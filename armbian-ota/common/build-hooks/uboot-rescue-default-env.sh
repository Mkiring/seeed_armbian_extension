# Stage the Seeed rescue-default-env U-Boot patch (recovery OTA v0.8 design
# section 3.4) into the userpatches overlay for EVERY build flavor, picking
# the patch matching the board's U-Boot tree (radxa rk3576/rk3588 vs rockchip
# v2025.04 rk3572 -- see the case in the hook body).
#
# The patch's default bootcmd is self-routing: ota_rescue_boot boots the
# /recovery/ assets only when they exist and falls through to
# distro_bootcmd otherwise, so the same compiled U-Boot is correct for
# recovery-OTA, plain and A/B images. Staging unconditionally keeps:
#   - one stable U-Boot artifact hash across flavors sharing a checkout
#     (patches_hash covers this location; a gated patch used to bump the
#     artifact version and thrash the cache whenever flavors alternated);
#   - no stale-patch risk window (the previous stage/sweep pair had to run
#     on every single build or a recovery build's patch leaked into the
#     next plain build's U-Boot).
#
# Staging targets USERPATCHES_PATH (not SRC/patch) so the framework tree
# stays untouched. The patch versions together with the rest of the v0.8
# pieces under this repository's release tags.

function post_family_config__seeed_ota_stage_uboot_rescue_default_env() {
	local extension_common_root patch_src
	local boot_patch_dir target_dir target_patch

	extension_common_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

	# BOOTPATCHDIR is a space-separated list; the base family dir comes first.
	# Each U-Boot tree needs its own patch: the rk3572 rockchip v2025.04 tree
	# (rk3572_common.h, bootcmd composed in rockchip-common.h) shares no patch
	# context with the radxa rk3576/rk3588 tree (rk3576/rk3588_common.h,
	# config_distro_bootcmd.h) -- staging the radxa patch there fails to apply.
	boot_patch_dir="${BOOTPATCHDIR%% *}"
	case "${boot_patch_dir}" in
		rk3572-vendor-v2025.04)
			patch_src="${extension_common_root}/patches/seeed-ota-rescue-default-env-v2025.04.patch"
			;;
		*)
			patch_src="${extension_common_root}/patches/seeed-ota-rescue-default-env.patch"
			;;
	esac

	[[ -f "${patch_src}" ]] ||
		exit_with_error "seeed-ota" "rescue-default-env patch missing: ${patch_src}"

	target_dir="${USERPATCHES_PATH}/u-boot/${boot_patch_dir}"
	target_patch="${target_dir}/seeed-ota-rescue-default-env.patch"

	mkdir -p "${target_dir}"
	cp -f "${patch_src}" "${target_patch}"
	display_alert "seeed-ota" "staged rescue-default-env U-Boot patch -> ${target_dir}" "info"
}
