SEEED_EXTENSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# U-Boot default-environment helpers must exist for every build flavor,
# including standalone `compile.sh uboot` runs (CI) with no OTA_* variables:
# the packaging hook inside ships u-boot-default.env in the u-boot deb, which
# image builds later need for boot-env prefill and A/B initial-env merging.
# shellcheck source=/dev/null
source "${SEEED_EXTENSION_ROOT}/armbian-ota/common/build-hooks/uboot-default-env.sh"

if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
	exit_with_error "RK_SECURE_UBOOT_ENABLE and RK_OPTEE_BOOT_ENABLE are mutually exclusive" "use secure-boot or secure-rootfs, not both"
fi

if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" || "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
	export CRYPTROOT_ENABLE=yes
	export RK_AUTO_DECRYP=yes
fi

if [[ "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" && "${RK_OPTEE_BOOT_ENABLE}" != "yes" ]]; then
	exit_with_error "RK_AUTO_DECRYP requires an explicit boot security mode" "set RK_OPTEE_BOOT_ENABLE=yes or RK_SECURE_UBOOT_ENABLE=yes"
fi

if [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
	display_alert "Cryptroot" "Enable RK to automatically unlock encrypted containers" "info"
	export CRYPTROOT_SSH_UNLOCK=no
	enable_extension "seeed_armbian_extension/rk_secure-disk-encryption/rk-auto-decryption-disk"
fi

if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" || "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
	if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]; then
		display_alert "Secure U-Boot" "Enable Secure Boot Extensions" "info"
	else
		display_alert "OP-TEE bootchain" "Enable secure boot build hooks in OP-TEE bootchain mode" "info"
	fi
	enable_extension "seeed_armbian_extension/rk_secure-disk-encryption/rk-secure-boot"
fi

if [[ "${OTA_ENABLE}" == "yes" ]]; then
	display_alert "OTA_ENABLE" "Enable OTA extension ota-support" "info"
	enable_extension "seeed_armbian_extension/armbian-ota/ota-support"
fi

if [[ "yes" == "yes" ]]; then
	display_alert "Security hardening" "Enable security hardening extension recomputer-security" "info"
	enable_extension "seeed_armbian_extension/security-hardening/recomputer-security"
fi

# RK3576/RK3588 U-Boot SPL loader hooks: boot_merger + optional usbplug recompile
# for Maskrom recovery on new SPI flash boards. Hook functions are inert for SoCs
# they don't handle (they fall back to upstream mkimage behavior).
if [[ "yes" == "yes" ]]; then
	display_alert "RK U-Boot postprocess" "Enable rk-uboot-postprocess hooks" "info"
	enable_extension "seeed_armbian_extension/rk-uboot-postprocess/rk-uboot-postprocess"
fi

# Anchor root= resolution to the actual boot disk in every image flavor. The
# init-top script is picked up by mkinitramfs from /etc/initramfs-tools and is
# a no-op without the armbian.bootdev cmdline token (single-disk/legacy boots).
function post_customize_image__020_install_bootdev_root_anchor() {
	install -D -m 0755 \
		"${SEEED_EXTENSION_ROOT}/initramfs/scripts/init-top/armbian-bootdev-root" \
		"${MOUNT}/etc/initramfs-tools/scripts/init-top/armbian-bootdev-root" ||
		exit_with_error "Failed to install bootdev root anchor"

	display_alert "Bootdev root anchor" "Installed init-top armbian-bootdev-root" "info"
}

# Add the PCIe ASPM workaround to the generated image's kernel command line.
# Keep any board- or user-provided extraargs intact and make this hook idempotent.
function post_customize_image__010_disable_pcie_aspm() {
	local armbian_env="${MOUNT}/boot/armbianEnv.txt"
	local line
	local extraargs=""

	mkdir -p "${MOUNT}/boot"
	touch "${armbian_env}"

	while IFS= read -r line; do
		if [[ "${line}" == extraargs=* ]]; then
			extraargs="${line#extraargs=}"
			break
		fi
	done < "${armbian_env}"

	if [[ " ${extraargs} " == *" pcie_aspm=off "* ]]; then
		return 0
	fi

	if [[ -n "${extraargs}" ]]; then
		sed -i '0,/^extraargs=/{/^extraargs=/s|$| pcie_aspm=off|}' "${armbian_env}"
	else
		if grep -q '^extraargs=' "${armbian_env}"; then
			sed -i '0,/^extraargs=/{/^extraargs=/s|$|pcie_aspm=off|}' "${armbian_env}"
		else
			printf 'extraargs=pcie_aspm=off\n' >> "${armbian_env}"
		fi
	fi

	display_alert "PCIe ASPM" "Added pcie_aspm=off to armbianEnv.txt" "info"
}
