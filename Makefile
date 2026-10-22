PYTHON ?= python3
KCONFIG := Kconfig
DEFCONFIG := configs/agilex5_defconfig
CONFIG := .config

.PHONY: help menuconfig defconfig olddefconfig

help:
	@echo "Agilex 5 Debian SD card image"
	@echo
	@echo "  make menuconfig   - configure the build (writes $(CONFIG))"
	@echo "  make defconfig    - write $(CONFIG) from $(DEFCONFIG)"
	@echo "  make olddefconfig - fill missing $(CONFIG) symbols from defaults"
	@echo "  ./mk_debian_sd.sh - build using $(CONFIG) if present, else debconf.sh"

defconfig:
	cp $(DEFCONFIG) $(CONFIG)
	@echo "wrote $(CONFIG) from $(DEFCONFIG)"

menuconfig:
	$(PYTHON) scripts/menuconfig.py --kconfig $(KCONFIG) --config $(CONFIG)

olddefconfig:
	$(PYTHON) scripts/menuconfig.py --kconfig $(KCONFIG) --config $(CONFIG) --olddefconfig
