# Seeed Armbian Extension (RK35xx)

This repository contains Armbian extensions focused on:

- OTA updates (Recovery OTA / A/B Partition OTA)
- Disk encryption (LUKS) with automatic unlock (OP-TEE)

## Repository Role

`seeed_armbian_extension.sh` is the extension entry script. It only enables sub-extensions based on environment variables and does not implement core features directly.

- `armbian-ota/`: OTA packaging and runtime tools
- `rk_secure-disk-encryption/`: encryption and auto-decryption implementation

## Feature Matrix

| Feature | Key Flags | Description |
|---|---|---|
| Recovery OTA | `OTA_ENABLE=yes` and `AB_PART_OTA` unset | Single-system OTA applied in initramfs after reboot |
| A/B OTA | `OTA_ENABLE=yes AB_PART_OTA=yes` | Dual-slot OTA with rollback support |
| LUKS root | `CRYPTROOT_ENABLE=yes` | Enables encrypted root filesystem |
| Auto-decrypt | `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes` | Automatically unlocks encrypted root at boot |

## Current Entry Behavior

Current relevant logic in `seeed_armbian_extension.sh`:

1. It validates `CRYPTROOT_PASSPHRASE` length when encryption is enabled; the passphrase must be exactly 64 characters or the build exits with error.
2. When `CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes`:
   - `CRYPTROOT_SSH_UNLOCK=no`
   - Enables `rk_secure-disk-encryption/rk-auto-decryption-disk`
3. When `OTA_ENABLE=yes`, it enables `armbian-ota/ota-support`.

## Quick Build Examples

### 1) Recovery OTA firmware

```bash
export OTA_ENABLE=yes
./compile.sh
```

### 2) A/B OTA firmware

```bash
export OTA_ENABLE=yes
export AB_PART_OTA=yes
./compile.sh
```

### 3) Encrypted + auto-decrypt firmware

```bash
export CRYPTROOT_ENABLE=yes
export RK_AUTO_DECRYP=yes
export CRYPTROOT_PASSPHRASE='your-64-char-passphrase'
./compile.sh
```

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
    └── auto-decryption-config/               # initramfs hook and decrypt scripts
```

## Development Convention

- Keep `seeed_armbian_extension.sh` focused on flag checks and `enable_extension` dispatching.
- Put feature implementation in sub-extension scripts (for example `rk-auto-decryption-disk.sh`, `ota-support.sh`).

## Related Document

- OTA details: `armbian-ota/README.md`
