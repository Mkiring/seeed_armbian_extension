SEEED_EXTENSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function seeed_apply_armbian_build_patch_bundle() {
	# TEMPORARILY DISABLED: patches must be applied manually before build.
	# Reason: patch_files array is applied during inc source (enable_extension
	# at inc:479), but bash has already cached earlier function definitions
	# in memory — patched versions on disk never reach bash memory, so hooks
	# like recomputer_enable_usb_gadget_defaults run with their pre-patch body.
	# Manual workflow:
	#   1. git apply patches/armbian-build/0001-*.patch
	#   2. git apply patches/armbian-build/0002-*.patch
	#   3. git apply patches/armbian-build/0003-*.patch
	#   4. git apply patches/armbian-build/0004-*.patch
	#   5. run build
	# TODO: move enable_extension seeed_armbian_extension into board conf,
	# before `source inc`, so patches apply before inc is sourced.
	return 0

	local patch_file
	local -a patch_files=(
		"0001-rk3588-enable-panthor-gpu-stack.patch"
		"0002-rk35xx-install-fcs960k-bluez-with-common-packages.patch"
		"0003-rk3576-enable-panfrost-gpu-stack.patch"
		"0004-rk35xx-fix-usb-gadget-tty-deadlock.patch"
	)

	# Apply extensions before later build phases consume board, kernel, and
	# common-source files. Reverse checking makes this safe when sourced again.
	for patch_file in "${patch_files[@]}"; do
		patch_file="${SEEED_EXTENSION_ROOT}/patches/armbian-build/${patch_file}"
		[[ -f "${patch_file}" ]] ||
			exit_with_error "Seeed Armbian build patch is missing" "${patch_file}"

		if (
			cd "${SRC}" &&
			git apply --reverse --check "${patch_file}"
		) 2>/dev/null; then
			display_alert "Seeed Armbian build patch" "Already applied: ${patch_file##*/}" "debug"
		elif (
			cd "${SRC}" &&
			git apply --check "${patch_file}"
		); then
			(
				cd "${SRC}" &&
				git apply "${patch_file}"
			) || exit_with_error "Failed to apply Seeed Armbian build patch" "${patch_file}"
			display_alert "Seeed Armbian build patch" "Applied: ${patch_file##*/}" "info"
		else
			exit_with_error "Seeed Armbian build patch conflicts with build sources" "${patch_file}"
		fi
	done
}

seeed_apply_armbian_build_patch_bundle

function seeed_apply_uboot_patch_bundle() {
	local patch_dir="${SEEED_EXTENSION_ROOT}/patches/u-boot"
	local userpatch_root="${USERPATCHES_PATH}/u-boot/legacy/u-boot-radxa-rk35xx"
	local patch_file source_defconfig target_defconfig
	local -a patch_files=(
		"0001-u-boot-add-FIT-environment-partition-fallback.patch"
		"0002-u-boot-scan-OS-boot-devices-after-SPI-boot.patch"
		"0003-u-boot-normalize-recomputer-rk35xx-defconfigs.patch"
		"0004-u-boot-rk3576-fdt-fixup-fallback-bootdev.patch"
	)
	local -a defconfigs=(
		"recomputer-rk3576-devkit_defconfig"
		"recomputer-rk3588-devkit_defconfig"
	)

	case "${BOARD}" in
		recomputer-rk3576-devkit|recomputer-rk3588-devkit)
			;;
		*)
			return 0
			;;
	esac

	for patch_file in "${patch_files[@]}"; do
		[[ -f "${patch_dir}/${patch_file}" ]] ||
			exit_with_error "Seeed U-Boot patch bundle is incomplete" "${patch_dir}/${patch_file}"
	done
	mkdir -p "${userpatch_root}/board_recomputer-rk3576-devkit" \
		"${userpatch_root}/board_recomputer-rk3588-devkit" \
		"${userpatch_root}/defconfig" ||
		exit_with_error "Failed to create Seeed U-Boot userpatch directories" "${userpatch_root}"

	# 0003 is a modification patch, so seed the userpatch overlay with the
	# core defconfigs before applying it. Userpatches then takes precedence over
	# the core overlay during Armbian's normal U-Boot patching phase.
	for source_defconfig in "${defconfigs[@]}"; do
		target_defconfig="${userpatch_root}/defconfig/${source_defconfig}"
		[[ -e "${target_defconfig}" ]] && continue

		[[ -f "${SRC}/patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig/${source_defconfig}" ]] ||
			exit_with_error "Base U-Boot defconfig is missing" "${source_defconfig}"
		install -D -m 0644 \
			"${SRC}/patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig/${source_defconfig}" \
			"${target_defconfig}" ||
			exit_with_error "Failed to stage Seeed U-Boot defconfig" "${target_defconfig}"
	done

	for patch_file in "${patch_files[@]}"; do
		patch_file="${patch_dir}/${patch_file}"
		if (
			cd "${USERPATCHES_PATH}" &&
			git apply -p2 --reverse --check "${patch_file}"
		) 2>/dev/null; then
			display_alert "Seeed U-Boot patches" "Already staged: ${patch_file##*/}" "debug"
		elif (
			cd "${USERPATCHES_PATH}" &&
			git apply -p2 --check "${patch_file}"
		); then
			(
				cd "${USERPATCHES_PATH}" &&
				# The outer MBOX adds inner unified-diff patch files. Their
				# context marker followed by a tab is valid payload, but appears
				# as whitespace to the outer git-apply invocation.
				git apply --whitespace=nowarn -p2 "${patch_file}"
			) ||
				exit_with_error "Failed to stage Seeed U-Boot patch" "${patch_file}"
			display_alert "Seeed U-Boot patches" "Staged: ${patch_file##*/}" "info"
		else
			exit_with_error "Seeed U-Boot patch conflicts with userpatches" "${patch_file}"
		fi
	done
}

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
	seeed_apply_uboot_patch_bundle

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

# Restart ssh.service instead of reload, and never abort firstlogin on its
# failure. On a freshly booted image ssh.service may not yet be "active" when
# firstlogin reaches the sshd-config step, so `systemctl reload ssh.service`
# fails ("Unit ssh.service is not active, cannot reload."). The stock
# `|| exit 1` then aborts before the /root/.not_logged_in_yet marker is removed,
# and the setup loops on every subsequent boot. Mirrors
# Seeed-Studio/armbian-build PR #13.
function post_family_tweaks__seeed_firstlogin_restart_ssh() {
	local patch_file="${SEEED_EXTENSION_ROOT}/patches/firstlogin/0001-firstlogin-restart-ssh-on-failure.patch"
	local target="${SDCARD}/usr/lib/armbian/armbian-firstlogin"

	[[ -f "$patch_file" ]] ||
		exit_with_error "Firstlogin SSH restart patch not found" "$patch_file"

	# Idempotent: skip if already applied (e.g. re-run against a staged rootfs).
	if patch --dry-run --no-backup-if-mismatch -R -s "$target" < "$patch_file" 2>/dev/null; then
		display_alert "Firstlogin SSH restart" "Already applied" "debug"
		return 0
	fi

	display_alert "Firstlogin SSH restart" "Patching armbian-firstlogin" "info"
	patch --no-backup-if-mismatch -s "$target" < "$patch_file" ||
		exit_with_error "Failed to patch armbian-firstlogin" "$patch_file"
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
