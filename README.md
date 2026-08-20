# Seeed Armbian Extension (RK35xx)

This repository contains Armbian extensions focused on:

- OTA updates (Recovery OTA / A/B Partition OTA)
- Disk encryption (LUKS) with automatic unlock (OP-TEE)
- Rockchip secure U-Boot / OP-TEE bootchain support
- PCIe ASPM is disabled in generated images through `extraargs=pcie_aspm=off`

## Repository Role

`seeed_armbian_extension.sh` is the extension entry script. It only enables sub-extensions based on environment variables and does not implement core features directly.

- `armbian-ota/`: OTA packaging and runtime tools
- `rk_secure-disk-encryption/`: encryption, auto-decryption, and secure boot image hooks

U-Boot board defconfigs are maintained in the Armbian build tree:

```text
/home/mingzq/armbian/build/patch/u-boot/legacy/u-boot-radxa-rk35xx/
└── defconfig/*_defconfig
```

This keeps board bootloader changes in the normal Armbian U-Boot patch flow. Secure boot specific U-Boot config fragments, kernel FIT ITS templates, and the ATF + OP-TEE FIT generator live in this extension under `rk_secure-disk-encryption/u-boot/`.

## Feature Matrix

| Feature | Key Flags | Description |
|---|---|---|
| Recovery OTA | `OTA_ENABLE=yes` and `AB_PART_OTA` unset | Single-system OTA applied in initramfs after reboot |
| A/B OTA | `OTA_ENABLE=yes AB_PART_OTA=yes` | Dual-slot OTA with rollback support |
| LUKS root | `CRYPTROOT_ENABLE=yes` | Enables encrypted root filesystem |
| Secure rootfs | `RK_OPTEE_BOOT_ENABLE=yes` | Enables LUKS root, OP-TEE/SSKR automatic unlock, and OP-TEE bootchain packaging |
| Secure boot | `RK_SECURE_UBOOT_ENABLE=yes` | Enables secure rootfs plus Rockchip secure U-Boot flow |

## Current Entry Behavior

Current relevant logic in `seeed_armbian_extension.sh`:

1. It validates `CRYPTROOT_PASSPHRASE` length when encryption is enabled; the passphrase must be exactly 64 characters or the build exits with error.
2. `RK_SECURE_UBOOT_ENABLE=yes` and `RK_OPTEE_BOOT_ENABLE=yes` are mutually exclusive.
3. When `RK_SECURE_UBOOT_ENABLE=yes` or `RK_OPTEE_BOOT_ENABLE=yes`, it enables:
   - `CRYPTROOT_ENABLE=yes`
   - `RK_AUTO_DECRYP=yes`
4. `RK_AUTO_DECRYP=yes` without `RK_SECURE_UBOOT_ENABLE=yes` or `RK_OPTEE_BOOT_ENABLE=yes` is rejected.
5. When `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes`:
   - `CRYPTROOT_SSH_UNLOCK=no`
   - Enables `rk_secure-disk-encryption/rk-auto-decryption-disk`
6. When `RK_SECURE_UBOOT_ENABLE=yes` or `RK_OPTEE_BOOT_ENABLE=yes`, it enables `rk_secure-disk-encryption/rk-secure-boot`.
7. When `OTA_ENABLE=yes`, it enables `armbian-ota/ota-support`.

## Quick Build Examples

Run board builds from the Armbian build tree:

```bash
cd /home/mingzq/armbian/build
```

When the host has a global HTTP proxy, clear it for reproducible rootfs and chroot APT work. `APT_PROXY_ADDR=none` also tells the Armbian helpers not to inject an APT proxy.

## Source Overrides

`rockchip_sdk_tools` defaults to the Seeed fork:

```bash
https://github.com/Seeed-Studio/rockchip_sdk_tools.git
```

Override it with `RKSDK_TOOLS_GIT_URL` and `RKSDK_TOOLS_BRANCH` when needed.

