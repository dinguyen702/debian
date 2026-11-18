#!/bin/bash
# =============================================================================
# Agilex 5 HPS Debian Linux Example Script
# =============================================================================
#
# PURPOSE:
# This script builds an SD card boot image for Altera Agilex 5 HPS systems to
# start Debian.
# The SD card image produced from this script will demonstrate the HPS first boot flow
#
# USAGE:
#   ./mk_debian_sd.sh [-c debconf.sh]
#
# OUTPUT:
#   sdcard_agilex5.img - Ready to write to SD card
#
# The SD card image is assembled from regular files, so no root
# privileges are needed to run this script. Only python3, mtools and
# e2fsprogs are required. Partition 1 is FAT16 with the BPB guestfish
# produced (spt 62, heads 133, hidden sectors = partition start). SPL
# rejected a FAT with mkfs.vfat's default geometry (fat register err -1).
#
# =============================================================================

set -e  # Exit on any error

# e2fsprogs puts e2fsck, resize2fs and debugfs in /usr/sbin, which is
# often missing from a non-root PATH.
PATH="/usr/sbin:/sbin:${PATH}"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Build configuration
declare -r OUTPUT_DIR="./build_output"
declare -r OUTPUT_DIR_ABS="$(readlink -f ${OUTPUT_DIR})"
declare -r JOBS=$(nproc)
declare -r _BRANCH="work"

declare -r DEF_CONFIG_FILE="debconf.sh"
declare -r CONFIG_MANDATORY="ATF_REPO ATF_REF UBOOT_REPO UBOOT_REF LINUX_REPO LINUX_REF"
declare -r CONFIG_OPTIONAL="UBOOT_ITS_FILE UBOOT_ITS_URL UBOOT_SCRIPT_FILE UBOOT_SCRIPT_URL FABRIC_RBF_FILE FABRIC_RBF_URL BOARD_ID"

# Component URLs and settings
# Using the musl compiler to make a tight, statically linked Linux environment
declare -r TOOLCHAIN_URL="https://github.com/cross-tools/musl-cross/releases/download/20250929/aarch64-unknown-linux-musl.tar.xz"
declare -r TOOLCHAIN_DIR="aarch64-unknown-linux-musl"

declare -r ATF_DIR="arm-trusted-firmware"
declare -r UBOOT_DIR="u-boot-socfpga"
declare -r LINUX_DIR="linux-socfpga"
declare -r LINUX_LM_DIR="${LINUX_DIR}_modules"

# Agilex 5 SoC Development Kit
declare -r ATF_PLAT="agilex5"
declare -r UBOOT_DEFCONFIG="socfpga_agilex5_defconfig"
declare -r UBOOT_DTSI="arch/arm/dts/socfpga_agilex5_socdk-u-boot.dtsi"
declare -r LINUX_DTB="intel/socfpga_agilex5_socdk.dtb"
declare -r LINUX_DTB_NAME="socfpga_agilex5_socdk.dtb"

# Standard DDR load address for Linux kernel
declare -r KERNEL_LOAD="0x90000000"

declare -r DEF_UBOOT_ITS_FILE="uboot_script.its"
declare -r DEF_UBOOT_ITS_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/wrynose/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${DEF_UBOOT_ITS_FILE}"
declare -r DEF_UBOOT_SCRIPT_FILE="uboot.txt"
declare -r DEF_UBOOT_SCRIPT_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/wrynose/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${DEF_UBOOT_SCRIPT_FILE}"

declare -r DEF_FABRIC_RBF_FILE=""
declare -r DEF_FABRIC_RBF_URL=""
# FIT configuration name is board-${BOARD_ID}; the boot script uses the
# same value when U-Boot has no board_id in the environment.
declare -r DEF_BOARD_ID="0"

declare -r DEBIAN_NAME="trixie"
declare -r DEBIAN_VERSION="13"
# The tarball contains disk.raw.
declare -r DEBIAN_ARCHIVE="debian-13-nocloud-arm64-20260623-2518.tar.xz"
declare -r DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/20260623-2518/${DEBIAN_ARCHIVE}"

# Created from DEBIAN_PASS when missing, then copied over the image's /etc/shadow
# so the root account can log in.
declare -r DEBIAN_SHADOW_FILE="etc/shadow"
# the default fstab file provided with the nocloud image includes
# PARTUUID's that are not relevant. The file below replaces it
declare -r DEBIAN_FSTAB_FILE="etc/fstab"

# the credentials below are of no security issue
declare -r DEBIAN_USER="root"
declare -r DEBIAN_PASS="fpga1983"

# use this variable to set a different timezone than the system
# e.g. America/Chicago
declare -r DEBIAN_TIMEZONE=""

declare -r SZ_KB=1024
declare -r SZ_MB=$((${SZ_KB}*${SZ_KB}))
declare -r SZ_GB=$((${SZ_MB}*${SZ_KB}))

