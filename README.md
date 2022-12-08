Builds a minimal Alpine Linux image as Chromium kiosk for Raspberry Pi 4, 3 and Zero 2. Other boards are not supported since the Chromium package is only available for `aarch64` architecture since Alpine Linux version 3.12.

To configure, use the following environment variables:

- `BRANCH` - Alpine Linux [release branch](https://www.alpinelinux.org/releases/). For example: `edge`, `latest-stable` or `v3.17`. Default is `v3.17`.

- `MIRROR` - Alpine Linux [mirror service URL](https://mirrors.alpinelinux.org). Default is `http://dl-cdn.alpinelinux.org/alpine`.

- `IMAGE_FILE` - Path to the output image file, but without the extension for compression if enabled. Default is `alpine-rpi-kiosk-$BRANCH.img`.

- `PACKAGES` - Additional packages to install. Default is none.

- `KEYBOARD_LAYOUT` - Set keyboard layout. Default is `us`.

- `KEYBOARD_VARIANT` - Set keyboard variant. Default is `us`.

- `TIMEZONE` - Set the timezone. Default is `UTC`.

- `ROOTPASS` - Password for the root user. Default is `raspberry`.

- `USERNAME` - Username for the non-root user. Default is `pi`.

- `USERPASS` - Password for the non-root user. Default is `raspberry`.

- `IP_ADDRESS` - IP Address for the `eth0` interface. Default is empty, which means use DHCP.

- `RESOLUTION` - Screen resolution to use in the `WIDTHxHEIGHT` format. Default is `1280x720`.

- `HOME_URL` - URL that will be shown with the Chromium browser. Default is `https://www.google.com`.

- `ROOT_MNT` - Path where the root will be created and mounted. Default is a temporary folder created using `mktemp -d`.

- `COMPRESSOR` - Command to use to compress the image file. Set to `:` if you don't want to use compression. Default is `xz -4f -T0`.

- `COMMANDS` - Commands to run before unmounting the image. You could use environment variables here but escape them while setting the value. To run commands inside the chroot you have to use `"$ROOT_MNT"/enter-chroot /bin/sh` to run it. Default is `:`, which means no commands will be executed.

In Ubuntu 22.04, install dependencies with: `sudo apt install -y fdisk dosfstools curl parted xz-utils qemu-user-static binfmt-support`.

License: GPL version 3
