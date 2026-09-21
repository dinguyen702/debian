#!/bin/bash
# =============================================================================
# SoCFPGA HPS Debian Linux SD Card Example Script
# =============================================================================
#
# PURPOSE:
# This script builds an SD card boot image for Altera SoCFPGA HPS systems to
# start Debian.
# The SD card image produced from this script will demonstrate the HPS first boot flow
#
# USAGE:
#   ./mk_debian_sd_s10.sh [-p agilex5|agilex3|stratix10|arria10] [-c debconf.sh]
#
# OUTPUT:
#   sdcard_<platform>.img - Ready to write to SD card
#
# REQUIREMENTS:
# - Linux host system (Ubuntu 22.04+ recommended)
# - Internet connection for downloading sources
# - ~20GB free disk space
# - Packages:
#   - build-essential
#   - bison
#   - flex
#   - guestfs-tools for SD image creation
#   - u-boot-tools
#   - python3-setuptools
#   - python3-dev
#   - libssl-dev
#   - bc 
#   - xz-utils
#   - swig
#   - sudo
#   - curl  
#   - git
#
# This script uses guestfs tools to create an SD card image.
# For the tools to work efficiently, it is
# important the kernel image file in the host's /boot be readable by all users
# and that the user running the script be part of the group 'kvm'.
#
# =============================================================================

set -e  # Exit on any error

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
declare -r CONFIG_OPTIONAL="UBOOT_ITS_FILE UBOOT_ITS_URL UBOOT_SCRIPT_FILE UBOOT_SCRIPT_URL FABRIC_RBF_FILE FABRIC_RBF_URL"

# Component URLs and settings
# Toolchain URL and directory are selected with the platform (see select_platform).
# Using the musl compiler to make a tight, statically linked Linux environment
declare -r TOOLCHAIN_RELEASE="https://github.com/cross-tools/musl-cross/releases/download/20250929"

declare -r ATF_DIR="arm-trusted-firmware"
declare -r UBOOT_DIR="u-boot-socfpga"
declare -r LINUX_DIR="linux-socfpga"
declare -r LINUX_LM_DIR="${LINUX_DIR}_modules"

declare -r DEF_UBOOT_ITS_FILE="uboot_script.its"
declare -r DEF_UBOOT_ITS_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/whinlatter/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${DEF_UBOOT_ITS_FILE}"
declare -r DEF_UBOOT_SCRIPT_FILE="uboot.txt"
declare -r DEF_UBOOT_SCRIPT_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/whinlatter/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${DEF_UBOOT_SCRIPT_FILE}"

declare -r DEF_FABRIC_RBF_FILE=""
declare -r DEF_FABRIC_RBF_URL=""

declare -r DEBIAN_NAME="trixie"
declare -r DEBIAN_VERSION="13"
# arm64 cloud image. The tarball contains disk.raw.
declare -r DEBIAN_ARM64_ARCHIVE="debian-13-nocloud-arm64-20260623-2518.tar.xz"
declare -r DEBIAN_ARM64_URL="https://cloud.debian.org/images/cloud/trixie/20260623-2518/${DEBIAN_ARM64_ARCHIVE}"
# Debian does not publish nocloud images for armhf. This is a Debian 13
# armhf root filesystem (debootstrap) for Arria 10.
declare -r DEBIAN_ARMHF_ARCHIVE="debian-13-armhf-rootfs-20260921.tar.xz"
declare -r DEBIAN_ARMHF_URL="https://images.linuxcontainers.org/images/debian/trixie/armhf/default/20260921_05%3A24/rootfs.tar.xz"

# file below enables the account 'root'
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
# SDIMG is set after the platform is chosen: sdcard_<platform>.img
declare -r SDCARD_IMG_SIZE=$((4*SZ_GB))
declare -r RFS_PART_SIZE=$((3*${SZ_GB}))
declare -r BOOT_PART_SIZE=$((50*${SZ_MB}))

# =============================================================================
# HELPERS AND FUNCTIONS
# =============================================================================

