#!/bin/bash

set -ex

: ${BRANCH:=v3.17}
: ${IMAGE_FILE:=$PWD/alpine-rpi-kiosk-$BRANCH.img}
: ${PACKAGES:="alpine-base linux-rpi linux-rpi4 linux-firmware-other raspberrypi-bootloader openssl dosfstools e2fsprogs"}
: ${IP_ADDRESS:=}
: ${ROOT_MNT:="$(mktemp -d)"}


setup_disk() {
	local boot_uuid=$(blkid -o value -s UUID "$BOOT_DEV")
	local root_uuid=$(blkid -o value -s UUID "$ROOT_DEV")

	cat <<-EOF > "$ROOT_MNT"/etc/fstab
	UUID=$root_uuid	/	ext4	rw,relatime 0 1
	UUID=$boot_uuid	/boot	vfat	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 2
	/dev/cdrom	/media/cdrom	iso9660	noauto,ro 0 0
	/dev/usbdisk	/media/usb	vfat	noauto	0 0
	tmpfs	/tmp	tmpfs	nosuid,nodev	0	0
	EOF

	echo "root=UUID=$root_uuid modules=sd-mod,usb-storage,ext4 quiet rootfstype=ext4" > "$ROOT_MNT"/boot/cmdline.txt
}

setup_bootloader() {
	# Based on https://gitlab.alpinelinux.org/alpine/alpine-conf/-/blob/master/setup-disk.in
	cat <<-EOF > "$ROOT_MNT"/boot/config.txt
	# do not modify this file as it will be overwritten on upgrade.
	# create and/or modify usercfg.txt instead.
	# https://www.raspberrypi.com/documentation/computers/config_txt.html
	[pi02]
	kernel=vmlinuz-rpi
	initramfs initramfs-rpi
	[pi3]
	kernel=vmlinuz-rpi
	initramfs initramfs-rpi
	[pi3+]
	kernel=vmlinuz-rpi
	initramfs initramfs-rpi
	[pi4]
	enable_gic=1
	kernel=vmlinuz-rpi4
	initramfs initramfs-rpi4
	[all]
	arm_64bit=1
	include usercfg.txt
	EOF

	# Based on: https://wiki.alpinelinux.org/wiki/Raspberry_Pi#Enable_OpenGL_(Raspberry_Pi_3/4)
	cat <<-EOF >> "$ROOT_MNT"/boot/usercfg.txt
	dtoverlay=vc4-kms-v3d
	disable_overscan=1
	EOF
}

setup_network() {
	# Based on https://wiki.alpinelinux.org/wiki/Configure_Networking#Ethernet_Configuration

	cat <<-EOF > "$ROOT_MNT"/etc/network/interfaces
	auto lo
	iface lo inet loopback

	auto eth0
	EOF

	if [ -z "$IP_ADDRESS" ]; then
		cat <<-EOF >> "$ROOT_MNT"/etc/network/interfaces
		iface eth0 inet dhcp
		EOF
	else
		cat <<-EOF >> "$ROOT_MNT"/etc/network/interfaces
		iface eth0 inet static
		        address ${IP_ADDRESS}/24
		        gateway ${IP_ADDRESS%.*}.1
		EOF

		cat <<-EOF >> "$ROOT_MNT"/etc/resolv.conf
		nameserver 8.8.8.8
		nameserver 8.8.4.4
		EOF
	fi
}

clean_files() {
	rm -f "$1"{/env.sh,/enter-chroot,/destroy,/apk.static,/setup.sh}
	find "$1"{/var/cache/apk,/root} -mindepth 1 -delete

	if [ -z "$IP_ADDRESS" ]; then
		rm "$1"/etc/resolv.conf
	fi
}


dd if=/dev/zero of=$IMAGE_FILE bs=2M count=1K

(echo o;                                    # Create partition table
 echo n; echo p; echo 1; echo; echo +128MB; # Create boot partition
 echo t; echo c;                            # Set type to W95 FAT32 (LBA)
 echo n; echo p; echo 2; echo; echo;        # Create root partition
 echo w) | fdisk $IMAGE_FILE

LOOP_DEV=$(losetup -Pf --show "$IMAGE_FILE")
BOOT_DEV="$LOOP_DEV"p1
ROOT_DEV="$LOOP_DEV"p2

mkfs.fat -F32 "$BOOT_DEV"
mkfs.ext4 "$ROOT_DEV"

mkdir -p "$ROOT_MNT"
mount --make-private "$ROOT_DEV" "$ROOT_MNT"
mkdir -p "$ROOT_MNT/boot"
mount --make-private "$BOOT_DEV" "$ROOT_MNT/boot"

curl https://raw.githubusercontent.com/alpinelinux/alpine-chroot-install/master/alpine-chroot-install \
	| sh -s -- -a aarch64 -b "$BRANCH" -d "$ROOT_MNT" -p "$PACKAGES"

setup_disk
setup_bootloader
setup_network

clean_files "$ROOT_MNT"
umount -lf "$ROOT_MNT"
rmdir "$ROOT_MNT"
losetup -d "$LOOP_DEV"