### 1) Recovery OTA firmware

```bash
./build.sh recovery -b recomputer-rk3576-devkit
```

### 2) A/B OTA firmware

```bash
./build.sh ab -b recomputer-rk3576-devkit
```

### 3) Secure rootfs firmware

```bash
CRYPTROOT_PASSPHRASE='your-64-char-passphrase' \
./build.sh secure-rootfs --minimal -b recomputer-rk3576-devkit
```

### 4) Secure U-Boot + encrypted recovery image

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
SEEED_RK_EXTENSION_OFFLINE=yes \
OFFLINE_WORK=yes \
APT_PROXY_ADDR=none \
CRYPTROOT_PASSPHRASE="$(< /home/mingzq/.config/armbian/rk3576-cryptroot-passphrase.txt)" \
./build.sh recovery secure-boot --minimal -b recomputer-rk3576-devkit
```

This enables recovery OTA, LUKS root, RK auto-decrypt, secure U-Boot, and RK Maskrom usbplug build through the `build.sh` wrapper.

### 5) Secure A/B OTA firmware

```bash
CRYPTROOT_PASSPHRASE='your-64-char-passphrase' \
./build.sh ab secure-boot -b recomputer-rk3576-devkit
```

## Secure Boot Extension Layout

Secure boot assets are extension-owned:

```text
rk_secure-disk-encryption/u-boot/
├── fit-generator/make_fit_atf_optee.sh
├── fit-kernel/rk3576_fit_kernel.its
├── fit-kernel/rk3588_fit_kernel.its
├── fragments/rk3576-secure-autodecrypt.config
└── fragments/rk3588-secure-autodecrypt.config
```

Build hook helper implementation is split into four files under `rk_secure-disk-encryption/build-hooks/`:

- `common.sh`: host command wrapper, SDK tool fetch/path helpers, mode predicates, platform detection, extension asset resolution, and Kconfig fragment application.
- `auto-decryption.sh`: non-secure OP-TEE bootchain defconfig preparation, OP-TEE client/keybox installation, initramfs hook installation, and secure-storage partition handling.
- `secure-boot-uboot.sh`: platform/rkbin/BL32 resolution, U-Boot FIT generator staging, secure config fragment application, FIT key preparation, and produced `u-boot.itb` validation.
- `secure-boot-image.sh`: kernel FIT bootargs, DTB bootargs injection, raw boot partition handling, resource image creation, final FIT packaging, and raw boot partition flashing.

`rk_secure-disk-encryption/rk-secure-boot.sh` is the secure boot extension entry and contains Armbian hook wrappers. It loads `build-hooks/common.sh`, `build-hooks/secure-boot-uboot.sh`, and `build-hooks/secure-boot-image.sh`.

`rk_secure-disk-encryption/rk-auto-decryption-disk.sh` is the auto-decryption extension entry and contains Armbian hook wrappers. It loads `build-hooks/common.sh` and `build-hooks/auto-decryption.sh`.

Supported platform detection currently targets RK3576 and RK3588 boards. Secure U-Boot uses the board's normal Armbian defconfig plus a platform-specific fragment from `rk_secure-disk-encryption/u-boot/fragments/`, the ATF+OP-TEE FIT generator from `rk_secure-disk-encryption/u-boot/fit-generator/`, and kernel FIT ITS templates from `rk_secure-disk-encryption/u-boot/fit-kernel/`.

Secure build responsibility is split as follows:

- Armbian build U-Boot patch overlay: board defconfigs and U-Boot patch application.
- `build-hooks/common.sh`: shared helpers used by RK extension entries.
- `rk-secure-boot.sh`: secure boot extension entry; exposes Armbian hooks and loads implementation from `build-hooks/secure-boot-uboot.sh` and `build-hooks/secure-boot-image.sh`.
- `rk-auto-decryption-disk.sh`: auto-decryption extension entry; exposes Armbian hooks and loads implementation from `build-hooks/auto-decryption.sh`.
- `armbian-ota/ota-support.sh`: Armbian extension entry point for OTA build hooks; implementation lives in `armbian-ota/build-hooks/`.

## OTA Runtime Usage

Unified command entry:

```bash
armbian-ota start --mode=recovery <ota-package.tar.gz>
armbian-ota start --mode=ab <ota-package.tar.gz>
armbian-ota status
armbian-ota mark-success
armbian-ota rollback
```

## Recovery OTA Behavior in Encrypted Auto-decrypt Mode

Current implementation highlights:

1. Detects auto-decrypt path via `PARTLABEL=security`.
2. Mounts and updates rootfs via `/dev/mapper/armbian-root`.
3. If a separate `boot` partition exists and payload includes `boot.tar.gz`, boot partition OTA is also applied.
4. Uses a two-step tar extraction strategy (metadata mode + plain fallback) and prints explicit errors on failure.

## OTA Payload Artifacts (Build Time)

`ota-support.sh` generates:

- `rootfs.tar.gz` (required)
- `rootfs.sha256`
- `boot.tar.gz` (when a separate boot partition exists)
- `boot.itb` (secure boot + encrypted rootfs)
- `boot.sha256` (for `boot.tar.gz` or `boot.itb`)
- `package.env`
- `version.txt` (image name, build commit, and extension commit)

The OTA package does not include an offline `ota_tools/` bundle. OTA runtime is
installed into the firmware during image creation.

## Directory Layout (Simplified)

```text
seeed_armbian_extension/
├── seeed_armbian_extension.sh                # Entry: extension orchestration only
├── armbian-ota/
│   ├── ota-support.sh                        # OTA build hook entry point
│   ├── build-hooks/                          # OTA build-time hook implementation
│   ├── runtime/                              # Unified armbian-ota CLI and shared libs
│   ├── recovery/                             # Recovery OTA backend
│   └── ab/                                   # A/B OTA userspace/systemd
└── rk_secure-disk-encryption/
    ├── rk-auto-decryption-disk.sh            # Auto-decryption extension entry
    ├── rk-secure-boot.sh                     # Secure U-Boot / OP-TEE bootchain extension entry
    ├── build-hooks/                          # RK build hook implementation modules
    │   ├── auto-decryption.sh
    │   ├── common.sh
    │   ├── secure-boot-image.sh
    │   └── secure-boot-uboot.sh
    ├── initramfs/                            # initramfs hook and decrypt scripts
    └── u-boot/
        ├── fit-generator/                    # ATF + OP-TEE U-Boot FIT generator
        ├── fit-kernel/                       # Final kernel FIT ITS templates
        └── fragments/                        # Platform secure U-Boot Kconfig fragments
```

## Development Convention

- Keep `seeed_armbian_extension.sh` focused on flag checks and `enable_extension` dispatching.
- Keep Armbian extension entry scripts at the feature directory root; put RK build hook implementation in `rk_secure-disk-encryption/build-hooks/*.sh`.
- Keep board U-Boot source patches and base defconfigs in `/home/mingzq/armbian/build/patch/u-boot/legacy/u-boot-radxa-rk35xx/`.
- Keep secure boot fragments, kernel FIT ITS templates, and extension-owned FIT generator files in `rk_secure-disk-encryption/u-boot/`.
- Keep shared helper implementation in `rk_secure-disk-encryption/build-hooks/common.sh`.
- Keep `rk-secure-boot.sh` focused on Armbian hook wrappers; put secure boot implementation in `secure-boot-uboot.sh` and `secure-boot-image.sh`.
- Keep `rk-auto-decryption-disk.sh` focused on Armbian hook wrappers; put auto-decryption implementation in `auto-decryption.sh`.

## Related Document

- OTA details: `armbian-ota/README.md`