declare -r BOOT_PART_SECTOR_START=2048
declare -r BOOT_PART_SECTOR_END=$(( (${BOOT_PART_SIZE} / 512 ) + ${BOOT_PART_SECTOR_START})) 
declare -r RFS_PART_SECTOR_START=$((${BOOT_PART_SECTOR_END} + 1))
declare -r RFS_PART_SECTOR_END=$(( (${RFS_PART_SIZE} / 512 ) + ${RFS_PART_SECTOR_START})) 

# abs paths to files, handy later
declare _DEBIAN_SHADOW_FILE="$(readlink -f ${DEBIAN_SHADOW_FILE})"
declare _DEBIAN_FSTAB_FILE="$(readlink -f ${DEBIAN_FSTAB_FILE})"

# usage
declare -r SELF="$(basename $0)"

# Supported -p values. agilex3 reuses the Agilex 5 TF-A platform: socfpga_v2.14.1
# has no separate agilex3 port. Arria 10 is a Cortex-A9 and does not use TF-A.
declare -r SUPPORTED_PLATFORMS="agilex5 agilex3 stratix10 arria10"

function usage() {

    cat <<EOH
Builds an SD card image with an unmodified Debian run time.

Usage: ${SELF} [-h] [-p <platform>] [-c <file>]
    -h: prints this message
    -p: SoCFPGA platform. One of: ${SUPPORTED_PLATFORMS}
        When -p is omitted, a menu is shown. Pressing Enter keeps the
        default (PLATFORM= from the configuration file, or stratix10).
    -c: specifies a configuration file to use.

Platforms
    agilex5    Agilex 5 SoC Development Kit (arm64, TF-A PLAT=agilex5)
    agilex3    Agilex 3 SoC Development Kit (arm64, TF-A PLAT=agilex5)
    stratix10  Stratix 10 SoC Development Kit (arm64, TF-A PLAT=stratix10)
    arria10    Arria 10 SoC Development Kit (arm, no TF-A, armhf Debian rootfs)

Configuration file

Must include the following mandatory variables:
${CONFIG_MANDATORY}

  - Prefixes:
     - ATF, UBOOT, LINUX refer respectively to Arm Trusted Firmware, U-Boot and the Linux kernel
  - The suffixes 
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

    if command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "${archive}" "${url}"
	err=$?
    else
        echo "ERROR: curl not found. Please install it"
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

# Map a platform name onto the ATF, U-Boot, kernel, and toolchain settings
# used by the rest of this script.
function select_platform() {

    local plat="${1}"

    case "${plat}" in
        agilex5)
            PLATFORM_TITLE="Agilex 5"
            TARGET_ARCH="arm64"
            ATF_PLAT="agilex5"
            UBOOT_DEFCONFIG="socfpga_agilex5_defconfig"
            UBOOT_DTSI="arch/arm/dts/socfpga_agilex5_socdk-u-boot.dtsi"
            UBOOT_BIN="u-boot.itb"
            SPL_ARTIFACT="spl/u-boot-spl-dtb.hex"
            LINUX_DTB="intel/socfpga_agilex5_socdk.dtb"
            KERNEL_FIT_ARCH="arm64"
            KERNEL_FIT_COMPRESSION="lzma"
            KERNEL_LOAD="0x90000000"
            QUARTUS_DEVICE="MT25QU128"
            QUARTUS_FLASH_LOADER="A5ED065BB32AE6SR0"
            QUARTUS_MODE="ASX4"
            ;;
        agilex3)
            PLATFORM_TITLE="Agilex 3"
            TARGET_ARCH="arm64"
            ATF_PLAT="agilex5"
            UBOOT_DEFCONFIG="socfpga_agilex3_defconfig"
            UBOOT_DTSI="arch/arm/dts/socfpga_agilex3_socdk-u-boot.dtsi"
            UBOOT_BIN="u-boot.itb"
            SPL_ARTIFACT="spl/u-boot-spl-dtb.hex"
            LINUX_DTB="intel/socfpga_agilex3_socdk.dtb"
            KERNEL_FIT_ARCH="arm64"
            KERNEL_FIT_COMPRESSION="lzma"
            KERNEL_LOAD="0x90000000"
            QUARTUS_DEVICE=""
            QUARTUS_FLASH_LOADER=""
            QUARTUS_MODE=""
            ;;
        stratix10)
            PLATFORM_TITLE="Stratix 10"
            TARGET_ARCH="arm64"
            ATF_PLAT="stratix10"
            UBOOT_DEFCONFIG="socfpga_stratix10_defconfig"
            UBOOT_DTSI="arch/arm/dts/socfpga_stratix10_socdk-u-boot.dtsi"
            UBOOT_BIN="u-boot.itb"
            SPL_ARTIFACT="spl/u-boot-spl-dtb.hex"
            LINUX_DTB="altera/socfpga_stratix10_socdk.dtb"
            KERNEL_FIT_ARCH="arm64"
            KERNEL_FIT_COMPRESSION="lzma"
            KERNEL_LOAD="0x86000000"
            QUARTUS_DEVICE=""
            QUARTUS_FLASH_LOADER=""
            QUARTUS_MODE=""
            ;;
        arria10)
            PLATFORM_TITLE="Arria 10"
            TARGET_ARCH="arm"
            ATF_PLAT=""
            UBOOT_DEFCONFIG="socfpga_arria10_defconfig"
            UBOOT_DTSI="arch/arm/dts/socfpga_arria10_socdk_sdmmc-u-boot.dtsi"
            UBOOT_BIN="u-boot.img"
            SPL_ARTIFACT="spl/u-boot-splx4.sfp"
            LINUX_DTB="intel/socfpga/socfpga_arria10_socdk_sdmmc.dtb"
            KERNEL_FIT_ARCH="arm"
            KERNEL_FIT_COMPRESSION="none"
            KERNEL_LOAD="0x8000"
            QUARTUS_DEVICE=""
            QUARTUS_FLASH_LOADER=""
            QUARTUS_MODE=""
            ;;
        *)
            echo "error: unknown platform '${plat}'" >&2
            echo "supported platforms: ${SUPPORTED_PLATFORMS}" >&2
            return 1
            ;;
    esac

    if [[ ${TARGET_ARCH} == arm64 ]]; then
        TOOLCHAIN_DIR="aarch64-unknown-linux-musl"
    else
        TOOLCHAIN_DIR="armv7-unknown-linux-musleabihf"
    fi
    TOOLCHAIN_URL="${TOOLCHAIN_RELEASE}/${TOOLCHAIN_DIR}.tar.xz"
    TOOLCHAIN_PREFIX="${TOOLCHAIN_DIR}-"
    LINUX_DTB_NAME="$(basename "${LINUX_DTB}")"
    SPL_ARTIFACT_NAME="$(basename "${SPL_ARTIFACT}")"

    return 0
}

