# Seeed Armbian Extension (RK35xx)

This repository contains Armbian extensions focused on:

- OTA updates (Recovery OTA / A/B Partition OTA)
- Disk encryption (LUKS) with automatic unlock (OP-TEE)
- Rockchip secure U-Boot / OP-TEE bootchain support

## Repository Role

`seeed_armbian_extension.sh` is the extension entry script. It only enables sub-extensions based on environment variables and does not implement core features directly.

- `armbian-ota/`: OTA packaging and runtime tools
- `rk_secure-disk-encryption/`: encryption, auto-decryption, and secure boot image hooks

U-Boot secure defconfigs, the ATF + OP-TEE FIT generator, and kernel FIT ITS templates are maintained in the Armbian build tree:

```text
/home/mingzq/armbian/build/patch/u-boot/legacy/u-boot-radxa-rk35xx/
├── defconfig/*-secure_defconfig
├── arch/arm/mach-rockchip/make_fit_atf_optee.sh
└── fit-kernel/*_fit_kernel.its
```

This keeps board bootloader changes in the normal Armbian U-Boot patch flow. The extension selects and stages those assets during secure builds, but does not carry its own copied `secure-boot-config/` tree.

## Feature Matrix

| Feature | Key Flags | Description |
|---|---|---|
| Recovery OTA | `OTA_ENABLE=yes` and `AB_PART_OTA` unset | Single-system OTA applied in initramfs after reboot |
| A/B OTA | `OTA_ENABLE=yes AB_PART_OTA=yes` | Dual-slot OTA with rollback support |
| LUKS root | `CRYPTROOT_ENABLE=yes` | Enables encrypted root filesystem |
| Auto-decrypt | `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes` | Automatically unlocks encrypted root at boot |
| Secure U-Boot | `RK_SECURE_UBOOT_ENABLE=yes` | Enables Rockchip secure U-Boot flow; forces `CRYPTROOT_ENABLE=yes` |
| OP-TEE bootchain | `RK_OPTEE_BOOT_ENABLE=yes` | Enables OP-TEE bootchain packaging without the full secure-boot overlay |

## Current Entry Behavior

Current relevant logic in `seeed_armbian_extension.sh`:

1. It validates `CRYPTROOT_PASSPHRASE` length when encryption is enabled; the passphrase must be exactly 64 characters or the build exits with error.
2. When `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes`:
   - `CRYPTROOT_SSH_UNLOCK=no`
   - Enables `rk_secure-disk-encryption/rk-auto-decryption-disk`
3. When `RK_SECURE_UBOOT_ENABLE=yes`:
   - Forces `CRYPTROOT_ENABLE=yes`
   - Enables `rk_secure-disk-encryption/rk-secure-boot`
4. When `RK_OPTEE_BOOT_ENABLE=yes`, it enables `rk_secure-disk-encryption/rk-secure-boot` in OP-TEE bootchain mode.
5. When `OTA_ENABLE=yes`, it enables `armbian-ota/ota-support`.

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

### 3) OP-TEE encrypted auto-decrypt firmware

```bash
CRYPTROOT_PASSPHRASE='your-64-char-passphrase' \
./build.sh optee --minimal -b recomputer-rk3576-devkit
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

`rk_secure-disk-encryption/rk-secure-boot.sh` is organized by related responsibilities:

1. Source fetching and mode predicates.
2. Platform, board, DTB, rkbin, secure `BOOTCONFIG`, and ITS template resolution.
3. U-Boot preparation hooks for FIT keys, secure `BOOTCONFIG`, OP-TEE BL32 FIT nodes, and produced `u-boot.itb` validation.
4. FIT image helpers for kernel bootargs, DTB bootargs injection, and `/boot` fstab cleanup.
5. Armbian partition, build, packaging, and final image hooks.

Supported platform detection currently targets RK3576 and RK3588 boards. Secure U-Boot uses `*-secure_defconfig`, the ATF+OP-TEE FIT generator, and kernel FIT ITS templates from the Armbian U-Boot patch overlay.

Secure build responsibility is split as follows:

- Armbian build U-Boot patch overlay: secure defconfig, `make_fit_atf_optee.sh`, FIT kernel ITS templates, and U-Boot patch application.
- `rk-secure-boot.sh`: switches `BOOTCONFIG` to the secure defconfig, stages BL32 as `tee.bin`, validates the produced `u-boot.itb`, injects encrypted-root bootargs, and rebuilds the final kernel FIT after initramfs generation.
- `rk-auto-decryption-disk.sh`: prepares the runtime auto-decrypt path for encrypted rootfs.
- `armbian-ota/ota-support.sh`: creates recovery or A/B OTA payloads from the final image rootfs/boot content.

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
- `boot.sha256`
- `package.env`
- `manifest.txt`
- `ota_tools/` (offline/fallback runtime tools)

## Directory Layout (Simplified)

```text
seeed_armbian_extension/
├── seeed_armbian_extension.sh                # Entry: extension orchestration only
├── armbian-ota/
│   ├── ota-support.sh                        # OTA build and packaging logic
│   ├── runtime/                              # Unified armbian-ota CLI and backends
│   ├── recovery_ota/                         # Recovery OTA (initramfs apply)
│   └── ab_ota/                               # A/B OTA userspace/systemd
└── rk_secure-disk-encryption/
    ├── rk-auto-decryption-disk.sh            # Auto-decryption workflow
    ├── rk-secure-boot.sh                     # Secure U-Boot / OP-TEE bootchain hooks
    └── auto-decryption-config/               # initramfs hook and decrypt scripts
```

## Development Convention

- Keep `seeed_armbian_extension.sh` focused on flag checks and `enable_extension` dispatching.
- Put feature implementation in sub-extension scripts (for example `rk-auto-decryption-disk.sh`, `ota-support.sh`).
- Keep U-Boot source patches, secure defconfigs, FIT generators, and ITS templates in `/home/mingzq/armbian/build/patch/u-boot/legacy/u-boot-radxa-rk35xx/`.
- Keep `rk-secure-boot.sh` focused on Armbian hooks, board/platform selection, artifact staging, validation, and final image integration.

## Related Document

- OTA details: `armbian-ota/README.md`
