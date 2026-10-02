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
#   - openssl
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
declare -r KERNEL_LOAD="0x90000000"

declare -r DEF_UBOOT_ITS_FILE="uboot_script.its"
declare -r DEF_UBOOT_ITS_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/whinlatter/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${DEF_UBOOT_ITS_FILE}"
declare -r DEF_UBOOT_SCRIPT_FILE="uboot.txt"
declare -r DEF_UBOOT_SCRIPT_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/whinlatter/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${DEF_UBOOT_SCRIPT_FILE}"

declare -r DEF_FABRIC_RBF_FILE=""
declare -r DEF_FABRIC_RBF_URL=""

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
declare -r SDCARD_IMG_SIZE=$((4*SZ_GB))
declare -r RFS_PART_SIZE=$((3*${SZ_GB}))
declare -r BOOT_PART_SIZE=$((200*${SZ_MB}))

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

# Write etc/shadow with a usable root password when the file is not already present.
function write_root_shadow() {

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
            if [ -z ${CONFIG_FILE} -o ! -f ${CONFIG_FILE} ] ; then
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

# =============================================================================
# BUILD PROCESS
# =============================================================================

echo "[STEP] Setting up build environment..."

# Create and enter build directory
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

# Set environment variables, read-only and exported
declare -rx ARCH=arm64
declare -rx CROSS_COMPILE="${PWD}/${TOOLCHAIN_DIR}/bin/aarch64-unknown-linux-musl-"

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
make clean
make -j "${JOBS}" PLAT="${ATF_PLAT}" bl31 ENABLE_LTO=0

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
make clean && make mrproper
make "${UBOOT_DEFCONFIG}"

# Link directly to ATF bl31.bin in its build directory
ln -sf "../${ATF_DIR}/build/${ATF_PLAT}/release/bl31.bin" .

make -j "${JOBS}"

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
cat > config-fragment-agilex5 << 'EOF'
# Enable Ethernet connectivity
CONFIG_MARVELL_PHY=y
EOF

# Configure and build kernel
make defconfig
./scripts/kconfig/merge_config.sh -O ./ ./.config ./config-fragment-agilex5
make oldconfig
make -j "${JOBS}" Image && make "${LINUX_DTB}"
make -j "${JOBS}" modules 
make -j "${JOBS}" modules_install INSTALL_MOD_PATH="${_LINUX_LM_DIR_ABS}"
set -x
pwd
cd ${_LINUX_LM_DIR_ABS}
# Debian merges /lib into /usr/lib. A tarball rooted at lib/ replaces that
# symlink, which removes /lib/systemd. Place modules under usr/lib instead.
mkdir -p usr
rm -rf usr/lib
mv lib usr/lib
tar cf ${_LINUX_LM_TAR} usr/lib/modules

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

# the archive contains the file 'disk.raw' that we'll use
# to extract the root file system
tar xfJ "${DEBIAN_ARCHIVE}"

echo "Debian download complete"

## =============================================================================
## CREATE SD CARD IMAGE
## =============================================================================
#
echo "[STEP] Creating SD card image..."

if ! write_root_shadow ; then
    exit 1
fi

# Running guestfish requires access to /boot/vmlinuz-* (chmod a+r)
# Being part of the kvm group may help with speed execution
guestfish --ro -a disk.raw <<EOF
sparse ${SDIMG} ${SDCARD_IMG_SIZE}
run
part-init /dev/sdb mbr
part-add /dev/sdb p ${BOOT_PART_SECTOR_START} ${BOOT_PART_SECTOR_END}
part-add /dev/sdb p ${RFS_PART_SECTOR_START}  ${RFS_PART_SECTOR_END}
mkfs fat /dev/sdb1
mount /dev/sdb1 /
copy-in ${PWD}/${UBOOT_DIR}/u-boot.itb /
copy-in ${PWD}/kernel.itb /
copy-in ${PWD}/boot.scr.uimg /
unmount /
copy-device-to-device /dev/sda1 /dev/sdb2
mount /dev/sdb2 /
upload ${_DEBIAN_SHADOW_FILE} /etc/shadow
chmod 0640 /etc/shadow
upload ${_DEBIAN_FSTAB_FILE} /etc/fstab
tar-in ${_LINUX_LM_TAR} /
ln-sf sbin/init /init
sync
EOF

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
    echo "  u-boot.itb                   - U-Boot bootloader"
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
    echo "  2. Insert SD card into the Agilex 5 board"
    echo "  3. Use quartus_pfg to generate a JIC using GHRD sof + u-boot-spl-dtb.hex"
    echo "     e.g. quartus_pfg \\"
    echo "          -c sof_filename.sof output_file.jic \\"
    echo "          -o device=MT25QU128 \\"
    echo "          -o flash_loader=A5ED065BB32AE6SR0 \\"
    echo "          -o hps_path=${OUTPUT_DIR_ABS}/u-boot-spl-dtb.hex \\"
    echo "          -o mode=ASX4 \\"
    echo "          -o hps=1"
    echo "  4. Program the JIC and power cycle the board"
    echo "     e.g. quartus_pgm -c 1 -m jtag -o \"pvi;output_file.jic\""
    echo ""
    echo "To Login, user name is ${DEBIAN_USER} and the password is ${DEBIAN_PASS}"
    echo ""
    echo "IMPORTANT:"
    echo " Once you have logged on to Debian on Agilex 5, please check the date"
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
