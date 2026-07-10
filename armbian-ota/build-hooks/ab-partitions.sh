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

function ota_ab_append_partition() {
	local index_var="$1"
	local name="$2"
	local size="$3"
	local type="$4"

	printf -v "${index_var}" '%s' "${p_index}"
	script+="${p_index} : name=\"${name}\", start=${next}MiB, size=${size}MiB, type=${type}\n"
	next=$((next + size))
	p_index=$((p_index + 1))
}

function ota_ab_format_ext4_partition() {
	local dev="$1"
	local label="$2"
	local description="$3"

	check_loop_device "${dev}"
	display_alert "A/B partition OTA" "Formatting ${description} (${dev}) as ext4 with label ${label}" "info"
	run_host_command_logged mkfs.ext4 -q -L "${label}" "${dev}" || display_alert "A/B partition OTA" "Failed to format ${description}" "warn"
}

function ota_ab_format_luks_ext4_partition() {
	local dev="$1"
	local mapper_name="$2"
	local label="$3"
	local description="$4"
	local mapper_dev="/dev/mapper/${mapper_name}"

	check_loop_device "${dev}"
	[[ -n "${CRYPTROOT_PASSPHRASE}" ]] || exit_with_error "A/B encrypted OTA requires CRYPTROOT_PASSPHRASE for ${description} LUKS format" "AB_PART_OTA=yes CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes"
	command -v cryptsetup >/dev/null 2>&1 || exit_with_error "cryptsetup not found while formatting encrypted ${description}" "host dependency missing"

	display_alert "A/B partition OTA" "Formatting ${description} (${dev}) as LUKS + ext4(label=${label})" "info"
	printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksFormat ${CRYPTROOT_PARAMETERS} "${dev}" - ||
		exit_with_error "A/B encrypted OTA failed to luksFormat ${description}" "${dev}"
	printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksOpen "${dev}" "${mapper_name}" - ||
		exit_with_error "A/B encrypted OTA failed to luksOpen ${description}" "${dev}"
	run_host_command_logged mkfs.ext4 -q -L "${label}" "${mapper_dev}" || {
		run_host_command_logged cryptsetup luksClose "${mapper_name}" || true
		exit_with_error "A/B encrypted OTA failed to mkfs ${description} mapper" "${mapper_dev}"
	}
	run_host_command_logged cryptsetup luksClose "${mapper_name}" || exit_with_error "A/B encrypted OTA failed to luksClose ${description} mapper" "${mapper_name}"
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
	local unused_index
	local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
	if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
		# Keep GPT entry table compact to reduce SPL malloc pressure when probing partitions.
		local gpt_table_length="${AB_GPT_TABLE_LENGTH:-64}"
		script+="table-length: ${gpt_table_length}\n"
	fi

	# BIOS (if exists)
	if [[ -n "${BIOSSIZE}" && ${BIOSSIZE} -gt 0 ]]; then
		[[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]] || exit_with_error "BIOS partition only supports GPT" "BIOSSIZE=${BIOSSIZE}"
		ota_ab_append_partition unused_index "bios" "${BIOSSIZE}" "21686148-6449-6E6F-744E-656564454649"
	fi
	# EFI
	if [[ -n "${UEFISIZE}" && ${UEFISIZE} -gt 0 ]]; then
		local efi_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System
		ota_ab_append_partition unused_index "efi" "${UEFISIZE}" "${efi_type}"
	fi
	# boot_a
	local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
	local boot_a_index
	ota_ab_append_partition boot_a_index "boot_a" "${AB_BOOT_SIZE}" "${boot_type}"
	# boot_b
	local boot_b_index
	ota_ab_append_partition boot_b_index "boot_b" "${AB_BOOT_SIZE}" "${boot_type}"
	# security partition must be between boot_b and rootfs_a in AB+encrypted auto-decrypt mode.
	local security_index=""
	if rk_ab_autodecrypt_nonsecure_mode_enabled; then
		local sec_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
		ota_ab_append_partition security_index "security" "${SECURE_STORAGE_SECURITY_SIZE}" "${sec_type}"
	fi
	# rootfs_a
	local root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
	local rootfs_a_index
	ota_ab_append_partition rootfs_a_index "rootfs_a" "${AB_ROOTFS_SIZE}" "${root_type}"
	# rootfs_b
	local rootfs_b_index
	ota_ab_append_partition rootfs_b_index "rootfs_b" "${AB_ROOTFS_SIZE}" "${root_type}"

	# Add userdata partition with minimal size (1MiB)
	local userdata_index
	ota_ab_append_partition userdata_index "userdata" "${USERDATA}" "${root_type}"

	display_alert "A/B partition OTA" "Custom A/B partition table:\n${script}" "debug"
	echo -e "${script}" | run_host_command_logged sfdisk "${SDCARD}.raw" || exit_with_error "A/B partition creation failed" "sfdisk"

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
		ota_ab_format_ext4_partition "${boot_b_dev}" "armbi_bootb" "boot_b"
	fi

	# Format rootfs_b as ext4 with label armbi_rootb
	if [[ -n "${AB_ROOTFS_B_PART_INDEX}" ]]; then
		local rootfs_b_dev="${LOOP}p${AB_ROOTFS_B_PART_INDEX}"
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			ota_ab_format_luks_ext4_partition "${rootfs_b_dev}" "armbian-rootb-build" "armbi_rootb" "rootfs_b"
		else
			ota_ab_format_ext4_partition "${rootfs_b_dev}" "armbi_rootb" "rootfs_b"
		fi
	fi

	# Format userdata as ext4 with label armbi_usrdata
	if [[ -n "${AB_USERDATA_PART_INDEX}" ]]; then
		local userdata_dev="${LOOP}p${AB_USERDATA_PART_INDEX}"
		ota_ab_format_ext4_partition "${userdata_dev}" "armbi_usrdata" "userdata"
	fi

	# Set PARTLABEL for rootfs_a if not set
	if [[ -n "${AB_ROOTFS_A_PART_INDEX}" ]]; then
		display_alert "A/B partition OTA" "Setting PARTLABEL for rootfs_a on partition ${AB_ROOTFS_A_PART_INDEX}" "info"
		run_host_command_logged parted "${LOOP}" name "${AB_ROOTFS_A_PART_INDEX}" "rootfs_a" || display_alert "A/B partition OTA" "Failed to set PARTLABEL for rootfs_a" "warn"
	fi
}
