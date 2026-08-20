# Changelog

All notable changes to the Seeed Armbian board support extensions are
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — secure boot, OTA overhaul, build wrapper

Covers the work on `fix/secure_boot` against `main`
(merge base `9980aee`, 2026-07-02 → 2026-07-27, 105 commits).

### Added

#### Recovery OTA

- **Dedicated `/boot` partition for all Recovery images.** Plain and
  auto-decrypt Recovery builds now reserve a separate ext4 boot partition
  (label `armbi_boot`) and mount it via fstab on top of overlayfs. This
  fixes runtime writes to `/boot` (apt kernel upgrades, `armbianEnv.txt`
  edits, OTA tooling) being swallowed by the overlayfs upper layer on
  userdata and silently ignored by U-Boot on next boot. Secure-boot
  Recovery continues to use a raw FIT boot partition (`BOOT_RAW_MODE=yes`),
  unchanged. The partition order is now `[boot][security?][rootfs][userdata]`.
- **`recurse=0` on overlayroot.** The overlayroot package's init-bottom
  hook defaults to `recurse=1`, which wraps every fstab mount point in a
  per-directory overlay — so even with a dedicated boot partition, `/boot`
  was still being overlayed and writes were captured by userdata. Setting
  `recurse=0` keeps the overlay on `/` only and leaves `/boot` (and any
  other non-root fstab mount) as a direct mount. Verified on a
  `recomputer-rk3588-devkit` image: `/boot` is now mounted directly from
  `armbi_boot` and writes reach the raw partition.

#### Secure boot & secure rootfs

- **Rockchip secure U-Boot bootchain.** New `RK_SECURE_UBOOT_ENABLE=yes`
  profile builds U-Boot with ATF + OP-TEE (BL32), packages the kernel as a
  signed FIT, and flashes a raw boot partition. LUKS root and OP-TEE/SSKR
  automatic unlock are enabled automatically.
- **OP-TEE secure rootfs.** New `RK_OPTEE_BOOT_ENABLE=yes` profile enables
  LUKS root + OP-TEE automatic unlock *without* the full secure U-Boot flow.
  It is mutually exclusive with `RK_SECURE_UBOOT_ENABLE`.
- **Extension-owned secure boot assets** under `rk_secure-disk-encryption/u-boot/`:
  - `fit-generator/make_fit_atf_optee.sh` — ATF + OP-TEE U-Boot FIT generator
  - `fit-kernel/rk3576_fit_kernel.its`, `rk3588_fit_kernel.its` — final kernel
    FIT ITS templates, split per SoC
  - `fragments/rk3576-secure-autodecrypt.config`,
    `fragments/rk3588-secure-autodecrypt.config` — secure U-Boot Kconfig fragments
- **Secure A/B FIT OTA.** The A/B backend verifies `boot.itb` and writes it
  directly to the inactive raw `boot_a`/`boot_b` partition. It never mounts a
  FIT boot partition or treats the FIT image as `boot.tar.gz`.
- **Caller-supplied FIT key directory.** Secure boot can sign with a key
  directory provided by the caller, and verifies the embedded SPL FIT key
  material during build.
- **Encrypted A/B and Recovery OTA.** Both A/B modes create a shared `security`
  partition and format both rootfs slots as LUKS-backed ext4 when automatic
  decryption is enabled. Encrypted images use the initramfs-unlocked
  `/dev/mapper/armbian-userdata` mapper as the overlayroot backing device.

#### OTA

- **New modular OTA layout.** `armbian-ota/` is reorganized into
  `common/`, `recovery/`, and `ab/`, each with a `build-hooks/`
  (build-time) and `rootfs/` (image contents) tree. Files under each
  `rootfs/` mirror their final path in the image and are installed via
  `rsync`.
- **Mode auto-detection.** The unified `armbian-ota` CLI detects OTA mode from
  the package manifest — `--mode=recovery` / `--mode=ab` is no longer required.
- **Encrypted A/B OTA backend** with slot selection by active slot, encrypted
  A/B root slot detection, and shared-security-partition layout.
- **Recovery full-root overlayroot.** Recovery OTA now uses a full-root
  overlayroot with the final `userdata` partition as the writable upper layer,
  plus persistent overlays for `/etc`, `/home`, and `/var/lib`.
- **`armbian-ota switch-slot [a|b]`** for manual slot maintenance after OTA
  has completed (replaces the old manual `rollback`/`mark-success` commands,
  which are now driven automatically by systemd units).
- **A/B rootfs size tiers** and configurable partition sizing: `OTA_BOOT_SIZE`,
  `OTA_USERDATA_SIZE`, `OTA_SECURITY_SIZE`, and optional `OTA_ROOTFS_SIZE`
  (auto-calculated from built rootfs + headroom when unset).
- **Package metadata & versioning.** OTA packages now ship `package.env`
  (mode + metadata, replacing `ota_manifest.*`) and `version.txt`
  (image name, version, build commit, extension commit). An OTA-mode suffix
  is appended to image filenames.
- **First-boot userdata resize** for both modes via `armbian-resize-userdata.service`.
  Encrypted images log that a reboot is required, then reopen the
  `armbian-userdata` LUKS mapper at its new size on the next boot.

#### Build & entry script

- **`scripts/build.sh` profile wrapper.** A single entry point composes build
  profiles (`recovery`, `ab`, `secure-rootfs`, `secure-boot`) with board,
  release, desktop, and tier options, replacing raw `export`-then-`compile.sh`
  invocations.