# sizes in bytes
declare -r SDIMG="sdcard_agilex5.img"
declare -r SDCARD_IMG_SIZE=$((2*SZ_GB))
# agilex5_image.cfg: image boot.vfat { size = 64M }
declare -r BOOT_PART_SIZE=$((64*${SZ_MB}))
# Layout from agilex5_image.cfg. genimage's empty hdimage aligns to 1MiB
# (sector 2048). Type 0xc bootable FAT, type 0x83 rootfs.
declare -r BOOT_PART_SECTOR_START=2048
# Rootfs fills the remainder of the image after the boot partition.
declare -r RFS_PART_SIZE=$(( SDCARD_IMG_SIZE - BOOT_PART_SECTOR_START * 512 - BOOT_PART_SIZE ))
declare -r IMAGE_CFG="agilex5_image.cfg"

# =============================================================================
# HELPERS AND FUNCTIONS
# =============================================================================

declare -r BOOT_PART_SECTORS=$(( ${BOOT_PART_SIZE} / 512 ))
declare -r RFS_PART_SECTOR_START=$(( ${BOOT_PART_SECTOR_START} + ${BOOT_PART_SECTORS} ))
declare -r RFS_PART_SECTORS=$(( ${RFS_PART_SIZE} / 512 ))
# FAT BPB geometry guestfish wrote for a known-good Agilex SD image; SPL's
# fat_set_blk_dev rejected default 16/32 heads/spt.
declare -r FAT_BPB_HEADS=133
declare -r FAT_BPB_SPT=62

# abs paths to files, handy later
declare _DEBIAN_SHADOW_FILE="$(readlink -f ${DEBIAN_SHADOW_FILE})"
declare _DEBIAN_FSTAB_FILE="$(readlink -f ${DEBIAN_FSTAB_FILE})"

# usage
declare -r SELF="$(basename $0)"

function usage() {

    cat <<EOH
Builds an Agilex 5 SD card image with an unmodified Debian run time.

Usage: ${SELF} [-h] [-c <file>]
    -h: prints this message
    -c: specifies a configuration file to use.

Configuration file

Must include the following mandatory variables:
${CONFIG_MANDATORY}

  - Prefixes:
     - ATF, UBOOT, LINUX refer respectively to Arm Trusted Firmware, U-Boot and the Linux kernel
  - The suffixes:
     _REPO: provides the URL of the repo
     _REF: reference to checkout, can be a tag, a branch or a SHA in short or long form

Failure to set these mandatory variables will cause the script to stop.

The configuration file may include the following variables (default values shown):
EOH

    for var in ${CONFIG_OPTIONAL} ; do

	declare -n p="DEF_${var}"

	echo ${var} '('${p:-"''"}')'
    done

    echo
    
    return 0
}

# download <url> <local file name>
function download() {

    local archive="${2}"
    local url="${1}"
    local err=0

    if /usr/bin/curl --version >/dev/null 2>&1; then
        /usr/bin/curl -fL --progress-bar -o "${archive}" "${url}" || return $?
    elif /usr/bin/wget --version >/dev/null 2>&1; then
        /usr/bin/wget -O "${archive}" "${url}" || return $?
    else
        echo "ERROR: Neither wget nor curl found. Please install one of them." >&2
        return 1
    fi
    return ${err}
}

function check_config () {

   local err=0

   for cfg_var in ${CONFIG_MANDATORY} ; do
       declare -n p=${cfg_var}

       if [ -z ${p} ] ; then
	   echo "${FUNCNAME}: error: mandatory config variable ${cfg_var} is not set"
	   err=1
       fi
   done

   return ${err}
}

function clone_and_checkout() {

    local repo_url="${1}"
    local repo_ref="${2}"
    local dir="${3}"
    local sha

    if [ -z ${repo_url} -o -z ${repo_ref} -o -z ${dir} ] ; then
	echo "${FUNCNAME}: missing argument..." >&2
	return 1
    fi

    mkdir "${dir}" && cd "${dir}"

    git clone ${repo_url} ../"${dir}"

    if ! sha=$(git rev-parse --quiet --verify "${repo_ref}") ; then
	if ! sha=$(git rev-parse --quiet --verify "origin/${repo_ref}") ; then
            echo "${FUNCNAME}: error: ${repo_ref}: invalid reference for repo ${repo_url}" >&2
	    return 1
	fi
    fi

    git checkout -b ${_BRANCH} "${sha}"

    cd ..

    return 0

}

# Create an etc/shadow with a usable root password when the file is not already present.
function create_root_shadow() {

    local hash
    local days

    if [[ -f ${_DEBIAN_SHADOW_FILE} ]]; then
        return 0
    fi

    if ! hash=$(openssl passwd -6 "${DEBIAN_PASS}"); then
        echo "error: failed to hash the root password" >&2
        return 1
    fi

    days=$(( $(date +%s) / 86400 ))
    mkdir -p "$(dirname "${_DEBIAN_SHADOW_FILE}")"
    printf 'root:%s:%s:0:99999:7:::\n' "${hash}" "${days}" > "${_DEBIAN_SHADOW_FILE}"
    chmod 0640 "${_DEBIAN_SHADOW_FILE}"

    return 0
}

