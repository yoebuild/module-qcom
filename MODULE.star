module_info(
    name = "qcom",
    description = "Qualcomm SoC board support: wraps the Arduino BSP apt repo (kernel, device trees, radio firmware, board config for QRB2210/QCM2290 boards) as yoe units, and will carry the machine definitions and boot units for those boards. Packages here layer on top of @module-debian's trixie feeds and share its glibc ABI — the suite pinned below MUST match @module-debian's _DEBIAN_SUITE.",
)

# The Arduino UNO Q (and its sibling Ventun Q) is a Qualcomm QRB2210 /
# QCM2290 board running stock Debian trixie. Everything board-specific
# ships from one small vendor apt repo, apt-repo.arduino.cc — the
# patched kernel with the arduino,imola device trees, the WCN3980 board
# data file, the carrier-board DT overlay tool, and the userspace
# runtime. The rest of the rootfs is plain Debian trixie + backports,
# which @module-debian already covers.
#
# So this module declares one apt_feed rather than a from-source BSP:
# the vendor packages are prebuilt, signed, and ABI-coupled to Debian
# trixie. apt_feed registers a synthetic module named
# "<parent>.<feed-name>", so consumers reference these packages as
# "qcom.arduino" in prefer_modules. Units materialize lazily as the
# runtime closure references them.
#
# DISTRO IS "debian", NOT "qcom". The distro kwarg is stamped on every
# unit apt_feed synthesizes and picks the rootfs-assembly backend and
# the resolver namespace. These packages are built against Debian
# trixie's glibc and depend on Debian packages by name; they must land
# in the same closure as @module-debian's units, so they declare the
# same distro. "qcom" is the module, not a distro.
#
# BOTH ARCHES ARE DECLARED, THOUGH ONLY ARM64 IS BOARD SUPPORT. The repo
# publishes the arm64 BSP plus amd64/i386/armel/armhf builds of the
# host-side Arduino tooling (arduino-cli and friends). Only arm64
# matters for this module's purpose.
#
# amd64 is declared anyway because it must be. The `arches` kwarg is
# validated non-empty at parse time but is never consulted at lookup
# time: the resolver consults every synthetic module for every
# unresolved name, and the feed loads feeds/<index>/<arch>/Packages
# unconditionally for whatever arch is active. A feed missing an index
# for an arch the project builds therefore hard-errors on any name it
# was merely being *asked* about —
#
#   synthetic module "qcom.arduino" lookup "py3-pip":
#   apt_feed: load .../feeds/arduino/amd64/Packages: no such file
#
# — which breaks unrelated x86_64 builds. Until a feed can legitimately
# declare a single arch, every apt_feed ships an index per supported
# arch, as @module-debian and @module-ubuntu do.
#
# To refresh the in-tree Packages file after Arduino ships an update,
# run `yoe update-feeds` in this module's root. That fetches the feed's
# InRelease, verifies the signature against
# keys/arduino-release-keyring.gpg, and atomically rewrites
# feeds/arduino/<arch>/Packages. See README.md "Maintainer playbook".

_ARDUINO_REPO = "https://apt-repo.arduino.cc"
_ARDUINO_SUITE = "stable"

apt_feed(
    name = "arduino",
    distro = "debian",
    url = _ARDUINO_REPO,
    suite = _ARDUINO_SUITE,
    component = "main",
    arches = ["amd64", "arm64"],
    index = "feeds/arduino",
    keyring = "keys/arduino-release-keyring.gpg",
)
