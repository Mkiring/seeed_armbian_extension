#
# Configuration Hooks
#

function extension_prepare_config__ota_image_suffix() {
    local ota_image_suffix
    ota_image_suffix="$(ota_image_layout_suffix)"

    display_alert "OTA image suffix" "${ota_image_suffix} (applied during image naming)" "info"
}

function extension_prepare_config__install_overlayroot_userdata() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "A/B partition OTA" "install overlayroot, busybox-static and libubootenv-tool" "info"
        add_packages_to_image overlayroot busybox-static libubootenv-tool

    fi
}

#
# A/B Partition Helpers And Hooks
#

function rk_ab_autodecrypt_nonsecure_mode_enabled() {
	[[ "${AB_PART_OTA}" == "yes" && "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]
}

function ota_set_default_ab_partition_sizes() {
	AB_BOOT_SIZE=${AB_BOOT_SIZE:-256}  # 256MiB for each boot partition

	if [[ -n "${AB_ROOTFS_SIZE:-}" ]]; then
		return 0
	fi

	local rootfs_size_tier="${AB_ROOTFS_SIZE_TIER:-}"
	if [[ -z "${rootfs_size_tier}" ]]; then
		if [[ "${BUILD_MINIMAL}" == "yes" ]]; then
			rootfs_size_tier="minimal"
		else
			rootfs_size_tier="mid"
		fi
	fi

	case "${rootfs_size_tier}" in
		minimal)
			AB_ROOTFS_SIZE=4096
			;;
		mid)
			AB_ROOTFS_SIZE=6144
			;;
		full)
			AB_ROOTFS_SIZE=8192
			;;
		*)
			exit_with_error "Invalid AB_ROOTFS_SIZE_TIER" "${rootfs_size_tier}"
			;;
	esac

	display_alert "A/B partition OTA" "Using AB_ROOTFS_SIZE=${AB_ROOTFS_SIZE} MiB (${rootfs_size_tier} tier)" "info"
}

function prepare_image_size__ab_part_ota() {
	if [[ "${AB_PART_OTA}" == "yes" ]]; then
		local security_extra_size=0
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			security_extra_size=${SECURE_STORAGE_SECURITY_SIZE:-4}
		fi
		FIXED_IMAGE_SIZE=$(((AB_ROOTFS_SIZE * 2) + OFFSET + (AB_BOOT_SIZE * 2) + UEFISIZE + EXTRA_ROOTFS_MIB_SIZE + USERDATA + security_extra_size)) # MiB
		display_alert "A/B partition OTA" "Setting FIXED_IMAGE_SIZE to ${FIXED_IMAGE_SIZE} MiB for equal rootfs_a and rootfs_b" "info"
	fi
}

function pre_prepare_partitions__ab_part_ota() {
	if [[ "${AB_PART_OTA}" == "yes" ]]; then
		USE_HOOK_FOR_PARTITION="yes"
		ota_set_default_ab_partition_sizes
		SECURE_STORAGE_SECURITY_SIZE=${SECURE_STORAGE_SECURITY_SIZE:-4}
        USERDATA=${USERDATA:-256}  # userdata partition by default
        BOOTFS_TYPE="ext4"
        ROOTFS_TYPE="ext4"
        ROOT_FS_LABEL="armbi_roota"
        BOOT_FS_LABEL="armbi_boota"
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			display_alert "A/B partition OTA" "Creating A/B encrypted partitions: boot_a, boot_b, security, rootfs_a, rootfs_b, userdata" "info"
		else
			display_alert "A/B partition OTA" "Creating A/B partitions: boot_a, boot_b, rootfs_a, rootfs_b, userdata" "info"
		fi
	fi
}