# rootfs_has <ext4 image> <path>: succeeds when <path> exists in the image
function rootfs_has() {

    debugfs -R "stat \"${2}\"" "${1}" 2>/dev/null | grep -q '^Inode:'
}

# ext4_has_magic <file> [byte offset]: succeeds when an ext4 superblock
# is at that offset (magic 0xEF53 at +0x438).
function ext4_has_magic() {

    python3 - "${1}" "${2:-0}" <<'PY'
import struct
import sys

path = sys.argv[1]
off = int(sys.argv[2], 0)
with open(path, "rb") as f:
    f.seek(off + 0x438)
    sys.exit(0 if f.read(2) == b"\x53\xef" else 1)
PY
}

# ext4_clear_orphan_file <ext4 image>: clear Debian 13's orphan_file compat
# feature (FEATURE_C12) on every backup superblock so host e2fsprogs 1.46.x
# can e2fsck/resize2fs the image. Updates superblock checksums in place.
function ext4_clear_orphan_file() {

    python3 - "${1}" <<'PY'
import struct
import sys

ORPHAN_FILE = 0x1000  # EXT4_FEATURE_COMPAT_ORPHAN_FILE
path = sys.argv[1]

def crc32c_table():
    poly = 0x82F63B78
    table = []
    for i in range(256):
        crc = i
        for _ in range(8):
            crc = (crc >> 1) ^ poly if crc & 1 else crc >> 1
        table.append(crc)
    return table

CRC32C_T = crc32c_table()

def crc32c_le(crc, data):
    for b in data:
        crc = CRC32C_T[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc

def sb_crc(sb):
    return crc32c_le(0xFFFFFFFF, bytes(sb[:0x3FC]))

def is_backup_group(g, groups):
    if g in (0, 1):
        return True
    for p in (3, 5, 7):
        x = p
        while x < groups:
            if x == g:
                return True
            if x > g:
                break
            x *= p
    return False

with open(path, "r+b") as f:
    f.seek(1024)
    sb = bytearray(f.read(1024))
    if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
        sys.exit("ext4_clear_orphan_file: no ext4 superblock")
    log_bs = struct.unpack_from("<I", sb, 0x18)[0]
    bs = 1024 << log_bs
    blocks = struct.unpack_from("<I", sb, 0x04)[0]
    blocks |= struct.unpack_from("<I", sb, 0x150)[0] << 32
    bpg = struct.unpack_from("<I", sb, 0x20)[0]
    groups = (blocks + bpg - 1) // bpg
    for g in range(groups):
        if not is_backup_group(g, groups):
            continue
        off = 1024 if g == 0 else g * bpg * bs
        f.seek(off)
        sb = bytearray(f.read(1024))
        if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
            continue
        compat = struct.unpack_from("<I", sb, 0x5C)[0]
        if not (compat & ORPHAN_FILE):
            continue
        struct.pack_into("<I", sb, 0x5C, compat & ~ORPHAN_FILE)
        struct.pack_into("<I", sb, 0x3FC, sb_crc(sb))
        f.seek(off)
        f.write(sb)
sys.exit(0)
PY
}

# debian_root_partition <disk.raw>: prints "start sectors" of the largest
# ext4 partition. The nocloud image is GPT: p1 is Linux root, p15 is EFI.
function debian_root_partition() {

    local disk="${1}"
    local start
    local sectors
    local best_start=""
    local best_sectors=0

    while read -r start sectors ; do
        [[ -n ${start} && -n ${sectors} ]] || continue
        if ext4_has_magic "${disk}" $(( start * 512 )) ; then
            if [[ ${sectors} -gt ${best_sectors} ]]; then
                best_start=${start}
                best_sectors=${sectors}
            fi
        fi
    done < <(partx -g -o START,SECTORS "${disk}")

    if [[ -z ${best_start} ]]; then
        if ext4_has_magic "${disk}" 0 ; then
            echo "0 $(( $(stat -c%s "${disk}") / 512 ))"
            return 0
        fi
        return 1
    fi

    echo "${best_start} ${best_sectors}"
}


# rootfs_tree_cmds <host dir> <image dir>: prints the debugfs commands that
# copy the content of <host dir> into the existing <image dir>
function rootfs_tree_cmds() {

    local src="${1}"
    local dst="${2}"
    local type
    local path

    (cd "${src}" && find . -mindepth 1 -printf '%y %P\n') | while read -r type path ; do
        case "${type}" in
            d) echo "mkdir \"${dst}/${path}\"" ;;
            f) echo "write \"${src}/${path}\" \"${dst}/${path}\"" ;;
            l) echo "symlink \"${dst}/${path}\" \"$(readlink "${src}/${path}")\"" ;;
            *) echo "${FUNCNAME}: error: unsupported file type: ${src}/${path}" >&2
               return 1 ;;
        esac
    done
}

