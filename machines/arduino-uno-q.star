# Arduino UNO Q — Qualcomm QRB2210 (QCM2290), board codename
# `arduino,imola`.
#
# WHAT THIS MACHINE MODELS. Only the two OS partitions. The eMMC carries
# 66 vendor partitions ahead of them (xbl, tz, rpm, hyp, uefi, abl,
# devcfg, modemst, persist, splash, …) holding the boot chain up to and
# including U-Boot; those are factory-provisioned and reflashed out of
# band with QDL/fastboot from Arduino's bundle. yoe never writes them,
# exactly as @module-jetson never writes the Orin's QSPI.
#
# `userdata` (p69, 18.2G ext4, mounted at /home/arduino) is deliberately
# absent below. It holds user data and is meant to survive a rootfs
# reflash, so it is not image content — it is provisioned once and left
# alone. Mounting it belongs to an fstab-writing rootfs unit, not here.
#
# BOOT CHAIN:
#   PBL → XBL → TZ/RPM/hyp → abl partition: U-Boot as UEFI firmware
#       → ESP:/EFI/BOOT/BOOTAA64.EFI: systemd-boot
#       → Boot Loader Spec type#1 entry → vmlinuz + initrd
#       (device tree comes from U-Boot, which loads
#        /boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb off the ESP)
#
# DEBIAN ONLY. The kernel and every board package come from the
# `qcom.arduino` feed, which is Debian-format and ABI-coupled to trixie.
# There is no Alpine or Ubuntu path for this board. Board packages are
# therefore declared under `distro_packages` with a `debian` key only,
# so an Alpine image built against this machine gets no board support
# rather than force-resolving Debian package names into a musl closure.
#
# PROJECT CONSTRAINT: A PROJECT SELECTING THIS MACHINE MUST BE ALL-APT.
# image() resolves the machine kernel eagerly, at image-definition time,
# for every image in every loaded module — not just the image being
# built. So the moment this machine is selected (defaults.machine,
# local.star, or `yoe build --machine`), an Alpine image anywhere in the
# module set is evaluated against a kernel that exists only in a Debian
# feed, and project evaluation fails before any build starts:
#
#   evaluating cache/modules/module-alpine/images/bun-image.star:
#   image bun-image: machine kernel has no entry for distro "alpine"
#
# The flat `unit = "linux-image-…"` form does not avoid this — it just
# trades the message above for an opaque unresolved-name error from
# resolve_closure. `distro_unit` is used here because it names the
# actual problem. @module-jetson sidesteps the whole issue only because
# its `linux-tegra` is a distro-neutral from-source unit; a kernel that
# ships as a Debian package has no such escape.
#
# Until yoe learns to skip kernel resolution for images whose distro the
# selected machine cannot boot, a project targeting this board must not
# load a module that defines Alpine images (drop @module-alpine, or keep
# UNO Q work in its own project).
machine(
    name = "arduino-uno-q",
    arch = "arm64",
    description = "Arduino UNO Q (Qualcomm QRB2210/QCM2290, 'imola')",
    kernel = kernel(
        # Arduino's kernel build, prebuilt in the vendor feed. No
        # defconfig: this is a binary package, not a from-source unit,
        # so there is no configure step to point at one.
        #
        # The name carries the upstream git hash because that is what
        # Arduino publishes — the feed has no `linux-image-arm64`-style
        # metapackage to track instead, and `arduino-unoq` depends on
        # this exact versioned name too. When Arduino ships a new
        # kernel, `yoe update-feeds` in this module surfaces the new
        # package name and this line moves with it.
        distro_unit = {
            "debian": "linux-image-7.0.0-g122c2c22d838",
        },
        provides = "linux",
        # clk_ignore_unused / pd_ignore_unused are mandatory on this
        # SoC, not tuning: TrustZone and the always-on firmware hold
        # clocks and power domains the kernel cannot see refcounts for,
        # and gating them at late_initcall hangs the board.
        # deferred_probe_timeout=30 covers the long probe chain behind
        # the modem and adsp remoteprocs. Both are carried over from the
        # stock /etc/kernel/cmdline.
        #
        # root=PARTLABEL=rootfs rather than the stock root=UUID=…: the
        # factory GPT labels p68 `rootfs`, and a label survives the
        # reflash that a filesystem UUID does not.
        cmdline = "console=ttyMSM0,115200 root=PARTLABEL=rootfs rootfstype=ext4 rootwait rw clk_ignore_unused pd_ignore_unused audit=0 deferred_probe_timeout=30",
    ),
    # Board enablement only. The Arduino product experience —
    # arduino-app-lab, arduino-app-cli, arduino-router, arduino-cli,
    # adbd — is image policy, not board policy; put those in an image's
    # package list (or pull the `arduino-unoq` metapackage there) rather
    # than forcing them into every image built for this board.
    distro_packages = {
        "debian": [
            "arduino-unoq-config",           # board config + customization
            "arduino-unoq-radio-firmware",   # per-PCB-revision WCN3980 board-2.bin
            "arduino-linux-config",          # carrier-board DT overlay tool (fdtoverlay)
            "alsa-ucm-conf",                 # qcom-patched UCM profiles for the QRB2210 audio path
            "firmware-qcom-soc",             # adsp/modem/wlanmdsp/a702_zap — remoteprocs stay down without it
            "firmware-atheros",              # WCN3990 ath10k Wi-Fi/BT firmware
        ],
    },
    partitions = [
        # Sizes match the factory GPT so a partition image produced here
        # can be fastboot-flashed straight into its slot. Do not grow
        # them past these values without re-partitioning the eMMC.
        partition(label = "efi", type = "vfat", size = "512M"),
        partition(label = "rootfs", type = "ext4", size = "10G", root = True),
    ],
)
