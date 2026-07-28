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
# The single `debian` key in `distro_unit` below is the load-bearing
# declaration of that fact: yoe reads a machine's kernel distro_unit keys
# as the set of distros the board can boot. Images targeting any other
# distro are registered not-buildable on this machine — no kernel
# resolution, no closure walk — so a project selecting this board may
# still load @module-alpine and evaluate cleanly. Naming such an image in
# a build is refused with the reason; an unnamed full build skips it with
# a notice.
#
# Use `distro_unit` here rather than the flat `unit = "linux-image-…"`
# form even though only one distro is listed. The flat form asserts the
# kernel works on every distro, which for a vendor .deb is false, and
# yoe would take it at its word — an Alpine image would then fail on an
# opaque unresolved-name error from resolve_closure instead of being
# marked. @module-jetson can use the flat form only because its
# `linux-tegra` really is a distro-neutral from-source unit.
#
# Practical note: a project whose defaults.distro is not `debian` needs
# `--distro debian` (or a local.star override) when building for this
# board, or its images evaluate for the wrong distro and get marked.
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
            # A/B SLOT BLESSING — DO NOT DROP THIS.
            # Every vendor partition on this board is A/B, and the Qualcomm
            # boot firmware treats a boot as provisional until userspace
            # marks the slot good. qbootctl's service runs `qbootctl -m`
            # after boot-complete.target to do exactly that. Without it the
            # firmware exhausts its retry count, switches to the other slot,
            # and the board stops booting — a failure that looks like a brick
            # and appears several reboots after the image that caused it.
            # Debian ships the package and its postinst enables the service.
            "qbootctl",
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