# Write a DOS MBR: a zeroed 440-byte bootstrap area, a disk signature,
# and up to four partitions. Each partition is start,size,type,bootable
# (type may be 0xNN).
function write_dos_mbr() {

    python3 - "$@" <<'PY'
import os
import struct
import sys

# Unused on Agilex (SPL/U-Boot do not run x86 MBR code).
BOOTSTRAP = bytes(440)

# 255 heads, 63 spt. Overflow CHS matches parted (fe c2 ff).
HEADS = 255
SPT = 63
CHS_LIMIT = 1024 * HEADS * SPT


def pack_chs(lba):
    if lba >= CHS_LIMIT:
        c, h, s = 1023, 254, 2
    else:
        c = lba // (HEADS * SPT)
        rem = lba % (HEADS * SPT)
        h = rem // SPT
        s = rem % SPT + 1
    return bytes((h & 0xFF, (s & 0x3F) | ((c >> 2) & 0xC0), c & 0xFF))


def pack_part(start, size, ptype, bootable):
    last = start + size - 1
    return struct.pack(
        "<B3sB3sII",
        0x80 if bootable else 0x00,
        pack_chs(start),
        ptype,
        pack_chs(last),
        start,
        size,
    )


path = sys.argv[1]
args = sys.argv[2:]
if len(args) % 4 != 0 or not 1 <= len(args) // 4 <= 4:
    sys.exit("write_dos_mbr: expected 1-4 partitions as start size type bootable")

table = bytearray()
for i in range(0, len(args), 4):
    start = int(args[i], 0)
    size = int(args[i + 1], 0)
    ptype = int(args[i + 2], 0)
    bootable = int(args[i + 3], 0)
    table += pack_part(start, size, ptype, bootable)
table += b"\x00" * (64 - len(table))

with open(path, "r+b") as f:
    f.write(BOOTSTRAP)
    f.write(os.urandom(4))
    f.write(b"\x00\x00")
    f.write(table)
    f.write(b"\x55\xaa")
PY
}

# Debian 13 ext4 enables orphan_file (compat feature bit 12). Host e2fsck
# 1.46.x does not know that feature and exits 8.
function e2fsck_rootfs() {

    local img="${1}"
    local log
    local st

    if ! command -v e2fsck >/dev/null 2>&1 ; then
        echo "warning: e2fsck not found; skipping fsck" >&2
        return 0
    fi

    log=$(mktemp)
    set +e
    e2fsck -fy "${img}" >"${log}" 2>&1
    st=$?
    set -e
    if [[ ${st} -le 1 ]]; then
        rm -f "${log}"
        return 0
    fi
    if grep -q 'unsupported feature' "${log}"; then
        echo "warning: host e2fsck is too old for this Debian ext4 image; skipping fsck" >&2
        rm -f "${log}"
        return 0
    fi
    cat "${log}" >&2
    rm -f "${log}"
    return "${st}"
}

# True when PATH entry is a ccache wrapper (often /usr/lib/ccache/gcc -> ccache).
# Using that as HOSTCC makes make pass -W... to ccache, which errors.
function cc_is_ccache() {

    local real

    real=$(readlink -f "${1}")
    [[ $(basename "${real}") == ccache ]]
}

