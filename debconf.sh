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
UBOOT_REPO="https://dinguyen702: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@github.com/altera-innersource/applications.fpga.soc.uboot-socfpga.git"
UBOOT_REF="socfpga_v2026.10"
LINUX_REPO="https://dinguyen702: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@github.com/altera-innersource/applications.fpga.soc.linux-socfpga-dev.git"
LINUX_REF="socfpga-6.18.53-lts"

# optional
UBOOT_ITS_FILE="uboot_script.its"
UBOOT_ITS_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/wrynose/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${UBOOT_ITS_FILE}"
UBOOT_SCRIPT_FILE="uboot.txt"
UBOOT_SCRIPT_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/wrynose/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${UBOOT_SCRIPT_FILE}"

FABRIC_RBF_FILE=
FABRIC_RBF_URL=

# FIT config board-${BOARD_ID}; must match U-Boot's board_id (this board reports 4)
BOARD_ID=4