- **Self-applying patch bundles.** The extension entry now stages its own
  patches into the Armbian build tree:
  - `patches/armbian-build/0001-rk3588-enable-panthor-gpu-stack.patch`
  - `patches/u-boot/000{1,2,3}-u-boot-*.patch` (FIT env partition fallback,
    OS-boot-device scan after SPI boot, recomputer defconfig normalization)
  - `patches/firstlogin/0001-firstlogin-restart-ssh-on-failure.patch`
  Each is applied idempotently with reverse-check guarding.
- **Seeed SDK tools fork.** `rockchip_sdk_tools` defaults to the Seeed fork
  (`github.com/Seeed-Studio/rockchip_sdk_tools.git`), overridable via
  `RKSDK_TOOLS_GIT_URL` / `RKSDK_TOOLS_BRANCH`.
- **Mirror/cache passthrough** through the build wrapper.
- **PCIe ASPM disabled** in generated images via `extraargs=pcie_aspm=off`.

### Changed

- **OTA entry script slimmed down.** `ota-support.sh` is now a thin Armbian
  hook entry point (was a ~1130-line monolith); implementation moved into
  `armbian-ota/build-hooks/`.
- **Secure boot / auto-decrypt hooks modularized.** `rk-secure-boot.sh` and
  `rk-auto-decryption-disk.sh` are now Armbian hook wrappers that load
  implementation from `rk_secure-disk-encryption/build-hooks/{common,
  auto-decryption,secure-boot-uboot,secure-boot-image}.sh`.
- **U-Boot environment handling.** Non-secure A/B images store boot state at
  the fixed raw U-Boot env offset (`0x3f8000`, `0x8000`) via distro `fw_*env`
  tools. Filesystem A/B packages U-Boot's complete compiled default
  environment and merges A/B variables into `/etc/u-boot-initial-env`, so
  first-boot `fw_setenv -f` does not discard commands like `distro_bootcmd`.
- **Persistent data model.** User account DB files (`passwd`, `shadow`,
  `group`, `gshadow`, `subuid`, `subgid`) remain normal overlay files (needed
  for `useradd`/`groupadd` atomic rewrite). Runtime writes to `/home` and
  `/var/lib` persist on `armbi_usrdata` via overlayroot.
- **Recovery payload location** moved to `userdata/ota-recovery/ota_work/`;
  the initramfs rewrites only the raw rootfs lower layer and leaves userdata
  intact.
- **Board U-Boot defconfigs** are maintained in the Armbian build tree
  (`patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig/`), keeping bootloader
  changes in the normal Armbian U-Boot patch flow.

### Removed

- **`firstlogin-protection/` extension dropped** (upstreamed). The hardened
  firstlogin logic and its atomic-write / hardening patches
  (`armbian-common-atomic-write.patch`,
  `armbian-firstlogin-hardening.patch`, `armbian-firstrun-atomic-write.patch`)
  are removed; a small `0001-firstlogin-restart-ssh-on-failure.patch` replaces
  the SSH-restart behavior.
- **Offline `ota_tools/` bundle** removed from OTA packages — the OTA runtime
  is now installed into the firmware at image build time.
- **Old OTA directory structure** removed: `runtime/` (monolithic CLI +
  backends), `recovery_ota/` (incl. `fit/fit-ota`, `99-ota-apply`),
  `ab_ota/`, and the standalone `armbian-resize-userdata` unit — all replaced
  by the new `common/` + `recovery/` + `ab/` layout.
- **Dead/redundant OTA helpers** cleaned up (userdata persist helper, NVMe
  bootscript env import, OTA verbosity hooks, manual `rollback` CLI).
- **Old auto-decrypt assets** removed (`auto-decrypt-disk.sh` standalone,
  `rk-cryptroot-verbosity.sh`, board defconfigs that lived in-repo).

### Fixed

- `fix(build)`: keep the cryptroot passphrase out of `argv` (pass via env/stdin
  instead of command line).
- `fix(autodecrypt)`: apply the defconfig fragment *after* patching; retain
  SPL FIT key material; restore FIT signing tools after USBPLUG build.
- `fix(ota)`: mark filesystem A fallback bootable; preserve the complete
  U-Boot environment; fail hard on A/B update / runtime-state / preserve-copy
  errors; detect and select encrypted A/B root slots by active slot.
- `fix(ota)`: defer encrypted userdata resize until reboot; resize encrypted
  userdata without prompting.
- `fix(recovery)`: use BusyBox-compatible `tar` extraction in the initramfs.
- `fix(secure-boot)`: isolate the U-Boot package name; verify the embedded SPL
  FIT key; sign the final secure boot FIT directly.
- `fix(firstlogin)`: restart SSH without aborting first-login setup.
- `build`: close a stale cryptroot mapper before image build.

## [1.0.0] — 2026-04-14

Initial import of the Seeed Armbian extension: OTA updates (Recovery + A/B),
LUKS disk encryption with OP-TEE auto-decrypt, firstlogin hardening, and
security hardening.

[Unreleased]: https://github.com/Seeed-Studio/seeed_armbian_extension/compare/v1.0...fix/secure_boot
[1.0.0]: https://github.com/Seeed-Studio/seeed_armbian_extension/releases/tag/v1.0
