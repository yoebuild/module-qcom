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
machines/
  arduino-uno-q.star           # Arduino UNO Q machine definition
feeds/
  arduino/{amd64,arm64}/Packages  # checked-in, signature-verified package indexes
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
    arches  = ["amd64", "arm64"],
    index   = "feeds/arduino",
    keyring = "keys/arduino-release-keyring.gpg",
)
```

`distro = "debian"` is deliberate. The kwarg picks the rootfs-assembly backend
and the resolver namespace, and these packages are built against Debian
trixie's glibc and depend on Debian packages by name — they have to land in the
same closure as `@module-debian`'s units. `qcom` is the module, not a distro.

Only arm64 is board support; the repo's amd64/i386/armel/armhf builds are
host-side Arduino tooling (`arduino-cli` and friends). amd64 is declared and
checked in anyway, because a feed cannot currently cover a single arch: the
`arches` kwarg is validated non-empty at parse time but never consulted at
lookup time, and the resolver asks every synthetic module about every
unresolved name. A feed missing an index for an arch the project builds
hard-errors on names it is merely being asked about —

```
synthetic module "qcom.arduino" lookup "py3-pip":
apt_feed: load .../feeds/arduino/amd64/Packages: no such file or directory
```

— which breaks unrelated x86_64 builds. `@module-debian` and `@module-ubuntu`
ship both arches for the same reason.

### What's in it

19 arm64 packages (and 10 amd64 host tools), in four groups:

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

A stock Qualcomm A/B GPT — 66 vendor partitions (38 signed firmware images in 19
A/B pairs, plus 28 single-copy state partitions) followed by three the OS
actually uses:

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

## The machine: `arduino-uno-q`

`machines/arduino-uno-q.star` models the board as arm64, two partitions, and a
prebuilt vendor kernel:

| Field | Value |
| --- | --- |
| `kernel.distro_unit` | `{"debian": "linux-image-7.0.0-g122c2c22d838"}` |
| `kernel.cmdline` | `console=ttyMSM0,115200 root=PARTLABEL=rootfs rootfstype=ext4 rootwait rw clk_ignore_unused pd_ignore_unused audit=0 deferred_probe_timeout=30` |
| `distro_packages["debian"]` | `arduino-unoq-config`, `arduino-unoq-radio-firmware`, `arduino-linux-config`, `alsa-ucm-conf`, `firmware-qcom-soc`, `firmware-atheros` |
| `partitions` | `efi` vfat 512M, `rootfs` ext4 10G (root) |

Three decisions worth stating outright:

**`clk_ignore_unused pd_ignore_unused` are mandatory, not tuning.** TrustZone
and always-on firmware hold clocks and power domains the kernel cannot
refcount; gating them at `late_initcall` hangs the board. Both are carried over
from the stock `/etc/kernel/cmdline`.

**`root=PARTLABEL=rootfs`, not the stock `root=UUID=…`.** The factory GPT labels
p68 `rootfs`, and a partition label survives a reflash that a filesystem UUID
does not.

**No `userdata` partition.** p69 (18.2G ext4 at `/home/arduino`) holds user data
and is meant to survive a rootfs reflash, so it is not image content. Mounting
it belongs to an fstab-writing rootfs unit. This also sidesteps a builder bug —
see below.

Board enablement only. The Arduino product experience (`arduino-app-lab`,
`arduino-app-cli`, `arduino-router`, `arduino-cli`, `adbd`) is image policy, not
board policy; put those in an image's package list, or pull the `arduino-unoq`
metapackage there.

## Known limitations

The machine definition parses, registers, and resolves. It does **not** yet
produce a bootable artifact — the shared image pipeline was built for
MBR + extlinux boards and this one is GPT + systemd-boot. Concretely:

- **A project selecting this machine must be all-apt.** `image()` resolves the
  machine kernel eagerly, at image-definition time, for every image in every
  loaded module. Selecting `arduino-uno-q` in a project that also loads
  `@module-alpine` fails during evaluation, before any build starts, with
  `image bun-image: machine kernel has no entry for distro "alpine"`. Drop
  `@module-alpine`, or keep UNO Q work in its own project, until yoe learns to
  skip kernel resolution for images whose distro the selected machine can't
  boot. The flat `kernel(unit = …)` form does not avoid this — it only trades
  the message for an opaque `resolve_closure` unresolved-name error.
- **The disk builder writes an MBR** (`sfdisk` `label: dos`), not GPT.
- **The ESP is populated from the wrong path.** `_create_disk_image_debian`
  copies `$DESTDIR/rootfs/boot/*` into the vfat partition; this board's ESP
  content lives at `/boot/efi/`, with kernels under a machine-id directory.
- **extlinux, not systemd-boot.** The Debian branch unconditionally generates
  `/boot/extlinux/extlinux.conf`. This board needs `BOOTAA64.EFI` plus a Boot
  Loader Specification type#1 entry. The stock `kernel-install` hooks already do
  the right thing on-device; the image builder has no equivalent.
- **`partition(contents = [...])` is inert.** It is parsed, hashed, and exposed
  to Starlark, but neither disk-image creator reads it — the vfat partition is
  always filled from `rootfs/boot/*`. The `contents` lists on the BeaglePlay and
  Raspberry Pi machines are documentation today.
- **A second ext4 partition would be wrong.** The builder runs
  `mkfs.ext4 -d $DESTDIR/rootfs` for *every* ext4 partition, so declaring
  `userdata` would populate it with a full second copy of the rootfs.
- **No DTB staging.** Nothing copies `qcom/qrb2210-arduino-imola*` from the
  kernel package to `/boot/efi/dtb/qcom/`, where U-Boot and
  `arduino-linux-config` expect them.
- **No flashing support.** yoe does not drive QDL/fastboot for the 66 vendor
  partitions. First-time provisioning still needs Arduino's own bundle.

## Maintainer playbook: `yoe update-feeds`

When Arduino publishes an update, refresh the checked-in index from this
module's root:

```sh
yoe update-feeds                  # refresh both arch indexes
yoe update-feeds --arch arm64     # arm64 only
```

The run fetches `dists/stable/InRelease`, verifies it against
`keys/arduino-release-keyring.gpg`, fetches each arch's
`dists/stable/main/binary-<arch>/Packages.gz`, decompresses it, and atomically
rewrites the on-disk index. It writes only — review with `git diff` and commit.

Watch the arm64 diff for a new `linux-image-<version>-g<hash>` name: the
`arduino-uno-q` machine pins that exact package, so a kernel bump means editing
`machines/arduino-uno-q.star` in the same commit.

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

> **Status:** The feed (`MODULE.star`, `feeds/`, `keys/`) and the
> `arduino-uno-q` machine exist. There is no `units/` directory yet, and the
> shared image pipeline cannot yet emit a bootable artifact for this board —
> see [Known limitations](#known-limitations). Today the module supplies vendor
> packages and a machine definition; a Debian image for this board is still
> assembled and provisioned by hand. The items below describe intended future
> work, informed by the board teardown above.

- **Image-pipeline support for GPT + systemd-boot** — the largest gap. A GPT
  branch in the disk builder, an ESP populated from `/boot/efi` rather than
  `/boot`, and a BLS entry writer replacing the unconditional `extlinux.conf`.
  This is core work in `@module-core`'s `classes/image.star`, not something
  this module can fix on its own.
- **A systemd-boot / BLS boot unit** — the ESP-side counterpart to
  `module-jetson`'s `jetson-extlinux`: install `BOOTAA64.EFI`, write
  `loader.conf`, and let the stock `kernel-install` hooks generate the entry.
- **ESP DTB staging** — copy `qcom/qrb2210-arduino-imola*` from the kernel
  package into `/boot/efi/dtb/qcom/` at image assembly time. The stock board
  mirrors the entire arm64 DTB tree there; staging only the qcom subtree is
  both smaller and sufficient.
- **An fstab unit for `/home/arduino`** — mounts the factory-provisioned
  `userdata` partition, which the machine deliberately does not model.
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