# Prompt for a platform. Sets PLATFORM. A bare Enter keeps the default.
function choose_platform() {

    local default="${1}"
    local -a platforms
    local -a titles
    local choice
    local i
    local plat

    read -r -a platforms <<< "${SUPPORTED_PLATFORMS}"
    titles=(
        "Agilex 5 SoC Development Kit"
        "Agilex 3 SoC Development Kit"
        "Stratix 10 SoC Development Kit"
        "Arria 10 SoC Development Kit"
    )

    echo "Select a platform:"
    for i in "${!platforms[@]}"; do
        printf "  %d) %-12s %s\n" "$((i + 1))" "${platforms[i]}" "${titles[i]}"
    done

    while true; do
        read -r -p "Choice [${default}]: " choice
        if [[ -z ${choice} ]]; then
            PLATFORM="${default}"
            return 0
        fi
        if [[ ${choice} =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#platforms[@]} )); then
            PLATFORM="${platforms[choice - 1]}"
            return 0
        fi
        for plat in "${platforms[@]}"; do
            if [[ ${choice} == "${plat}" ]]; then
                PLATFORM="${plat}"
                return 0
            fi
        done
        echo "Enter a number from 1 to ${#platforms[@]}, or one of: ${SUPPORTED_PLATFORMS}" >&2
    done
}

# =============================================================================
# CLI 
# =============================================================================
declare CONFIG_FILE="${DEF_CONFIG_FILE}"
declare PLATFORM_ARG=""

while [[ $# -gt 0 ]]; do
    case "${1}" in
        -h)
            usage
            exit 0
            ;;
        -c)
            shift
            CONFIG_FILE="${1:-}"
            if [ -z ${CONFIG_FILE} -o ! -f ${CONFIG_FILE} ] ; then
                echo "error: no config file given or was not found" >&2
                exit 1
            fi
            ;;
        -p)
            shift
            PLATFORM_ARG="${1:-}"
            if [ -z "${PLATFORM_ARG}" ] ; then
                echo "error: -p requires a platform (${SUPPORTED_PLATFORMS})" >&2
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

# =============================================================================
# CHECK CONFIG
# =============================================================================
echo "[STEP] configuring from ${CONFIG_FILE}..."
source "${CONFIG_FILE}"

if ! check_config ; then
    echo "Please check your configuration in ${CONFIG_FILE}..."
    exit 127
fi

# -p skips the menu. Otherwise ask, unless this is not a terminal.
if [[ -n ${PLATFORM_ARG} ]]; then
    PLATFORM="${PLATFORM_ARG}"
elif [[ -t 0 ]]; then
    choose_platform "${PLATFORM:-stratix10}"
else
    PLATFORM="${PLATFORM:-stratix10}"
    echo "No terminal; using platform ${PLATFORM}"
fi

if ! select_platform "${PLATFORM}" ; then
    exit 1
fi

SDIMG="sdcard_${PLATFORM}.img"

echo "======================================================================"
echo "   ${PLATFORM_TITLE} HPS SD Card Boot Flow Builder"
echo "======================================================================"
echo "Platform: ${PLATFORM}"
if [[ -n ${ATF_PLAT} ]]; then
    echo "ATF PLAT: ${ATF_PLAT}"
else
    echo "ATF PLAT: (none)"
fi
echo "U-Boot defconfig: ${UBOOT_DEFCONFIG}"
echo "Linux DTB: ${LINUX_DTB}"

if [[ ${TARGET_ARCH} == arm64 ]]; then
    DEBIAN_ARCHIVE="${DEBIAN_ARM64_ARCHIVE}"
    DEBIAN_URL="${DEBIAN_ARM64_URL}"
    DEBIAN_ROOTFS_KIND="disk"
else
    DEBIAN_ARCHIVE="${DEBIAN_ARMHF_ARCHIVE}"
    DEBIAN_URL="${DEBIAN_ARMHF_URL}"
    DEBIAN_ROOTFS_KIND="tar"
fi
echo "Debian rootfs: ${DEBIAN_ARCHIVE}"

# for the optional variables, we pickup the default value if 
# not set in config file
UBOOT_ITS_FILE=${UBOOT_ITS_FILE:-${DEF_UBOOT_ITS_FILE}}
UBOOT_ITS_URL=${UBOOT_ITS_URL:-${DEF_UBOOT_ITS_URL}}
UBOOT_SCRIPT_FILE=${UBOOT_SCRIPT_FILE:-${DEF_UBOOT_SCRIPT_FILE}}
UBOOT_SCRIPT_URL=${UBOOT_SCRIPT_URL:-${DEF_UBOOT_SCRIPT_URL}}
FABRIC_RBF_FILE=${FABRIC_RBF_FILE:-${DEF_FABRIC_RBF_FILE}}
FABRIC_RBF_URL=${FABRIC_RBF_URL:-${DEF_FABRIC_RBF_URL}}

# =============================================================================
# BUILD PROCESS
# =============================================================================

echo "[STEP] Setting up build environment..."

# Create and enter build directory
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

# Set environment variables, read-only and exported
declare -rx ARCH="${TARGET_ARCH}"
declare -rx CROSS_COMPILE="${PWD}/${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}"

echo "Build directory: ${PWD}"
echo "Architecture: ${ARCH}"
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
    if [[ ! -x "${TOOLCHAIN_DIR}/bin/${TOOLCHAIN_PREFIX}gcc" ]]; then
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

if [[ -n ${ATF_PLAT} ]]; then
    echo "[STEP] Building ARM Trusted Firmware (ATF) for ${ATF_PLAT}..."

    if [[ ! -d "${ATF_DIR}" ]]; then
        clone_and_checkout "${ATF_REPO}" "${ATF_REF}" "${ATF_DIR}"
    fi

    cd "${ATF_DIR}"

    # Clean and build ATF
    make clean
    make -j "${JOBS}" PLAT="${ATF_PLAT}" bl31 ENABLE_LTO=0

    cd ..

    echo "ATF build complete"
else
    echo "[STEP] ${PLATFORM_TITLE} does not use ARM Trusted Firmware; skipping ATF"
fi


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

# Configure for SD card boot. Boards without this property are left unchanged.
sed -i 's/u-boot,spl-boot-order.*/u-boot,spl-boot-order = \&mmc;/g' "${UBOOT_DTSI}"

# Disable NAND when the board dtsi enables it. Agilex nodes that only carry
# bootph-all are left alone.
sed -i '/&nand {/,/};/ s/status = "okay"/status = "disabled"/' "${UBOOT_DTSI}"

# Build U-Boot
make clean && make mrproper
make "${UBOOT_DEFCONFIG}"

# Link directly to ATF bl31.bin in its build directory
if [[ -n ${ATF_PLAT} ]]; then
    ln -sf "../${ATF_DIR}/build/${ATF_PLAT}/release/bl31.bin" .
fi

make -j "${JOBS}"

# SPL image is needed when a JIC file is created. Copy it at a known location
cp "${SPL_ARTIFACT}" ${OUTPUT_DIR_ABS} 

cd ..

echo "U-Boot build complete"

# =============================================================================
# GET UBOOT SCRIPT
# =============================================================================
echo "[STEP] Getting uboot script ..."

# get the updated uboot_script.its everytime
rm -f "${UBOOT_ITS_FILE}"
if ! download "${UBOOT_ITS_URL}" "${UBOOT_ITS_FILE}" ; then
	echo "error: failed to dowbload ${UBOOT_ITS_FILE}"
	exit 3
fi

# get the updated uboot.txt everytime
rm -f "${UBOOT_SCRIPT_FILE}"
if ! download "${UBOOT_SCRIPT_URL}" "${UBOOT_SCRIPT_FILE}" ; then
	echo "error: failed to dowbload ${UBOOT_SCRIPT_FILE}"
	exit 3
fi

mkimage -f "${UBOOT_ITS_FILE}" boot.scr.uimg

echo "Created boot.scr.uimg"

# =============================================================================
# BUILD LINUX KERNEL
# =============================================================================

echo "[STEP] Building Linux kernel..."

rm -rf ${LINUX_LM_DIR} && mkdir ${LINUX_LM_DIR}
_LINUX_LM_DIR_ABS="$(readlink -f ${LINUX_LM_DIR})"
_LINUX_LM_TAR="${PWD}/linux-modules.tar"

if [[ ! -d "${LINUX_DIR}" ]]; then
    clone_and_checkout "${LINUX_REPO}" "${LINUX_REF}" "${LINUX_DIR}"
fi

cd "${LINUX_DIR}"

# Create custom config fragment for networking
cat > "config-fragment-${PLATFORM}" << 'EOF'
# Enable Ethernet connectivity
CONFIG_MARVELL_PHY=y
EOF

# Configure and build kernel
make defconfig
./scripts/kconfig/merge_config.sh -O ./ ./.config "./config-fragment-${PLATFORM}"
make oldconfig
make -j "${JOBS}" Image && make "${LINUX_DTB}"
make -j "${JOBS}" modules 
make -j "${JOBS}" modules_install INSTALL_MOD_PATH="${_LINUX_LM_DIR_ABS}"
set -x
pwd
cd ${_LINUX_LM_DIR_ABS}
tar cf ${_LINUX_LM_TAR} lib/

cd ..

echo "Linux kernel build complete"

# =============================================================================
# CREATE KERNEL.ITS
# =============================================================================
KERNEL_IMAGE="${LINUX_DIR}/arch/${ARCH}/boot/Image"
if [[ ${KERNEL_FIT_COMPRESSION} == lzma ]]; then
    xz --threads=${JOBS} --format=lzma -f -k "${KERNEL_IMAGE}"
    KERNEL_FIT_DATA="${KERNEL_IMAGE}.lzma"
else
    KERNEL_FIT_DATA="${KERNEL_IMAGE}"
fi

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

            data = /incbin/("${KERNEL_FIT_DATA}");

            type = "kernel";

            arch = "${KERNEL_FIT_ARCH}";

            os = "linux";

            compression = "${KERNEL_FIT_COMPRESSION}";

            load = <${KERNEL_LOAD}>;

            entry = <${KERNEL_LOAD}>;

            hash-1 { algo = "crc32"; };

        };

        fdt-0 {

            description = "${LINUX_DTB_NAME%.dtb}";

            data = /incbin/("${LINUX_DIR}/arch/${ARCH}/boot/dts/${LINUX_DTB}");

            type = "flat_dt";

            arch = "arm64";

            compression = "none";

            hash-1 { algo = "crc32"; };

        };