function create_partition_table__ab_part_ota() {
	if [[ "${AB_PART_OTA}" != "yes" ]]; then
		return 0
	fi

	local next=${OFFSET} # Starting MiB
	local p_index=1
	local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
	if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
		# Keep GPT entry table compact to reduce SPL malloc pressure when probing partitions.
		local gpt_table_length="${AB_GPT_TABLE_LENGTH:-64}"
		script+="table-length: ${gpt_table_length}\n"
	fi

	# BIOS (if exists)
	if [[ -n "${BIOSSIZE}" && ${BIOSSIZE} -gt 0 ]]; then
		[[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]] || exit_with_error "BIOS partition only supports GPT" "BIOSSIZE=${BIOSSIZE}"
		script+="${p_index} : name=\"bios\", start=${next}MiB, size=${BIOSSIZE}MiB, type=21686148-6449-6E6F-744E-656564454649\n"
		next=$((next + BIOSSIZE)); p_index=$((p_index+1))
	fi
	# EFI
	if [[ -n "${UEFISIZE}" && ${UEFISIZE} -gt 0 ]]; then
		local efi_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System
		script+="${p_index} : name=\"efi\", start=${next}MiB, size=${UEFISIZE}MiB, type=${efi_type}\n"
		next=$((next + UEFISIZE)); p_index=$((p_index+1))
	fi
	# boot_a
	local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
	script+="${p_index} : name=\"boot_a\", start=${next}MiB, size=${AB_BOOT_SIZE}MiB, type=${boot_type}\n"
	next=$((next + AB_BOOT_SIZE)); local boot_a_index=${p_index}; p_index=$((p_index+1))
	# boot_b
	script+="${p_index} : name=\"boot_b\", start=${next}MiB, size=${AB_BOOT_SIZE}MiB, type=${boot_type}\n"
	next=$((next + AB_BOOT_SIZE)); local boot_b_index=${p_index}; p_index=$((p_index+1))
	# security partition must be between boot_b and rootfs_a in AB+encrypted auto-decrypt mode.
	local security_index=""
	if rk_ab_autodecrypt_nonsecure_mode_enabled; then
		local sec_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
		script+="${p_index} : name=\"security\", start=${next}MiB, size=${SECURE_STORAGE_SECURITY_SIZE}MiB, type=${sec_type}\n"
		next=$((next + SECURE_STORAGE_SECURITY_SIZE)); security_index=${p_index}; p_index=$((p_index+1))
	fi
	# rootfs_a
	local root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
    script+="${p_index} : name=\"rootfs_a\", start=${next}MiB, size=${AB_ROOTFS_SIZE}MiB, type=${root_type}\n"
    next=$((next + AB_ROOTFS_SIZE)); local rootfs_a_index=${p_index}; p_index=$((p_index+1))
	# rootfs_b
	script+="${p_index} : name=\"rootfs_b\", start=${next}MiB, size=${AB_ROOTFS_SIZE}MiB, type=${root_type}\n"
    next=$((next + AB_ROOTFS_SIZE)); local rootfs_b_index=${p_index}; p_index=$((p_index+1))

	# Add userdata partition with minimal size (1MiB)
	script+="${p_index} : name=\"userdata\", start=${next}MiB, size=${USERDATA}MiB, type=${root_type}\n"
	local userdata_index=${p_index}

	display_alert "A/B partition OTA" "Custom A/B partition table:\n${script}" "debug"
	echo -e "${script}" | run_host_command_logged sfdisk ${SDCARD}.raw || exit_with_error "A/B partition creation failed" "sfdisk"

	AB_BOOT_A_PART_INDEX=${boot_a_index}
	AB_BOOT_B_PART_INDEX=${boot_b_index}
	AB_ROOTFS_A_PART_INDEX=${rootfs_a_index}
	AB_ROOTFS_B_PART_INDEX=${rootfs_b_index}
	if [[ -n "${security_index}" ]]; then
		AB_SECURITY_PART_INDEX=${security_index}
		SECURE_STORAGE_SECURITY_PART_INDEX=${security_index}
	fi
	
	# Set bootpart and rootpart for Armbian partitioning logic
	bootpart=${boot_a_index}
	rootpart=${rootfs_a_index}
    AB_USERDATA_PART_INDEX=${userdata_index}
}

