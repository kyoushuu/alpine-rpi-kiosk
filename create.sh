#!/bin/bash

set -ex

: ${BRANCH:=v3.17}
: ${IMAGE_FILE:=$PWD/alpine-rpi-kiosk-$BRANCH.img}
: ${BASE_PACKAGES:="alpine-base linux-rpi linux-rpi4 linux-firmware-other raspberrypi-bootloader openssl dosfstools e2fsprogs"}
: ${XORG_PACKAGES:="xorg-server xf86-input-libinput eudev mesa-dri-gallium xf86-video-fbdev mesa-egl xrandr chromium"}
: ${PACKAGES:="chrony doas e2fsprogs-extra parted lsblk"}
: ${ROOTPASS:=raspberry}
: ${USERNAME:=pi}
: ${USERPASS:=raspberry}
: ${IP_ADDRESS:=}
: ${RESOLUTION:=1280x720}
: ${HOME_URL:=https://www.google.com}
: ${ROOT_MNT:="$(mktemp -d)"}
: ${COMPRESSOR:=xz -4f -T0}


setup_first_boot() {
	# Based on https://github.com/knoopx/alpine-raspberry-pi/blob/master/bootstrap/99-first-boot

	cat <<-'EOF' > "$ROOT_MNT"/usr/bin/first-boot
	#!/bin/sh
	set -xe

	ROOT_PARTITION=$(df -P / | tail -1 | cut -d' ' -f1)
	SYS_DISK="/dev/$(lsblk -ndo PKNAME $ROOT_PARTITION)"

	cat <<PARTED | parted ---pretend-input-tty $SYS_DISK
	unit %
	resizepart 2
	Yes
	100%
	PARTED

	partprobe
	resize2fs $ROOT_PARTITION
	rc-update del first-boot
	rm /etc/init.d/first-boot /usr/bin/first-boot

	reboot
	EOF

	cat <<-EOF > "$ROOT_MNT"/etc/init.d/first-boot
	#!/sbin/openrc-run
	command="/usr/bin/first-boot"
	command_background=false
	depend() {
	    after modules
	    need localmount
	}
	EOF
}

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

gen_setup_script() {
	cat <<-EOF
	#!/bin/sh

	set -ex

	# Needed by X11
	setup-devd udev || true

	echo "root:$ROOTPASS" | /usr/sbin/chpasswd

	# Create user
	adduser -D "$USERNAME"
	echo "$USERNAME:$USERPASS" | /usr/sbin/chpasswd

	# Raspberry Pi has no hardware clock
	rc-update add swclock boot
	rc-update del hwclock boot || true
	setup-ntp chrony || true

	chmod +x /etc/init.d/first-boot /usr/bin/first-boot
	rc-update add first-boot
	EOF
}

setup_xorg() {
	# Based on https://wiki.alpinelinux.org/wiki/Raspberry_Pi_3_-_Browser_Client

	cat <<-EOF >> "$ROOT_MNT"/home/$USERNAME/.xinitrc
	xrandr -s $RESOLUTION
	chromium-browser --kiosk --window-size=${RESOLUTION/x/,} $HOME_URL
	EOF

	cat <<-EOF >> "$ROOT_MNT"/home/$USERNAME/.profile
	startx
	doas /sbin/poweroff
	EOF

	cat <<-EOF >> "$ROOT_MNT"/etc/doas.d/doas.conf
	permit nopass $USERNAME as root cmd /sbin/poweroff
	EOF

	# Automatic login
	sed -i "s|^\(tty1::.*\)|#\1\ntty1::respawn:/bin/login -f $USERNAME|" "$ROOT_MNT"/etc/inittab
}

clean_files() {
	rm -f "$1"{/env.sh,/enter-chroot,/destroy,/apk.static,/setup.sh}
	find "$1"{/var/cache/apk,/root} -mindepth 1 -delete

	if [ -z "$IP_ADDRESS" ]; then
		rm "$1"/etc/resolv.conf
	fi
}

shrink_image() {
	# From https://github.com/knoopx/alpine-raspberry-pi/blob/master/make-image

	# Shrink image
	local part_start=$(parted -ms "$1" unit B print | tail -n 1 | cut -d ':' -f 2 | tr -d 'B')
	local block_size=$(tune2fs -l "$2" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)
	local min_size=$(resize2fs -P "$2" | cut -d ':' -f 2 | tr -d ' ')

	# Shrink fs
	e2fsck -f -p "$2"
	resize2fs -p "$2" "$min_size"

	# Shrink partition
	local part_end=$((part_start + (min_size * block_size)))
	parted ---pretend-input-tty "$1" <<-EOF
	unit B
	resizepart 2 $part_end
	yes
	quit
	EOF
}

truncate_image() {
	# From https://github.com/knoopx/alpine-raspberry-pi/blob/master/make-image

	# Truncate free space
	local free_start=$(parted -ms "$1" unit B print free | tail -1 | cut -d ':' -f 2 | tr -d 'B')
	truncate -s "$free_start" "$1"
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
	| sh -s -- -a aarch64 -b "$BRANCH" -d "$ROOT_MNT" -p "$BASE_PACKAGES $XORG_PACKAGES $PACKAGES"

setup_first_boot
setup_disk
setup_bootloader
setup_network

gen_setup_script > "$ROOT_MNT"/setup.sh
chmod +x "$ROOT_MNT"/setup.sh
"$ROOT_MNT"/enter-chroot /setup.sh

setup_xorg

clean_files "$ROOT_MNT"
umount -lf "$ROOT_MNT"
rmdir "$ROOT_MNT"

shrink_image "$IMAGE_FILE" "$ROOT_DEV"
losetup -d "$LOOP_DEV"
truncate_image "$IMAGE_FILE"

$COMPRESSOR "$IMAGE_FILE"
