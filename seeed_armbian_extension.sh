SEEED_EXTENSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function seeed_apply_armbian_build_patch_bundle() {
	local patch_file idx all_applied=yes
	local -a patch_files=(
		"0003-rk3576-enable-panfrost-gpu-stack.patch"
	)
	local -a patch_paths=()

	# Apply before later build phases consume board, kernel, and
	# common-source files.
	for patch_file in "${patch_files[@]}"; do
		patch_file="${SEEED_EXTENSION_ROOT}/patches/armbian-build/${patch_file}"
		[[ -f "${patch_file}" ]] ||
			exit_with_error "Seeed Armbian build patch is missing" "${patch_file}"
		patch_paths+=("${patch_file}")
	done

	for patch_file in "${patch_paths[@]}"; do
		(cd "${SRC}" && git apply --reverse --check "${patch_file}") 2>/dev/null || {
			all_applied=no
			break
		}
	done
	if [[ "${all_applied}" == "yes" ]]; then
		display_alert "Seeed Armbian build patch" "Bundle already applied" "debug"
		return 0
	fi

	# Patches are coupled: one applied on top of another can break its
	# reverse check, so a stale tree must be unwound in reverse numeric
	# order before re-applying in ascending order.
	for ((idx = ${#patch_paths[@]} - 1; idx >= 0; idx--)); do
		patch_file="${patch_paths[idx]}"
		if (cd "${SRC}" && git apply --reverse --check "${patch_file}") 2>/dev/null; then
			(cd "${SRC}" && git apply --reverse "${patch_file}") ||
				exit_with_error "Failed to revert Seeed Armbian build patch" "${patch_file}"
			display_alert "Seeed Armbian build patch" "Reverted: ${patch_file##*/}" "info"
		fi
	done

	for patch_file in "${patch_paths[@]}"; do
		if (cd "${SRC}" && git apply --check "${patch_file}" && git apply "${patch_file}"); then
			display_alert "Seeed Armbian build patch" "Applied: ${patch_file##*/}" "info"
		else
			exit_with_error "Seeed Armbian build patch conflicts with build sources" "${patch_file}"
		fi
	done
}

seeed_apply_armbian_build_patch_bundle

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
