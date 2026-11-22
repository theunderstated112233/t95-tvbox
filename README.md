# T95 (Allwinner H616) → mainline Debian server

<img width="1024" height="576" alt="image" src="https://github.com/user-attachments/assets/acbdd942-37fb-49af-9c3f-e0d1d5bdaae4" />


This turns the **T95 H616 Android TV box** (the one that shipped with the
"Corejava" firmware malware) into a headless **Debian 13 arm64 server**. It runs
**mainline U-Boot, TF-A and the stock Debian kernel**, with a device tree
written for this board. There is no vendor kernel or vendor bootloader, no
Armbian, and no vendor-signed image.

The box has secure boot enabled, but its root-key fuse was never programmed,
so the boot ROM accepts a bootloader signed with **your own key**.

> ⚠️ T95 boxes are sold with many different boards under the same name. Read
> [Is this your board?](#is-this-your-board) before writing anything. Back up
> the eMMC first (see [Backup](#backing-up-the-emmc)).

## Status

| | |
|---|---|
| Boot | Mainline U-Boot v2026.10 (TOC0, self-signed) + TF-A v2.15 → Debian 13, kernel 6.12, about 16 s to `multi-user` |
| RAM | All 4 GiB (proven by an alias test, not the label) |
| CPU | 4× A53, cpufreq 480 MHz–1.512 GHz, thermal throttling at 70 °C |
| microSD | ✅ boot + root (also the installer / recovery disk) |
| eMMC 32 GB | ✅ boot + root via `t95-install-emmc`; HS SDR 50 MHz, 8-bit, 1.8 V, about 40 MB/s (DDR modes hang, see below) |
| Watchdog + crash recovery | ✅ hardware watchdog, auto-reboot on panic, last kernel messages kept across resets (ramoops) |
| USB 2.0 (4 ports) | ✅ |
| Network | ✅ USB Ethernet adapter. Onboard 100M (AC300 PHY) needs Linux ≥ 7.4 |
| Wi-Fi BCM43342 | ❌ not supported by `brcmfmac` (chip 0xa94e), not even in 7.4-rc |
| Serial console | ✅ output only: RX is not wired on this board |
| HDMI / GPU / VPU | not configured (headless server) |
| IR receiver | enabled in DT, not tested |
| Front-panel display (FD6551) | ✅ clock + network icon, out-of-tree driver built with DKMS |

**Stability tested:** 24 h of memtester (2.8 GB, 18 full passes) plus stress-ng
on 3 cores with result checking: 0 errors, no lockups, no link drops. A kernel
package reinstall left the bootloader byte-identical. 20/20 warm reboots
passed health checks. Deliberate kernel crashes recover by themselves, both
through the panic reboot and through the hardware watchdog. Since then it has
run Pi-hole and Tailscale from the eMMC (see [Running services](#running-services)).

## Is this your board?

This was developed on a **T95 (5G), 4 GB / 32 GB**. Its hardware, read from
Android over adb:

| Part | Value |
|---|---|
| Android | Settings → About: model `MBOX`, build `10.1.A29-0407` |
| PCB marking | most likely `H616-T95MAX-AXP313A-v3.0` |
| SoC | H616 (`sun50iw9`), secure boot **on**, `sunxi_rotpk: 0` |
| RAM | 4 GB DDR3 @ 600 MHz |
| PMIC | **AXP1530** at r_i2c 0x36 (chip id reg 0x03 = 0x4b) |
| eMMC | 32 GB on mmc2, 8-bit |
| Wi-Fi | BCM43342 (SDIO 02d0:4334) |
| Ethernet | EMAC1 + internal AC300 EPHY |

The `H616-T95MAX-v4.0` board sold under the same name has an XR819 Wi-Fi chip
and a different PMIC; it is **not** this board.

Check these on yours (`getprop`, `dmesg`, `/sys/firmware/fdt`) before using
these values. The DRAM settings in particular are specific to this board.
Wrong DRAM settings are harmless (SPL just hangs, and the box still boots
Android), but they won't boot either.

## How it boots

```
Boot ROM ──(SD first, then eMMC; checks TOC0 signature against the empty fuse)──▶
  SPL (DRAM init, PMIC) ─▶ TF-A BL31 ─▶ U-Boot ─▶ extlinux.conf
  ─▶ Debian kernel + our DTB + initramfs ─▶ systemd
```

* The **boot ROM** reads a TOC0 image at 8 KiB on the SD card or eMMC. With
  secure boot on, it only accepts TOC0 (not the usual eGON header). Because the
  ROTPK fuse is empty, any key's signature is accepted. U-Boot's
  `CONFIG_SPL_IMAGE_TYPE_SUNXI_TOC0` builds one, signed with `keys/root_key.pem`.
* **apt never writes the bootloader.** `u-boot-sunxi` and `flash-kernel` are
  pinned to -1. Kernel updates only regenerate `/boot/extlinux/extlinux.conf`
  (via `u-boot-menu`), which always points at our DTB. Images that let a
  package update rewrite the bootloader, with a non-TOC0 or vendor-key image
  on this SoC, are the most likely cause of the "boots fine, then bricks after
  an update" reports.

## What you need

* A **USB Ethernet adapter**: the onboard port isn't supported by Debian's
  kernel yet. Realtek RTL8152/8153 adapters (firmware included) are tested.
* A **microSD card** (4 GB or more) and a card reader on the build PC.
* Optional: a **3.3 V USB-UART adapter** on the board's serial pads, to watch
  the boot and read the first-boot SSH host key fingerprints.

## Guided install: `t95-setup`

`./t95-setup` does everything below for you and stops only when it needs your
hands (SD card, cables, power) or your OK (anything that erases). Run it from
the repo as your normal user; run it again after any interruption and it
carries on where it stopped (`./t95-setup status` shows where that is).

| Step | What happens | Needs you |
|---|---|---|
| `prep` | installs the build packages, clones the pinned sources, fetches the Debian 13 signing keys and checks their fingerprints | sudo password |
| `doctor` | read-only check from Android over adb: H616, empty key fuse, AXP1530, BCM43342, 4 GB, eMMC, and the factory DRAM settings vs. the defconfig | ADB on (or `skip`) |
| `build` | everything in [Building](#building), with your SSH key, your password (stored only as a hash) and your PC's timezone | choose a password |
| `card` | finds the SD card, writes it, reads it back to verify | confirm the card by typing its name (e.g. `sdb`) |
| `boot` | finds the box on your network by its SSH host key (no serial console needed) | insert card, cable, power |
| `check` | RAM, cpufreq, thermal map, eMMC speed mode and read test, kernel log, watchdog, updates; lists running services, open ports, connections | - |
| `backup` | full eMMC + boot partitions to `backup/`, hashed on the box and on the PC | - |
| `install` | `t95-install-emmc`, blanks the leftover eMMC boot partitions | type `wipe`; then power off, remove card, power on |
| `verify` | checks it now runs from the eMMC and repeats the health checks | - |

`--dry-run` shows what it would do, `--host IP` skips the network scan,
`./t95-setup restore` puts the backed-up Android back. Private files (password
hash, the box's SSH host keys, reports) live in `.t95-setup/`, git-ignored.

The card `t95-setup` writes is **yours only**: `out/t95-sd.img` from a
`t95-setup` build holds the box's private SSH host keys, your password hash and
your SSH key. Don't share it. An image to share comes from the plain `board/`
scripts in [Building](#building).

## Building

You can run the interactive setup script and follow it or build. Everything builds as a normal user on an x86-64 Linux PC (tested on Linux Mint
22.3); only writing a card needs root. The rootfs is built for arm64 under
qemu-user emulation, so allow about 30 minutes and 10 GB of disk.

**One-time host setup**

```sh
sudo apt install gcc-aarch64-linux-gnu make bison flex swig bc \
    python3-dev python3-setuptools python3-pyelftools libssl-dev libgnutls28-dev \
    device-tree-compiler mmdebstrap qemu-user-static binfmt-support uidmap \
    fakeroot e2fsprogs zstd rsync git

mkdir -p src && cd src
git clone --depth 1 -b v2026.10 https://source.denx.de/u-boot/u-boot.git
git clone --depth 1 -b v2.15.0 https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git tf-a
# only the DT includes are needed from Linux
git clone --depth 1 -b v6.12 --filter=blob:none --sparse \
    https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git linux-6.12
git -C linux-6.12 sparse-checkout set arch/arm64/boot/dts/allwinner arch/arm/boot/dts/allwinner include/dt-bindings scripts/dtc/include-prefixes
cd ..
```

* `mmdebstrap --mode=unshare` needs your user to have subordinate IDs
  (`grep $USER /etc/subuid /etc/subgid`; Debian/Ubuntu/Mint create them for
  normal users).
* Debian keyring: older hosts don't have the trixie keys. Fetch
  `debian-archive-keyring_2025.1_all.deb` from deb.debian.org, check the key
  fingerprints against <https://ftp-master.debian.org/keys.html>, then
  `dpkg-deb -x <deb> keys/debian-keyring/x`.

**Build**

```sh
board/build-uboot.sh       # TF-A + U-Boot (patches applied) -> out/u-boot-sunxi-with-spl.bin
                           #   (creates keys/root_key.pem on the first run - keep it)
board/build-dtb.sh         # -> out/sun50i-h616-t95.dtb
board/build-rootfs.sh      # -> out/rootfs.tar (Debian 13 + overlay + DKMS front-panel driver)
board/build-sdimage.sh     # -> out/t95-sd.img (3 GiB, grows to the card on first boot)
```

`build-rootfs.sh` options (environment variables): `T95_USER` / `T95_PASSWORD`
(default `t95` / `t95`), `T95_PUBKEY` (preinstall an SSH key), `T95_TZ`
(default `Etc/UTC`), `T95_LOCALE` (default `en_US.UTF-8`). For a ready-to-dd
eMMC image instead: `ROOT_LABEL=t95-emmc IMG_NAME=emmc board/build-sdimage.sh`.

## Installing

1. **Write the SD card** (check the device name with `lsblk` first):
   `sudo dd if=out/t95-sd.img of=/dev/sdX bs=4M conv=fsync status=progress`
2. **Boot it.** Insert the card, plug in a USB Ethernet adapter, power on. The
   boot ROM tries SD before eMMC, so the eMMC is not touched. On the first boot
   the root partition grows to fill the card, and the box prints its new SSH
   host key fingerprints on the serial console (`t95: new SSH host key ...`)
   so you can check your first connection against them.
3. **Log in** as `t95`, password `t95` (find the box's address in your router,
   or reserve one for its adapter's MAC). The password has expired: you must
   set a new one, then log in again. After that:
   * `sudo` works with your password;
   * `ssh-copy-id t95@<box>` from each PC for key logins;
   * `sudo timedatectl set-timezone Region/City` (the front-panel clock uses it).
4. **Install to eMMC** (optional, erases Android): `sudo t95-install-emmc`.
   It copies the running system - including your account and keys - to the
   eMMC, with its own root label, machine-id and SSH host keys, and writes the
   bootloader. Power off, remove the card, power on. Keep the card: with it
   inserted the box boots from SD again, as a recovery system.

The image is a plain Debian install: one sudo user, SSH with password or key
logins (never root), DHCP on any wired interface (by MAC, so a router
reservation follows the box across reinstalls), unattended security updates,
zram swap. To update an already-written card in place from a newer build
(U-Boot, DTB, overlay, kernel arguments), use `sudo board/update-sd.sh /dev/sdX`.

## Running services

The image is deliberately bare: nothing beyond a base server is installed, so
what runs on it is up to you. Two common services have been tested on this box,
both installed by hand after the first boot:

* **Pi-hole v6** with the [official installer](https://docs.pi-hole.net/main/basic-install/)
  (directly on the system, not in a container). The installer adds
  `/etc/systemd/resolved.conf.d/90-pi-hole-disable-stub-listener.conf` so
  Pi-hole can take port 53; that is expected. Give the box a fixed address
  (router reservation) before pointing your network's DNS at it.
* **Tailscale** from [its Debian repository](https://tailscale.com/kb/1031/install-linux).
  With MagicDNS on, the box itself resolves through `100.100.100.100`.

With both running the box uses about 320 MB of its 3.9 GB of RAM and idles
around 40 °C.

## Files

| Path | What |
|---|---|
| `t95-setup` | guided install: runs every step below, stops only for cables, power, the SD card and confirmations |
| `board/sun50i-h616-t95.dts` | board device tree (used by both U-Boot and Linux) |
| `board/t95_h616_defconfig` | U-Boot config: DRAM, PMIC, TOC0 |
| `board/patches/u-boot/` | 4 GiB detection fix for TOC0 boot |
| `board/patches/tf-a/` | watchdog reset fix (panic reboots hung without it) |
| `board/drivers/leds-fd6551/` | front-panel driver: [paolosabatino/leds-fd6551](https://github.com/paolosabatino/leds-fd6551) at `4a90394` with `board/patches/leds-fd6551/` applied, built by DKMS |
| `board/rootfs-overlay/` | files copied into the image (network, sshd, apt pins, watchdog, front panel, installer …) |
| `board/backup-emmc.sh` | resumable, hash-verified eMMC backup over adb (from Android) |
| `board/test/` | heartbeat service, reboot-cycle test, ping watcher, front-panel probe |

## Board quirks and how they were fixed

These are the problems hit during bring-up, in boot order. Each one is
documented next to its fix in the DTS or defconfig.

**1. DRAM settings: use boot0, not the Android device tree.** The `dram_para`
values in Android's DT did not match what boot0 actually used. The working
values were read from the vendor **boot0** header on the eMMC (at 8 KiB) and
are in the defconfig.

**2. AXP1530 PMIC.** It is register-compatible with the AXP313A and passes
U-Boot's and Linux's AXP313 chip-ID check. DCDC3 must be 1.5 V (DDR3).

**3. "2 GiB" in U-Boot on a 4 GiB box.** A TOC0 image has no eGON header, so
U-Boot can't read the RAM size SPL measured. It falls back to probing, capped
at `PHYS_SDRAM_0_SIZE` (2 GiB). The patch probes up to
`CONFIG_SUNXI_DRAM_MAX_SIZE` instead. Many of these boxes have **faked RAM
labels**, so the defconfig keeps a `PREBOOT` alias test: it writes different
values at 0x50000000 and 0xd0000000 (2 GiB apart). If both read back
distinct, the RAM is really 4 GiB.

**4. UART RX is not connected.** The console pads (115200 8N1) print output,
but nothing typed reaches U-Boot. Everything diagnostic therefore runs
automatically (`CONFIG_PREBOOT`, kernel arguments, an extlinux menu with a
`single` rescue entry).

**5. Kernel goes silent right after "Starting kernel".** The DTS had
`vcc-p*-supply` on `&pio`, as other H616 boards do. Debian builds the AXP and
I2C drivers as modules, so the built-in pin controller (and with it the UART)
deferred probing until the PMIC module loaded. `clk_disable_unused` then
switched off the UART clock and the early console went dark. Fix: no pio
supplies (the rails are always on anyway).

**6. eMMC hangs (`data error, sending stop command` / `send stop command failed`,
hung tasks, `sync` never returns).** `sunxi-mmc` turns on **DDR52** for every
"new timings" controller, and `sun50i-h616.dtsi` adds `mmc-ddr-3_3v`. The chip
supports DDR52 and HS200, but on this board DDR transfers fail and the
controller wedges. The vendor kernel ran the eMMC as SDR high-speed at 50 MHz,
which suggests the board was never validated for DDR. The driver only skips
DDR for nodes compatible with `allwinner,sun50i-h5-emmc`. The fix appends that
string and deletes `mmc-ddr-3_3v`. Result: SDR 50 MHz, 8-bit, 0 errors over a
full-disk read and 20 warm resets.

   Why a **warm** reboot didn't recover it: the chip's hardware-reset function
   is disabled (`EXT_CSD[162] RST_n_FUNCTION = 0`), and its supply stays on
   through a reboot. So the eMMC kept its stuck state and failed again with
   `update clk timeout`; only pulling power cleared it.

**7. No thermal throttling.** Mainline `sun50i-h616.dtsi` defines the
cpu-thermal trip points (60/70 °C) but **no cooling map**. Without one, the CPU
never slows down before the 110 °C emergency shutdown. The DTS adds the map on
the 70 °C trip. In a stock case at full load the CPU settles at about 73 °C and
1.2–1.3 GHz.

**8. cpufreq not loaded.** `sun50i-cpufreq-nvmem` is a module that isn't
autoloaded. It is loaded via `/etc/modules-load.d/t95-cpufreq.conf`.

**9. `ping` fails for normal users.** File capabilities (`cap_net_raw`) are
lost when the image is built under fakeroot. Unprivileged ICMP is enabled via
`net.ipv4.ping_group_range` instead.

**10. Onboard Ethernet LED stays off.** That is expected: EMAC1 and the AC300
PHY aren't described in the DT, because the PHY driver only lands in Linux 7.4.
Use a USB adapter until Debian ships 7.4 (trixie-backports).

**11. A kernel panic hangs instead of rebooting (TF-A bug).** With systemd's
hardware watchdog running, a panic reboot froze the box for good: no reset,
and the watchdog never fired. TF-A's PSCI reset on Allwinner reprograms the
watchdog to its shortest timeout but never restarts its counter, and on the
H616 that leaves it stalled - the serial console shows `Rebooting in 10
seconds..` followed by `PANIC at PC : 0x...` from BL31. The patch in
`board/patches/tf-a/` adds the counter reload Linux's own `sunxi_wdt` does.
Normal reboots were never affected (Linux stops the watchdog first).

**12. Front-panel display.** The FD6551 sits on PI11 (clock) / PI12 (data) and
speaks an I2C-like protocol, but it **never ACKs**, so the bit-banged
`i2c-gpio` bus is configured output-only. The segments are wired upside down
(`segment-map = /bits/ 8 <3 4 5 0 1 2 6 7>`; digit order is normal), and the
icons are: 0 clock, 1 USB, 2 play, 3 pause, 4 colon, 5 network, 6 Wi-Fi.
`t95-frontpanel.service` shows the time with a blinking colon and lights the
network icon with the wired link.

## Backing up the eMMC

Do this before ever writing to the eMMC. There are two ways:

* **From Linux on SD (best).** If booting in linux, Android will not be running, so the image is
  consistent:
  `ssh box 'sudo dd if=/dev/mmcblk1 bs=4M' | tee >(sha256sum > emmc.sha256) | zstd -T0 > emmc.img.zst`
  Compare the hash with `sudo sha256sum /dev/mmcblk1` run on the box.
* **From Android over adb** with `board/backup-emmc.sh`: resumable 1 GiB chunks,
  each hashed on both ends. Note: an image taken while Android runs is *not*
  consistent. Here 24 MiB of ext4 metadata in `super`/`cache` read back as
  zeros.

Restore, from Linux on SD:
`zstd -dc emmc.img.zst | sudo dd of=/dev/mmcblk1 bs=4M conv=fsync`

Keep `keys/root_key.pem`. Any key works on this SoC, but keeping one makes
builds reproducible.

## Roadmap

- [x] SD boot, 4 GiB, PMIC, cpufreq, thermal, eMMC, USB network
- [x] 24 h stress test, kernel-update test, reboot cycles
- [x] Hardening: hardware watchdog, panic reboot, ramoops, unattended security updates
- [x] Front-panel display (clock, network icon)
- [x] Clean installable image + `t95-install-emmc` (wipes Android and the malware)
- [x] Real services on the eMMC install (Pi-hole, Tailscale)
- [ ] Onboard Ethernet (EMAC1 + AC300) once Linux 7.4 reaches trixie-backports
- [ ] Report the TF-A watchdog reset fix upstream

## Credits

* [DesktopECHO/T95-H616-Malware](https://github.com/DesktopECHO/T95-H616-Malware):
  the malware analysis and Android mitigation.
* [linux-sunxi.org](https://linux-sunxi.org): H616 and T95 documentation.
* U-Boot, Trusted Firmware-A, Linux and Debian maintainers. The board DTS is
  derived from `sun50i-h618-transpeed-8k618-t.dts`.
* [paolosabatino/leds-fd6551](https://github.com/paolosabatino/leds-fd6551):
  the FD6551 front-panel driver (patched here).
* Claude for doing pretty much all of the work to get an image running.
* NickAlilovic for helping me set up Armbian on this board many months ago.

## License

| Part | License |
|---|---|
| Scripts, rootfs overlay, docs | MIT ([LICENSE](LICENSE)) |
| `board/sun50i-h616-t95.dts` | `GPL-2.0+ OR MIT` (same as the upstream DTS it derives from) |
| `board/drivers/leds-fd6551/`, `board/patches/leds-fd6551/` | GPL-2.0 (upstream driver, [its LICENSE](board/drivers/leds-fd6551/LICENSE)) |
| `board/patches/u-boot/`, `board/t95_h616_defconfig` | GPL-2.0+ (U-Boot) |
| `board/patches/tf-a/` | BSD-3-Clause (TF-A) |
