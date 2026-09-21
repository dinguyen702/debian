# all variables required
ATF_REPO="https://github.com/altera-fpga/arm-trusted-firmware.git"
ATF_REF="socfpga_v2.14.1"
UBOOT_REPO="https://github.com/altera-fpga/u-boot-socfpga.git"
UBOOT_REF="socfpga_v2026.04"
LINUX_REPO="git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
LINUX_REF="v7.2"

# optional
UBOOT_ITS_FILE="uboot_script.its"
UBOOT_ITS_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/whinlatter/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${UBOOT_ITS_FILE}"
UBOOT_SCRIPT_FILE="uboot.txt"
UBOOT_SCRIPT_URL="https://raw.githubusercontent.com/altera-fpga/meta-altera-fpga/whinlatter/meta-altera-bsp/recipes-bsp/u-boot/bootscr/${UBOOT_SCRIPT_FILE}"

FABRIC_RBF_FILE=
FABRIC_RBF_URL=
