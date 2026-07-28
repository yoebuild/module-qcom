# module-qcom

Yoe module for Qualcomm SoC boards. Today it wraps the **Arduino BSP apt
repo** — the one vendor feed that carries everything board-specific for the
Arduino UNO Q (Qualcomm QRB2210 / QCM2290, board codename `arduino,imola`).
Machine definitions and boot units for that board follow; see
[Roadmap](#roadmap-planned).

Everything in this module layers on top of `@module-debian`'s Debian trixie
feeds and shares their glibc ABI. The suite pinned in `MODULE.star`
(`stable`, which tracks Debian trixie) must stay consistent with
`@module-debian`'s `_DEBIAN_SUITE`.

## Layout

```
MODULE.star                    # apt_feed() declaration for the Arduino BSP repo
feeds/
  arduino/arm64/Packages       # checked-in, signature-verified package index
keys/
  arduino-release-keyring.gpg  # Arduino Release key; trust root for InRelease
  allowed-fingerprints         # accepted signing fingerprints on key rollover
```

## The feed

One `apt_feed(...)` call in `MODULE.star` exposes the whole vendor repo as a
synthetic module named `qcom.arduino`. Consumers reference it in
`prefer_modules`:

```python
apt_feed(
    name    = "arduino",                       # synthetic module: qcom.arduino
    distro  = "debian",                        # see below — not "qcom"
    url     = "https://apt-repo.arduino.cc",
    suite   = "stable",
    component = "main",
    arches  = ["arm64"],
    index   = "feeds/arduino",
    keyring = "keys/arduino-release-keyring.gpg",
)
```

`distro = "debian"` is deliberate. The kwarg picks the rootfs-assembly backend
and the resolver namespace, and these packages are built against Debian
trixie's glibc and depend on Debian packages by name — they have to land in the
same closure as `@module-debian`'s units. `qcom` is the module, not a distro.

The repo also publishes amd64/i386/armel/armhf builds of the host-side Arduino
tooling (`arduino-cli` and friends). Those are desktop tools, not board
support, so the feed declares `arches = ["arm64"]` only.

### What's in it

19 arm64 packages, in four groups:

| Package | Role |
| --- | --- |
| `linux-image-7.0.0-g122c2c22d838`, `linux-headers-…` | Arduino's kernel build (source package `linux-upstream`, Linux 7.0.0 at commit `122c2c22d838`). Ships the `qrb2210-arduino-imola*` device trees and overlays alongside the full upstream arm64 DTB set. |
| `arduino-unoq`, `arduino-unoq-config`, `arduino-unoq-radio-firmware`, `arduino-linux-config` | Board support. `arduino-unoq` is the metapackage that pulls the whole set; `arduino-unoq-radio-firmware` swaps in the right WCN3980 `board-2.bin` variant for the PCB revision; `arduino-linux-config` is the carrier-board device-tree overlay tool. `arduino-ventunoq*` is the same set for the sibling board. |
| `arduino-app-cli`, `arduino-app-lab`, `arduino-cli`, `arduino-router` | Userspace runtime — the App Lab web UI and the router daemon that bridges the Linux side to the on-board STM32 MCU. |
| `adbd`, `android-lib{base,cutils,log,utils,backtrace}` | Arduino rebuilds of Debian's android-tools, for USB device-mode `adb`. |
| `alsa-ucm-conf` (`1.2.14-1qcom0.1arduino3`) | Qualcomm's UCM profiles for the QRB2210 audio path, rebuilt on top of Debian's package. |

### Integrity

`dists/stable/InRelease` is OpenPGP clearsigned by the Arduino Release key
(subkey `D00818C3571FFCC4DEC903D0FE3654BE8D82CD00`). `yoe update-feeds`
verifies the signature against `keys/arduino-release-keyring.gpg` before
writing the index; each package's `SHA256:` from the verified index is what
gates the `.deb` download at build time.

The repo publishes no `Valid-Until` field, so freshness is not bounded by the
index itself — the signature is the trust anchor. Treat a stale checked-in
`Packages` as stale, not as invalid.

## How an Arduino UNO Q image is put together

Findings from a stock board (`arduino,imola` / `qcom,qrb2210` / `qcom,qcm2290`,
Debian 13.1 trixie, kernel 7.0.0-g122c2c22d838). This is the shape a yoe image
for this board has to reproduce.

### Package sources

Four apt sources, all Debian-format:

| Source | Suite / component | Role |
| --- | --- | --- |
| `deb.debian.org/debian` | `trixie` main, contrib, non-free, non-free-firmware | The rootfs. ~948 packages installed total. |
| `deb.debian.org/debian` | `trixie-updates` | Point-release updates. |
| `deb.debian.org/debian-security` | `trixie-security` | Security updates. |
| `deb.debian.org/debian` | `trixie-backports` | Newer hardware enablement; **not** enabled wholesale. |
| `apt-repo.arduino.cc` | `stable` main | The BSP feed this module wraps. |

Backports is pinned selectively rather than globally. `/etc/apt/preferences.d/`
raises priority to 900 for exactly six source packages:

```
Package: src:alsa-ucm-conf:any src:firmware-free:any src:firmware-nonfree:any
         src:linux:any src:linux-signed-arm64:any src:mesa:any
Pin: release n=trixie-backports
Pin-Priority: 900
```

In practice that pulls `firmware-qcom-soc` and `firmware-atheros`
(`20250808-1~bpo13+1`) and the Mesa stack (`25.2.6-1~bpo13+1`, for the Adreno
702 via freedreno) from backports, and leaves everything else on trixie.

Notably, the board is running Arduino's kernel — the `src:linux` backports pin
is a fallback path, not what boots.

### SoC firmware

Split across three places:

- **`firmware-qcom-soc` (Debian non-free-firmware, from backports)** — the
  loadable SoC firmware, including `/lib/firmware/qcom/qcm2290/` with
  `adsp.mbn`, `modem.mbn`, `wlanmdsp.mbn`, and `a702_zap.mbn` for the GPU. Both
  remoteprocs (`modem`, `adsp`) come up `running` from these.
- **`firmware-atheros` (Debian)** — WCN3980 Wi-Fi/BT firmware under
  `/lib/firmware/ath10k/WCN3990/` and `/lib/firmware/qca/`.
- **`arduino-unoq-radio-firmware` (Arduino)** — ships two candidate
  `board-2.bin` variants under `/usr/share/arduino-unoq-radio-firmware/` and
  selects the right one for the PCB revision at install time. This is the one
  piece Debian cannot supply, because it's per-board calibration data.

### eMMC layout

A stock Qualcomm A/B GPT — 66 firmware/vendor partitions followed by three the
OS actually uses:

```
p1-p2    xbl_a/b          3.5M    primary bootloader
p3-p4    xbl_config_a/b   128K
p5-p6    tz_a/b           4M      TrustZone
p7-p8    rpm_a/b          512K
p9-p10   hyp_a/b          512K
p11-p12  boot_a/b         4M
p13-p14  uefi_a/b         8M
p15-p16  uefi_dtb_a/b     1M
p24-p25  abl_a/b          1M      Android bootloader slot — holds U-Boot
…                                 devcfg, qupfw, modemst, persist, splash, …
p67      efi              512M    vfat, mounted at /boot/efi
p68      rootfs           10G     ext4, mounted at /
p69      userdata         18.2G   ext4, mounted at /home/arduino
```

Everything from `p1` through `p66` is flashed out of band (QDL / fastboot from
a vendor bundle) and is not managed by apt. Only the last three partitions are
image content. `/home/arduino` on its own partition means user data survives a
rootfs reflash.

### Boot chain

```
PBL → XBL → TZ / RPM / hyp → abl partition: U-Boot (EFI v2.11)
    → ESP:/EFI/BOOT/BOOTAA64.EFI: systemd-boot 257.8
    → BLS type#1 entry → vmlinuz + initrd
```

The interesting part is the middle: the `abl` slot holds **U-Boot running as
UEFI firmware** (`LoaderFirmwareInfo` reports `Das U-Boot 8230.256`,
`LoaderFirmwareType` reports `UEFI 2.110`), not Qualcomm's ABL. U-Boot's EFI
variable store persists to `/boot/efi/ubootefi.var` on the ESP.

U-Boot chainloads systemd-boot from the ESP, which reads Boot Loader
Specification type#1 entries under `/boot/efi/loader/entries/`, keyed by
machine-id:

```
title      Debian GNU/Linux 13 (trixie)
version    7.0.0-g122c2c22d838
machine-id 3e660e15577e4d88ad85a3673a183368
options    root=UUID=… clk_ignore_unused pd_ignore_unused audit=0 deferred_probe_timeout=30
linux      /3e660e15577e4d88ad85a3673a183368/7.0.0-g122c2c22d838/linux
initrd     /3e660e15577e4d88ad85a3673a183368/7.0.0-g122c2c22d838/initrd.img-…
```

Kernel and initrd are copied onto the ESP by the stock systemd `kernel-install`
hooks (`50-depmod`, `55-initrd`, `90-loaderentry`, `90-uki-copy`), with the base
cmdline in `/etc/kernel/cmdline`. Two kernel generations were installed
side-by-side on the board under test (6.16.7 and 7.0.0), each with its own BLS
entry — the standard multi-kernel rollback story, for free.

Note what is *not* in the boot chain: no `devicetree` line in the BLS entry.
The DT comes from U-Boot, which loads it from the ESP — see below.

### Device tree and carrier boards

The Arduino kernel package installs its DTBs to
`/usr/lib/linux-image-<ver>/`, and the full tree (every arm64 vendor, not just
qcom) is mirrored onto the ESP at `/boot/efi/dtb/`. That directory is owned by
no package — it's populated at image build time.

The board's own DTs live at `/boot/efi/dtb/qcom/`:

- `qrb2210-arduino-imola-base.dtb` — the base board
- `qrb2210-arduino-imola.dtb` — **the DTB U-Boot actually loads**
- `qrb2210-arduino-imola-carrier-media.dtbo`, `…-camera-imx219-csi{0,1}-{2,4}lanes.dtbo`,
  `…-panel-{5,8,10}in_touch_a-dsi.dtbo` — carrier-board overlays

`arduino-linux-config carrier enable …` is a Go CLI (hence its
`Depends: device-tree-compiler`) that runs `fdtoverlay` to merge the selected
`.dtbo`s onto the base DTB and writes the result to
`qrb2210-arduino-imola.dtb`, taking effect on the next boot. State lives in
`/var/lib/arduino-linux-config/status`, which is why `carrier show` reports a
separate `[current: …]` and `[next: …]`:

```
media-carrier  [current: disabled]  [next: disabled]
  camera0:     [current: none]      [next boot: none]
  camera1:     [current: none]      [next boot: none]
  display:     [current: none]      [next boot: none]
```

This is a runtime DT-composition mechanism, and it maps cleanly onto yoe's
"reuse binaries, resolve variation at runtime" rule — one image serves every
carrier/camera/panel combination, with no per-carrier build fork.

### Services enabled at boot

50 units enabled overall; the board-specific ones are:

```
adbd.service                     USB device-mode adb
arduino-app-cli.service          App Lab backend
arduino-router.service           bridge to the on-board STM32 MCU
arduino-router-serial.service    + .path unit
arduino-avahi-serial.service     mDNS advertisement
arduino-burn-bootloader.service  MCU bootloader provisioning
```

Under yoe these belong in `services = [...]` on the units that ship them, per
the "units declare their own services" rule — not in an image-level enable list.

### What a yoe image has to do differently

- **The 66 firmware partitions are out of scope**, exactly as QSPI is for
  Jetson. yoe produces the ESP + rootfs; a vendor QDL/fastboot bundle
  provisions the rest.
- **ESP + rootfs + userdata is a three-partition machine definition**, not the
  single-partition shape `module-jetson` uses.
- **systemd-boot + BLS**, not extlinux. The kernel-install hook path is stock
  Debian, so it works if the ESP is mounted at `/boot/efi` and a machine-id is
  present at image build time.
- **DTBs go on the ESP, not in `/boot`**, and the carrier overlay tool expects
  to find them at `/boot/efi/dtb/qcom/`.

## Maintainer playbook: `yoe update-feeds`

When Arduino publishes an update, refresh the checked-in index from this
module's root:

```sh
yoe update-feeds                  # refresh feeds/arduino/arm64/Packages
yoe update-feeds --arch arm64     # same; the only arch declared
```

The run fetches `dists/stable/InRelease`, verifies it against
`keys/arduino-release-keyring.gpg`, fetches
`dists/stable/main/binary-arm64/Packages.gz`, decompresses it, and atomically
rewrites the on-disk index. It writes only — review with `git diff` and commit.

If Arduino rotates the signing key, verification fails until the new
fingerprint is verified out of band and added:

```sh
yoe update-feeds --allow-key-update=<fingerprint>
```

and the new public key is dearmored into `keys/arduino-release-keyring.gpg`:

```sh
curl -fsSL https://apt-repo.arduino.cc/arduino.asc | gpg --dearmor > keys/arduino-release-keyring.gpg
```

## Roadmap (planned)

> **Status:** Only the feed exists today — `MODULE.star`, `feeds/`, and
> `keys/`. There are no `machines/` or `units/` directories yet, so this module
> cannot build an image on its own; it currently supplies vendor packages to a
> Debian-based image assembled elsewhere. The items below describe intended
> future work, informed by the board teardown above.

- **`machines/arduino-uno-q.star`** — arm64, three partitions (`efi` vfat 512M,
  `rootfs` ext4, `userdata` ext4 mounted at `/home/arduino`), kernel supplied by
  the feed's `linux-image-…` rather than a from-source unit, cmdline matching
  `/etc/kernel/cmdline`.
- **A systemd-boot / BLS boot unit** — the ESP-side counterpart to
  `module-jetson`'s `jetson-extlinux`: install `BOOTAA64.EFI`, write
  `loader.conf`, and let the stock `kernel-install` hooks generate the entry.
- **ESP DTB staging** — copy `qcom/qrb2210-arduino-imola*` from the kernel
  package into `/boot/efi/dtb/qcom/` at image assembly time. The stock board
  mirrors the entire arm64 DTB tree there; staging only the qcom subtree is
  both smaller and sufficient.
- **Service-enable companions** — `services = [...]` on the units that ship
  `adbd`, `arduino-router`, and the App Lab services, following the
  `<svc>-enable.star` pattern `module-alpine` uses for OpenRC.
- **Flashing support** — nothing here drives QDL/fastboot for the 66 vendor
  partitions. First-time provisioning still needs Arduino's own bundle.
- **Other Qualcomm boards** — the module is named for the SoC vendor, not the
  board. Qualcomm's RB1/RB2 (`qrb2210-rb1.dtb` ships in the same kernel
  package) and the Ventun Q are the obvious next machines; both would reuse
  this feed unchanged.

## Source provenance

- BSP feed: `https://apt-repo.arduino.cc` suite `stable`, component `main`,
  aptly-generated, signed by Arduino Release `<security@arduino.cc>`.
- Signing key: `/etc/apt/keyrings/arduino.asc` on a stock UNO Q image, also
  published at `https://apt-repo.arduino.cc/arduino.asc`.
- Board findings: stock Arduino UNO Q, Debian 13.1 trixie, kernel
  `7.0.0-g122c2c22d838`, U-Boot `8230.256`, systemd-boot `257.8-1~deb13u2`.