EOF

if [ ! -z ${FABRIC_RBF_FILE} -a ! -z ${FABRIC_RBF_URL} ] ; then
    if [ ! -e "${FABRIC_RBF_FILE}" ] ; then
        download "${FABRIC_RBF_URL}" "${FABRIC_RBF_FILE}"
    else
	echo "Fabric file already downloaded"
    fi

    cat >> kernel_test.its <<EOF

        fpga-0 {

            description = "fpga_fabric_data";

	    data = /incbin/("${FABRIC_RBF_FILE}");

            type = "flat_dt";

            arch = "arm64";

            compression = "none";

            hash-1 { algo = "crc32"; };

        };
EOF
fi

cat >> kernel_test.its <<EOF
    };

    configurations {

        default = "board-0";

        board-0 {

            description = "board_0";

            kernel = "kernel";

            fdt = "fdt-0";

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

# The arm64 cloud image contains disk.raw. The armhf download is a root
# filesystem tarball and is unpacked straight onto the SD card.
if [[ ${DEBIAN_ROOTFS_KIND} == disk ]]; then
    tar xfJ "${DEBIAN_ARCHIVE}"
fi

echo "Debian download complete"

## =============================================================================
## CREATE SD CARD IMAGE
## =============================================================================
#
echo "[STEP] Creating SD card image..."

# Running guestfish requires access to /boot/vmlinuz-* (chmod a+r)
# Being part of the kvm group may help with speed execution
if [[ ${DEBIAN_ROOTFS_KIND} == disk ]]; then
    guestfish --ro -a disk.raw <<EOF
sparse ${SDIMG} ${SDCARD_IMG_SIZE}
run
part-init /dev/sdb mbr
part-add /dev/sdb p ${BOOT_PART_SECTOR_START} ${BOOT_PART_SECTOR_END}
part-add /dev/sdb p ${RFS_PART_SECTOR_START}  ${RFS_PART_SECTOR_END}
mkfs fat /dev/sdb1
mount /dev/sdb1 /
copy-in ${PWD}/${UBOOT_DIR}/${UBOOT_BIN} /
copy-in ${PWD}/kernel.itb /
copy-in ${PWD}/boot.scr.uimg /
unmount /
copy-device-to-device /dev/sda1 /dev/sdb2
mount /dev/sdb2 /
upload ${_DEBIAN_SHADOW_FILE} /etc/shadow
chmod 0640 /etc/shadow
upload ${_DEBIAN_FSTAB_FILE} /etc/fstab
tar-in ${_LINUX_LM_TAR} /
sync
EOF
else
    # The armhf tarball is the only disk guestfish adds, so it is /dev/sda.
    guestfish <<EOF
sparse ${SDIMG} ${SDCARD_IMG_SIZE}
run
part-init /dev/sda mbr
part-add /dev/sda p ${BOOT_PART_SECTOR_START} ${BOOT_PART_SECTOR_END}
part-add /dev/sda p ${RFS_PART_SECTOR_START}  ${RFS_PART_SECTOR_END}
mkfs fat /dev/sda1
mkfs ext4 /dev/sda2
mount /dev/sda1 /
copy-in ${PWD}/${UBOOT_DIR}/${UBOOT_BIN} /
copy-in ${PWD}/kernel.itb /
copy-in ${PWD}/boot.scr.uimg /
unmount /
mount /dev/sda2 /
tar-in ${PWD}/${DEBIAN_ARCHIVE} / compress:xz
ln-s /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
upload ${_DEBIAN_SHADOW_FILE} /etc/shadow
chmod 0640 /etc/shadow
upload ${_DEBIAN_FSTAB_FILE} /etc/fstab
tar-in ${_LINUX_LM_TAR} /
sync
EOF
fi

if [[ $? -eq 0 ]]; then
    echo "SUCCESS: SD card image created: ${SDIMG}"
    echo ""
    echo "======================================================================"
    echo "                           BUILD COMPLETE"
    echo "======================================================================"
    echo ""
    echo "Output files created in: ${PWD}"
    echo ""
    echo "Key files:"
    echo "  ${SDIMG}                   - SD card image (write to SD card)"
    echo "  ${UBOOT_BIN}                   - U-Boot bootloader"
    echo "  Image                        - Linux kernel"
    echo "  ${LINUX_DTB_NAME}    - Device tree"
    echo "  ${DEBIAN_ARCHIVE}            - Debian root filesystem (downloaded)"
    echo ""
    echo "To write SD card image (:"
    echo "  sudo dd if=${PWD}/${SDIMG} of=/dev/sdX bs=1M"
    echo "  (Replace /dev/sdX with your SD card device)"
    echo ""
    echo "To boot from SD card:"
    echo "  1. Write image to SD card"
    echo "  2. Insert SD card into the ${PLATFORM_TITLE} board"
    echo "  3. Use quartus_pfg to generate a JIC using GHRD sof + ${SPL_ARTIFACT_NAME}"
    if [[ -n ${QUARTUS_FLASH_LOADER} ]]; then
        echo "     e.g. quartus_pfg \\"
        echo "          -c sof_filename.sof output_file.jic \\"
        echo "          -o device=${QUARTUS_DEVICE} \\"
        echo "          -o flash_loader=${QUARTUS_FLASH_LOADER} \\"
        echo "          -o hps_path=${OUTPUT_DIR_ABS}/${SPL_ARTIFACT_NAME} \\"
        echo "          -o mode=${QUARTUS_MODE} \\"
        echo "          -o hps=1"
    else
        echo "     Set device, flash_loader, and mode for the ${PLATFORM_TITLE} board."
        echo "     e.g. quartus_pfg \\"
        echo "          -c sof_filename.sof output_file.jic \\"
        echo "          -o hps_path=${OUTPUT_DIR_ABS}/${SPL_ARTIFACT_NAME} \\"
        echo "          -o hps=1"
    fi
    echo "  4. Program the JIC and power cycle the board"
    echo "     e.g. quartus_pgm -c 1 -m jtag -o \"pvi;output_file.jic\""
    echo ""
    echo "To Login, user name is ${DEBIAN_USER} and the password is ${DEBIAN_PASS}"
    echo ""
    echo "IMPORTANT:"
    echo " Once you have logged on to Debian on ${PLATFORM_TITLE}, please check the date"
    echo " are set correctly by NTP"
    echo "    timedatectl show"
    echo " If NTPSynchronized=no appears, NTP is not functional, which may be"
    echo " due to a firewall issue"
    echo " You may have to set the date manually, such as:"
    echo "    date -s '2026-06-22 12:00:00'"
    echo ""
else
    echo "ERROR: Failed to create SD card image"
    exit 1
fi
