#!/bin/bash
#
# Rockchip ARM64 ATF + OP-TEE FIT generator.
#
# SPDX-License-Identifier: GPL-2.0+

source ./${srctree}/arch/arm/mach-rockchip/fit_nodes.sh

gen_header
gen_uboot_node
gen_bl31_node
gen_bl32_node
gen_mcu_node
gen_loadable_node
gen_kfdt_node
gen_fdt_node
gen_arm64_configurations
