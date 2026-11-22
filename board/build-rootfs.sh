#!/usr/bin/env bash
# Build a Debian trixie arm64 rootfs tarball for the T95 (no root needed:
# mmdebstrap unshare mode + qemu-user-static binfmt).
# Output: out/rootfs.tar
set -euo pipefail

W=$(cd "$(dirname "$0")/.." && pwd)
OUT=$W/out
# Default account, like a fresh Debian install: member of sudo (asks for its
# password), password expired so the first login must set a new one.
USERNAME=${T95_USER:-t95}
PASSWORD=${T95_PASSWORD:-$USERNAME}
# optional: a file holding a crypt(3) hash for the account (openssl passwd -6),
# used instead of T95_PASSWORD - keeps the plaintext out of the build and is
# safe for passwords with quotes, $ or backslashes
PWHASHFILE=${T95_PASSWORD_HASHFILE:-}
# 1 (default): the password must be changed at first login (the default one is
# public). 0: keep it - for a password you chose yourself (used by t95-setup)
EXPIRE=${T95_EXPIRE_PASSWORD:-1}
# optional: preinstall an SSH public key for that account (none by default)
PUBKEY=${T95_PUBKEY:-}
# locale your SSH client forwards (sshd AcceptEnv LANG LC_*); system default is C.UTF-8
LOCALE=${T95_LOCALE:-en_US.UTF-8}
# timezone for logs and the front-panel clock
TZONE=${T95_TZ:-Etc/UTC}
DTB=$OUT/sun50i-h616-t95.dtb
UBOOT=$OUT/u-boot-sunxi-with-spl.bin   # shipped in the image for t95-install-emmc
# front-panel driver (out of tree, patched), built in the image with DKMS
DRV=$W/board/drivers/leds-fd6551
DRV_VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$DRV/dkms.conf")

[ -f "$DTB" ] || "$W/board/build-dtb.sh"
[ -f "$UBOOT" ] || { echo "missing $UBOOT - run board/build-uboot.sh"; exit 1; }
[ -z "$PUBKEY" ] || [ -f "$PUBKEY" ] || { echo "missing SSH public key $PUBKEY"; exit 1; }
[ -z "$PWHASHFILE" ] || [ -f "$PWHASHFILE" ] || { echo "missing password hash file $PWHASHFILE"; exit 1; }
case $EXPIRE in 0|1) ;; *) echo "T95_EXPIRE_PASSWORD must be 0 or 1"; exit 1 ;; esac
KEYHOOKS=()
[ -z "$PUBKEY" ] || KEYHOOKS=(
	--customize-hook="mkdir -p \"\$1/home/$USERNAME/.ssh\""
	--customize-hook="upload '$PUBKEY' /home/$USERNAME/.ssh/authorized_keys"
)
[ -z "$PWHASHFILE" ] || KEYHOOKS+=(
	--customize-hook="upload '$PWHASHFILE' /root/.t95-pwhash"
)

# Host (Mint) keyring is too old for trixie; use Debian 2025.1 keyring extracted
# to keys/debian-keyring (fingerprints cross-checked against ftp-master.debian.org).
# mmdebstrap would otherwise auto-pick the host's stale keyring as signed-by,
# so every source line carries an explicit signed-by for the build.
# apt verifies as the unprivileged _apt user, which cannot enter $HOME (0750),
# so stage a world-readable copy outside $HOME for the duration of the build.
SRC_KEYRING=$W/keys/debian-keyring/x/usr/share/keyrings/debian-archive-keyring.pgp
[ -f "$SRC_KEYRING" ] || { echo "missing $SRC_KEYRING"; exit 1; }
KDIR=$(mktemp -d /tmp/t95-keyring.XXXXXX); trap 'rm -rf "$KDIR"' EXIT
chmod 755 "$KDIR"; KEYRING=$KDIR/debian-archive-keyring.gpg
install -m 644 "$SRC_KEYRING" "$KEYRING"

PKGS=(
	debian-archive-keyring
	linux-image-arm64 initramfs-tools u-boot-menu
	systemd-sysv systemd-resolved systemd-timesyncd dbus
	openssh-server sudo ca-certificates
	iproute2 iputils-ping nano less curl
	zram-tools cloud-guest-utils e2fsprogs fdisk zstd
	locales unattended-upgrades rsync
	dkms linux-headers-arm64   # rebuilds the front-panel driver on kernel updates
	firmware-realtek          # RTL8152/8153 USB Ethernet adapters
)