function cc_can_link() {

    [[ $("${1}" -print-file-name=crt1.o 2>/dev/null) == /* ]]
}

# Print the first executable named like gcc/cc that is not a ccache wrapper.
# $1 is an optional explicit compiler (HOSTCC/HOSTCXX); remaining args are
# names to search on PATH.
function lookup_host_compiler() {

    local hint="${1:-}"
    local name
    local dir
    local cand
    local IFS
    shift || true

    if [[ -n ${hint} ]]; then
        if [[ -x ${hint} ]]; then
            cand="${hint}"
        else
            cand=$(command -v "${hint}" 2>/dev/null || true)
        fi
        if [[ -n ${cand} && -x ${cand} ]] && ! cc_is_ccache "${cand}" && cc_can_link "${cand}"; then
            echo "${cand}"
            return 0
        fi
    fi

    IFS=:
    for name in "$@" ; do
        for dir in ${PATH} ; do
            [[ -n ${dir} ]] || continue
            cand="${dir}/${name}"
            [[ -x ${cand} ]] || continue
            if cc_is_ccache "${cand}" || ! cc_can_link "${cand}"; then
                continue
            fi
            echo "${cand}"
            return 0
        done
    done
    return 1
}

# Resolve a native host compiler to an absolute path. Do this before the
# cross toolchain is prepended to PATH so make's host tools are not built
# with the musl compiler. Prefers HOSTCC/HOSTCXX if already set.
function find_host_cc() {

    if ! HOSTCC=$(lookup_host_compiler "${HOSTCC:-}" gcc cc); then
        echo "error: no host C compiler found (set HOSTCC, or install gcc/cc)" >&2
        return 1
    fi

    if ! HOSTCXX=$(lookup_host_compiler "${HOSTCXX:-}" g++ c++); then
        HOSTCXX="${HOSTCC}"
    fi

    [[ ${HOSTCC} == /* ]] || HOSTCC="${PWD}/${HOSTCC}"
    [[ ${HOSTCXX} == /* ]] || HOSTCXX="${PWD}/${HOSTCXX}"

    return 0
}

# =============================================================================
# CLI 
# =============================================================================
declare CONFIG_FILE="${DEF_CONFIG_FILE}"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        -h)
            usage
            exit 0
            ;;
        -c)
            shift
            CONFIG_FILE="${1:-}"
            if [[ -z "${CONFIG_FILE}" || ! -f "${CONFIG_FILE}" ]]; then
                echo "error: no config file given or was not found" >&2
                exit 1
            fi
            ;;
        *)
            echo "error: unknown argument: ${1}" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

echo "======================================================================"
echo "   Agilex 5 HPS SD Card Boot Flow Builder"
echo "======================================================================"

# =============================================================================
# CHECK CONFIG
# =============================================================================
echo "[STEP] configuring from ${CONFIG_FILE}..."
source "${CONFIG_FILE}"

if ! check_config ; then
    echo "Please check your configuration in ${CONFIG_FILE}..."
    exit 127
fi

# for the optional variables, we pickup the default value if 
# not set in config file
UBOOT_ITS_FILE=${UBOOT_ITS_FILE:-${DEF_UBOOT_ITS_FILE}}
UBOOT_ITS_URL=${UBOOT_ITS_URL:-${DEF_UBOOT_ITS_URL}}
UBOOT_SCRIPT_FILE=${UBOOT_SCRIPT_FILE:-${DEF_UBOOT_SCRIPT_FILE}}
UBOOT_SCRIPT_URL=${UBOOT_SCRIPT_URL:-${DEF_UBOOT_SCRIPT_URL}}
FABRIC_RBF_FILE=${FABRIC_RBF_FILE:-${DEF_FABRIC_RBF_FILE}}
FABRIC_RBF_URL=${FABRIC_RBF_URL:-${DEF_FABRIC_RBF_URL}}
BOARD_ID=${BOARD_ID:-${DEF_BOARD_ID}}

# =============================================================================
# BUILD PROCESS
# =============================================================================

echo "[STEP] Setting up build environment..."

if ! find_host_cc ; then
    exit 1
fi
declare -rx HOSTCC HOSTCXX

# Create and enter build directory
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

# Set environment variables, read-only and exported
declare -rx ARCH=arm64
declare -rx CROSS_COMPILE="${PWD}/${TOOLCHAIN_DIR}/bin/aarch64-unknown-linux-musl-"

echo "Build directory: ${PWD}"
echo "Architecture: ${ARCH}"
echo "Host compiler: ${HOSTCC}"
echo "Cross compiler: ${CROSS_COMPILE}"

# =============================================================================
# DOWNLOAD AND SETUP TOOLCHAIN
# =============================================================================

echo "[STEP] Setting up ARM GNU toolchain..."

TOOLCHAIN_ARCHIVE="${TOOLCHAIN_DIR}.tar.xz"

if [[ ! -d "${TOOLCHAIN_DIR}" ]]; then
    if [[ ! -f "${TOOLCHAIN_ARCHIVE}" ]]; then
        echo "Downloading ARM GNU toolchain..."
        if ! download "${TOOLCHAIN_URL}" "${TOOLCHAIN_ARCHIVE}" ; then
	    echo "error: failed to download the ARM GNU toolchain (${TOOLCHAIN_ARCHIVE})"
	    exit 1
        fi
    fi

    echo "Extracting ARM GNU toolchain..."
    tar -xf "${TOOLCHAIN_ARCHIVE}"

    # Verify toolchain
    if [[ ! -x "${TOOLCHAIN_DIR}/bin/aarch64-unknown-linux-musl-gcc" ]]; then
        echo "ERROR: ARM toolchain verification failed"
        exit 1
    fi

    echo "ARM toolchain setup complete"
else
    echo "ARM toolchain already downloaded"
fi

# Add toolchain to the path
export PATH=${PWD}/${TOOLCHAIN_DIR}/bin:$PATH

# =============================================================================
# BUILD ARM TRUSTED FIRMWARE
# =============================================================================

echo "[STEP] Building ARM Trusted Firmware (ATF)..."

if [[ ! -d "${ATF_DIR}" ]]; then
    clone_and_checkout "${ATF_REPO}" "${ATF_REF}" "${ATF_DIR}"
fi

cd "${ATF_DIR}"

# Clean and build ATF
make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" clean
make -j "${JOBS}" HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" PLAT="${ATF_PLAT}" bl31 ENABLE_LTO=

cd ..

echo "ATF build complete"


# =============================================================================
# BUILD U-BOOT
# =============================================================================

echo "[STEP] Building U-Boot bootloader..."

if [[ ! -d "${UBOOT_DIR}" ]]; then
    clone_and_checkout "${UBOOT_REPO}" "${UBOOT_REF}" "${UBOOT_DIR}"
fi

cd "${UBOOT_DIR}"

# Enable debug info for compatibility
sed -i 's/PLATFORM_CPPFLAGS += -D__ARM__/PLATFORM_CPPFLAGS += -D__ARM__ -gdwarf-4/g' arch/arm/config.mk

# Configure for SD card boot
sed -i 's/u-boot,spl-boot-order.*/u-boot,spl-boot-order = \&mmc;/g' "${UBOOT_DTSI}"

# Build U-Boot
make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" clean && make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" mrproper
make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" "${UBOOT_DEFCONFIG}"

# Link directly to ATF bl31.bin in its build directory
ln -sf "../${ATF_DIR}/build/${ATF_PLAT}/release/bl31.bin" .

make -j "${JOBS}" HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}"

# spl hex file is needed when JIC file is created. Copy it at a known location
cp spl/u-boot-spl-dtb.hex ${OUTPUT_DIR_ABS} 

cd ..

echo "U-Boot build complete"

# =============================================================================
# GET UBOOT SCRIPT
# =============================================================================
echo "[STEP] Getting uboot script ..."

# get the updated uboot_script.its everytime
rm -f "${UBOOT_ITS_FILE}"

echo "downloading from ${UBOOT_ITS_URL}"
if ! download "${UBOOT_ITS_URL}" "${UBOOT_ITS_FILE}" ; then
	echo "error: failed to download ${UBOOT_ITS_FILE}"
	exit 3
fi

# get the updated uboot.txt everytime
rm -f "${UBOOT_SCRIPT_FILE}"
if ! download "${UBOOT_SCRIPT_URL}" "${UBOOT_SCRIPT_FILE}" ; then
	echo "error: failed to download ${UBOOT_SCRIPT_FILE}"
	exit 3
fi

# The script does bootm ${loadaddr}#board-${board_id}. Set a
# default when the environment does not already have one.
{
       echo "if test -z \"\${board_id}\"; then setenv board_id ${BOARD_ID}; fi"
       cat "${UBOOT_SCRIPT_FILE}"
} > "${UBOOT_SCRIPT_FILE}.new"
mv "${UBOOT_SCRIPT_FILE}.new" "${UBOOT_SCRIPT_FILE}"

mkimage -f "${UBOOT_ITS_FILE}" boot.scr.uimg

echo "Created boot.scr.uimg"

# =============================================================================
# BUILD LINUX KERNEL
# =============================================================================

echo "[STEP] Building Linux kernel..."

rm -rf ${LINUX_LM_DIR} && mkdir ${LINUX_LM_DIR}
_LINUX_LM_DIR_ABS="$(readlink -f ${LINUX_LM_DIR})"

if [[ ! -d "${LINUX_DIR}" ]]; then
    clone_and_checkout "${LINUX_REPO}" "${LINUX_REF}" "${LINUX_DIR}"
fi

cd "${LINUX_DIR}"

# Create custom config fragment for networking
cat > config-fragment-agilex5 << 'EOF'
# Enable Ethernet connectivity
CONFIG_MARVELL_PHY=y
EOF

# Configure and build kernel
make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" defconfig
./scripts/kconfig/merge_config.sh -m -O ./ ./.config ./config-fragment-agilex5
make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" olddefconfig
make -j "${JOBS}" HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" Image && make HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" "${LINUX_DTB}"
make -j "${JOBS}" HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" modules
make -j "${JOBS}" HOSTCC="${HOSTCC}" HOSTCXX="${HOSTCXX}" modules_install INSTALL_MOD_PATH="${_LINUX_LM_DIR_ABS}"

cd ${_LINUX_LM_DIR_ABS}
# Debian merges /lib into /usr/lib. A tarball rooted at lib/ replaces that
# symlink, which removes /lib/systemd. Place modules under usr/lib instead.
mkdir -p usr
rm -rf usr/lib
mv lib usr/lib

cd ..

echo "Linux kernel build complete"

# =============================================================================
# CREATE KERNEL.ITS
# =============================================================================
xz --threads=${JOBS} --format=lzma -f -k ${LINUX_DIR}/arch/arm64/boot/Image

echo "[STEP] Creating kernel.its & kernel.itb"

#create a minimal kernel.its file
cat > kernel_test.its <<EOF

/dts-v1/;

/ {

    description = "FIT image with custom kernel and DTB";

    #address-cells = <1>;

    images {

        kernel {

            description = "Linux Kernel";

            data = /incbin/("${LINUX_DIR}/arch/arm64/boot/Image.lzma");

            type = "kernel";

            arch = "arm64";

            os = "linux";

            compression = "lzma";

            load = <${KERNEL_LOAD}>;

            entry = <${KERNEL_LOAD}>;

            hash-1 { algo = "crc32"; };

        };

        fdt-0 {

            description = "${LINUX_DTB_NAME%.dtb}";

            data = /incbin/("${LINUX_DIR}/arch/arm64/boot/dts/${LINUX_DTB}");

            type = "flat_dt";

            arch = "arm64";

            compression = "none";

            hash-1 { algo = "crc32"; };

        };
EOF

if [[ -n "${FABRIC_RBF_FILE}" && -n "${FABRIC_RBF_URL}" ]]; then
    if [ ! -e "${FABRIC_RBF_FILE}" ] ; then
        download "${FABRIC_RBF_URL}" "${FABRIC_RBF_FILE}"
    else
	echo "Fabric file already downloaded"
    fi

    cat >> kernel_test.its <<EOF

        fpga-0 {

            description = "fpga_fabric_data";

	    data = /incbin/("${FABRIC_RBF_FILE}");

            type = "fpga";

            arch = "arm64";

            compression = "none";

            hash-1 { algo = "crc32"; };

        };
EOF
fi

cat >> kernel_test.its <<EOF
    };

    configurations {

        default = "board-${BOARD_ID}";

        board-${BOARD_ID} {

            description = "board_${BOARD_ID}";

            kernel = "kernel";

            fdt = "fdt-0";
EOF

if [[ -n "${FABRIC_RBF_FILE}" && -n "${FABRIC_RBF_URL}" ]]; then
    cat >> kernel_test.its <<EOF

            fpga = "fpga-0";
EOF
fi

cat >> kernel_test.its <<EOF

            hash-1 { algo = "crc32"; };

        };

    };

};
EOF

#create kernel.itb
mkimage -f kernel_test.its kernel.itb

echo "Created kernel.itb" 

## =============================================================================
## DOWNLOAD DEBIAN
## =============================================================================

echo "[STEP] Download root filesystem..."


if [[ ! -f "${DEBIAN_ARCHIVE}" ]]; then
    echo "Download Debian archive"
    if ! download "${DEBIAN_URL}" "${DEBIAN_ARCHIVE}" ; then
        echo "error: failed to download the Debian archive (${DEBIAN_ARCHIVE})"
        exit 2
    fi
else
    echo "Debian archive previously downloaded"
fi

# the archive contains the file 'disk.raw' that we'll use
# to extract the root file system
tar xfJ "${DEBIAN_ARCHIVE}"

echo "Debian download complete"

## =============================================================================
## CREATE SD CARD IMAGE
## =============================================================================
#
echo "[STEP] Creating SD card image..."

if ! command -v debugfs >/dev/null 2>&1 ; then
    echo "error: debugfs not found (install e2fsprogs)" >&2
    exit 1
fi

if ! create_root_shadow ; then
    exit 1
fi

BOOT_IMG="boot.vfat"
RFS_IMG="rootfs.ext4"
RFS_CMDS="rootfs.debugfs"

echo "Assembling ${SDIMG} from ${IMAGE_CFG}"

rm -f "${SDIMG}"
truncate -s ${SDCARD_IMG_SIZE} "${SDIMG}"
write_dos_mbr "${SDIMG}" \
    "${BOOT_PART_SECTOR_START}" "${BOOT_PART_SECTORS}" 0x0c 1 \
    "${RFS_PART_SECTOR_START}" "${RFS_PART_SECTORS}" 0x83 0

# 64M FAT, files from agilex5_image.cfg plus kernel.itb and boot.scr.uimg
# for the debian FIT boot script.
rm -f "${BOOT_IMG}"
truncate -s ${BOOT_PART_SIZE} "${BOOT_IMG}"
MTOOLS_SKIP_CHECK=1 mformat -C -i "${BOOT_IMG}" \
    -T ${BOOT_PART_SECTORS} -h ${FAT_BPB_HEADS} -s ${FAT_BPB_SPT} \
    -H ${BOOT_PART_SECTOR_START} ::
MTOOLS_SKIP_CHECK=1 mcopy -i "${BOOT_IMG}" \
    "${LINUX_DIR}/arch/arm64/boot/Image" \
    "${LINUX_DIR}/arch/arm64/boot/dts/${LINUX_DTB}" \
    "${UBOOT_DIR}/u-boot.itb" \
    kernel.itb boot.scr.uimg ::/

dd if="${BOOT_IMG}" of="${SDIMG}" bs=512 seek=${BOOT_PART_SECTOR_START} \
   conv=notrunc status=none
rm -f "${BOOT_IMG}"

if ! read -r rfs_start rfs_sectors < <(debian_root_partition disk.raw) ||
   [[ -z ${rfs_start} || -z ${rfs_sectors} ]]; then
    echo "error: could not find an ext4 root filesystem in disk.raw" >&2
    exit 1
fi
echo "Debian ext4 at sector ${rfs_start}, ${rfs_sectors} sectors"
rm -f "${RFS_IMG}"
dd if=disk.raw of="${RFS_IMG}" bs=4M iflag=skip_bytes,count_bytes \
   skip=$(( ${rfs_start} * 512 )) count=$(( ${rfs_sectors} * 512 )) status=none
if ! ext4_has_magic "${RFS_IMG}" ; then
    echo "error: extracted Debian image is not ext4" >&2
    exit 1
fi
# Fit the filesystem to the MMC partition size when host e2fsprogs can.
# Debian 13 sets orphan_file (FEATURE_C12); clear it so 1.46.x resize2fs works.
ext4_clear_orphan_file "${RFS_IMG}"
e2fsck_rootfs "${RFS_IMG}" || true
if [[ $(stat -c%s "${RFS_IMG}") -gt ${RFS_PART_SIZE} ]]; then
    if ! command -v resize2fs >/dev/null 2>&1 ||
       ! resize2fs "${RFS_IMG}" $(( ${RFS_PART_SIZE} / 1024 ))K >/dev/null 2>&1 ; then
        echo "error: the Debian root file system does not fit in the SD card partition" >&2
        exit 1
    fi
    truncate -s ${RFS_PART_SIZE} "${RFS_IMG}"
elif command -v resize2fs >/dev/null 2>&1 ; then
    truncate -s ${RFS_PART_SIZE} "${RFS_IMG}"
    if ! resize2fs "${RFS_IMG}" >/dev/null 2>&1 ; then
        echo "warning: could not resize the Debian ext4 image to the MMC partition; systemd-growfs will finish this on first boot" >&2
    fi
else
    truncate -s ${RFS_PART_SIZE} "${RFS_IMG}"
    echo "warning: could not resize the Debian ext4 image to the MMC partition; systemd-growfs will finish this on first boot" >&2
fi

shadow_gid=$(debugfs -R "stat /etc/shadow" "${RFS_IMG}" 2>/dev/null | sed -n 's/.*Group: *\([0-9]*\).*/\1/p')

{
    echo "rm /etc/shadow"
    echo "write \"${_DEBIAN_SHADOW_FILE}\" /etc/shadow"
    echo "sif /etc/shadow mode 0100640"
    echo "sif /etc/shadow gid ${shadow_gid:-0}"
    echo "rm /etc/fstab"
    echo "write \"${_DEBIAN_FSTAB_FILE}\" /etc/fstab"
    echo "sif /etc/fstab mode 0100644"
    rootfs_tree_cmds "${_LINUX_LM_DIR_ABS}/usr/lib/modules" /usr/lib/modules
    if rootfs_has "${RFS_IMG}" /init ; then
        echo "rm /init"
    fi
    echo "symlink /init sbin/init"
} > "${RFS_CMDS}"

RFS_LOG="${RFS_CMDS}.log"
if ! debugfs -w -f "${RFS_CMDS}" "${RFS_IMG}" >"${RFS_LOG}" 2>&1 ||
   grep -Eq '^(mkdir|write|symlink|rm|sif):' "${RFS_LOG}" ; then
    cat "${RFS_LOG}" >&2
    echo "ERROR: Failed to update the root file system" >&2
    exit 1
fi
rm -f "${RFS_LOG}"

if ! e2fsck_rootfs "${RFS_IMG}" ; then
    exit 1
fi

for path in /etc/shadow /etc/fstab /usr/lib/modules /init ; do
    if ! rootfs_has "${RFS_IMG}" "${path}" ; then
        echo "ERROR: Failed to update the root file system: missing ${path}" >&2
        exit 1
    fi
done

dd if="${RFS_IMG}" of="${SDIMG}" bs=4M oflag=seek_bytes \
   seek=$(( ${RFS_PART_SECTOR_START} * 512 )) conv=notrunc status=none

if ! ext4_has_magic "${SDIMG}" $(( ${RFS_PART_SECTOR_START} * 512 )) ; then
    echo "error: MMC partition 2 does not contain an ext4 filesystem" >&2
    exit 1
fi
rm -f "${RFS_IMG}" "${RFS_CMDS}"

cat <<EOS

======================================================================
                           BUILD COMPLETE
======================================================================

SD card image:  ${PWD}/${SDIMG}

Build outputs (in ${PWD}):
  ${SDIMG}
      SD card image
  ${UBOOT_DIR}/u-boot.itb
      U-Boot bootloader
  kernel.itb
      Linux kernel and device tree (FIT image)
  boot.scr.uimg
      U-Boot boot script
  u-boot-spl-dtb.hex
      SPL image used to build the JIC
  ${DEBIAN_ARCHIVE}
      Debian root filesystem (downloaded)

Write the SD card image (replace /dev/sdX with your SD card device):
  sudo dd if=${PWD}/${SDIMG} of=/dev/sdX bs=1M status=progress conv=fsync

Boot from the SD card:
  1. Write the image to the SD card.
  2. Insert the SD card into the Agilex 5 board.
  3. Generate a JIC from the GHRD .sof and u-boot-spl-dtb.hex:
       quartus_pfg -c sof_filename.sof output_file.jic \\
           -o device=MT25QU128 \\
           -o flash_loader=A5ED065BB32AE6SR0 \\
           -o hps_path=${OUTPUT_DIR_ABS}/u-boot-spl-dtb.hex \\
           -o mode=ASX4 \\
           -o hps=1
  4. Program the JIC and power cycle the board:
       quartus_pgm -c 1 -m jtag -o "pvi;output_file.jic"

Login:
  user:     ${DEBIAN_USER}
  password: ${DEBIAN_PASS}

EOS