function format_partitions__ab_part_ota() {
	if [[ "${AB_PART_OTA}" != "yes" ]]; then
		return 0
	fi

	# Format boot_b as ext4 with label armbi_bootb
	if [[ -n "${AB_BOOT_B_PART_INDEX}" ]]; then
		local boot_b_dev="${LOOP}p${AB_BOOT_B_PART_INDEX}"
        check_loop_device "$boot_b_dev"
		display_alert "A/B partition OTA" "Formatting boot_b (${boot_b_dev}) as ext4 with label armbi_bootb" "info"
		run_host_command_logged mkfs.ext4 -q -L armbi_bootb "${boot_b_dev}" || display_alert "A/B partition OTA" "Failed to format boot_b" "warn"
	fi

	# Format rootfs_b as ext4 with label armbi_rootb
	if [[ -n "${AB_ROOTFS_B_PART_INDEX}" ]]; then
		local rootfs_b_dev="${LOOP}p${AB_ROOTFS_B_PART_INDEX}"
        check_loop_device "$rootfs_b_dev"
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			local mapper_name="armbian-rootb-build"
			local mapper_dev="/dev/mapper/${mapper_name}"
			[[ -n "${CRYPTROOT_PASSPHRASE}" ]] || exit_with_error "A/B encrypted OTA requires CRYPTROOT_PASSPHRASE for rootfs_b LUKS format" "AB_PART_OTA=yes CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes"
			command -v cryptsetup >/dev/null 2>&1 || exit_with_error "cryptsetup not found while formatting encrypted rootfs_b" "host dependency missing"

			display_alert "A/B partition OTA" "Formatting rootfs_b (${rootfs_b_dev}) as LUKS + ext4(label=armbi_rootb)" "info"
			printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksFormat ${CRYPTROOT_PARAMETERS} "${rootfs_b_dev}" - ||
				exit_with_error "A/B encrypted OTA failed to luksFormat rootfs_b" "${rootfs_b_dev}"
			printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksOpen "${rootfs_b_dev}" "${mapper_name}" - ||
				exit_with_error "A/B encrypted OTA failed to luksOpen rootfs_b" "${rootfs_b_dev}"
			run_host_command_logged mkfs.ext4 -q -L armbi_rootb "${mapper_dev}" || {
				run_host_command_logged cryptsetup luksClose "${mapper_name}" || true
				exit_with_error "A/B encrypted OTA failed to mkfs rootfs_b mapper" "${mapper_dev}"
			}
			run_host_command_logged cryptsetup luksClose "${mapper_name}" || exit_with_error "A/B encrypted OTA failed to luksClose rootfs_b mapper" "${mapper_name}"
		else
			display_alert "A/B partition OTA" "Formatting rootfs_b (${rootfs_b_dev}) as ext4 with label armbi_rootb" "info"
			run_host_command_logged mkfs.ext4 -q -L armbi_rootb "${rootfs_b_dev}" || display_alert "A/B partition OTA" "Failed to format rootfs_b" "warn"
		fi
	fi

	# Format userdata as ext4 with label armbi_usrdata
	if [[ -n "${AB_USERDATA_PART_INDEX}" ]]; then
		local userdata_dev="${LOOP}p${AB_USERDATA_PART_INDEX}"
        check_loop_device "$userdata_dev"
		display_alert "A/B partition OTA" "Formatting userdata (${userdata_dev}) as ext4 with label armbi_usrdata" "info"
		run_host_command_logged mkfs.ext4 -q -L armbi_usrdata "${userdata_dev}" || display_alert "A/B partition OTA" "Failed to format userdata" "warn"
	fi

	# Set PARTLABEL for rootfs_a if not set
	if [[ -n "${AB_ROOTFS_A_PART_INDEX}" ]]; then
		display_alert "A/B partition OTA" "Setting PARTLABEL for rootfs_a on partition ${AB_ROOTFS_A_PART_INDEX}" "info"
		run_host_command_logged parted ${LOOP} name ${AB_ROOTFS_A_PART_INDEX} "rootfs_a" || display_alert "A/B partition OTA" "Failed to set PARTLABEL for rootfs_a" "warn"
	fi
}