# sync-in keeps the host uid (1000 = the box user!) -> re-own every overlay path to root.
OVERLAY_PATHS=$(cd "$W/board/rootfs-overlay" && find . | tr '\n' ' ')

# Host files are copied with mmdebstrap's upload/sync-in special hooks: the
# namespace root (a subuid) cannot enter $HOME (0750).
mmdebstrap \
	--mode=unshare --arch=arm64 --variant=apt \
	--components="main non-free-firmware" \
	--include="$(IFS=,; echo "${PKGS[*]}")" \
	--customize-hook="mkdir -p \"\$1/boot/dtbs/t95\" \"\$1/usr/lib/t95\"" \
	--customize-hook="upload '$DTB' /boot/dtbs/t95/sun50i-h616-t95.dtb" \
	--customize-hook="upload '$UBOOT' /usr/lib/t95/u-boot-sunxi-with-spl.bin" \
	"${KEYHOOKS[@]}" \
	--customize-hook="sync-in '$W/board/rootfs-overlay' /" \
	--customize-hook="for p in $OVERLAY_PATHS; do chown -h 0:0 \"\$1/\$p\"; done" \
	--customize-hook="mkdir -p \"\$1/usr/src/leds-fd6551-$DRV_VER\"" \
	--customize-hook="sync-in '$DRV' /usr/src/leds-fd6551-$DRV_VER" \
	--customize-hook="rm -rf \"\$1/usr/src/leds-fd6551-$DRV_VER/.git\"; chown -R 0:0 \"\$1/usr/src/leds-fd6551-$DRV_VER\"" \
	--customize-hook="chroot \"\$1\" /bin/sh -e -c '
		echo t95 > /etc/hostname
		printf \"127.0.0.1\tlocalhost\n127.0.1.1\tt95\n::1\tlocalhost ip6-localhost ip6-loopback\n\" > /etc/hosts
		useradd -m -s /bin/bash -G sudo,adm,systemd-journal $USERNAME
		if [ -f /root/.t95-pwhash ]; then
			{ printf %s $USERNAME:; cat /root/.t95-pwhash; } | chpasswd -e
			rm -f /root/.t95-pwhash
		else
			echo \"$USERNAME:$PASSWORD\" | chpasswd
		fi
		[ $EXPIRE = 0 ] || passwd -e $USERNAME
		passwd -l root
		chown $USERNAME:$USERNAME /home/$USERNAME
		if [ -f /home/$USERNAME/.ssh/authorized_keys ]; then
			chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
			chmod 700 /home/$USERNAME/.ssh; chmod 600 /home/$USERNAME/.ssh/authorized_keys
		fi
		echo \"$LOCALE UTF-8\" >> /etc/locale.gen; locale-gen
		ln -sf /usr/share/zoneinfo/$TZONE /etc/localtime   # timedatectl only updates this link
		systemctl enable systemd-networkd systemd-resolved systemd-timesyncd t95-growroot.service t95-frontpanel.service
		u-boot-update
		dkms install leds-fd6551/$DRV_VER -k \$(ls /lib/modules | head -n1)
		# no baked-in SSH host keys: each install makes its own on first boot
		rm -f /etc/ssh/ssh_host_*
		# no battery-backed clock: systemd starts the clock at least at this
		# file's date, so a fresh install boots with the build date, not
		# systemd's own (months older), until the first time sync
		touch /usr/lib/clock-epoch
	'" \
	--customize-hook='cat > "$1/etc/apt/sources.list" <<EOF
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian trixie main non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian trixie-updates main non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian-security trixie-security main non-free-firmware
EOF' \
	trixie "$OUT/rootfs.tar" \
	"deb [signed-by=$KEYRING] http://deb.debian.org/debian trixie main non-free-firmware" \
	"deb [signed-by=$KEYRING] http://deb.debian.org/debian trixie-updates main non-free-firmware" \
	"deb [signed-by=$KEYRING] http://deb.debian.org/debian-security trixie-security main non-free-firmware"

echo "OK: $OUT/rootfs.tar"
