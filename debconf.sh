# all variables required
#ATF_REPO="github:altera-innersource/applications.fpga.soc.arm-trusted-firmware-dev"
#ATF_REF="socfpga_v2.15.0"
#UBOOT_REPO="github:altera-innersource/applications.fpga.soc.uboot-socfpga-dev"
#UBOOT_REF="socfpga_v2026.07"
#LINUX_REPO="github:altera-innersource/applications.fpga.soc.linux-socfpga-dev"
#LINUX_REF="socfpga-6.18.37-lts"

# if you can't clone to the above repo, then these will work
ATF_REPO="https://github.com/altera-fpga/arm-trusted-firmware.git"
ATF_REF="socfpga_v2.14.1"
UBOOT_REPO="https://github.com/altera-fpga/u-boot-socfpga.git"
UBOOT_REF="socfpga_v2026.04"
LINUX_REPO="https://github.com/altera-fpga/linux-socfpga.git"
LINUX_REF="socfpga-6.18.20-lts"

# optional
UBOOT_ITS_FILE="uboot_script.its"
UBOOT_ITS_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/wrynose/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${UBOOT_ITS_FILE}"
UBOOT_SCRIPT_FILE="uboot.txt"
UBOOT_SCRIPT_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/wrynose/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${UBOOT_SCRIPT_FILE}"

FABRIC_RBF_FILE=
FABRIC_RBF_URL=

# FIT config board-${BOARD_ID}; used by the U-Boot script if unset in env
BOARD_ID=0
