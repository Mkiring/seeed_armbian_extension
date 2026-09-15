# Seeed Armbian Extension (RK35xx)

Armbian board-support extensions for Seeed reComputer RK3576/RK3588 devices:

- **OTA updates** — Recovery (single system, initramfs-applied) and A/B (dual slot with health checks and automatic rollback)
- **Disk encryption** — LUKS rootfs with unattended automatic unlock (security partition + OP-TEE)
- **Secure boot** — Rockchip signed bootchain: loader → SPL → U-Boot FIT (ATF + OP-TEE) → signed kernel FIT
- **Robustness extras** — SSH power-loss recovery, multi-disk boot anchoring, PCIe ASPM off (`extraargs=pcie_aspm=off`)

> New here? Follow the step-by-step guides under [`docs/`](docs/README.md) —
> from environment setup to your first OTA update.

## Quick Start

Builds run from an Armbian build tree with this extension cloned alongside.
The `scripts/build.sh` wrapper must be staged next to `compile.sh` (see
[docs/01-getting-started.md](docs/01-getting-started.md); full reference in
[docs/02-build-reference.md](docs/02-build-reference.md)):

```bash
cd <armbian-build>    # scripts/build.sh staged next to compile.sh

# Recovery OTA image
./build.sh recovery -b recomputer-rk3576-devkit

# A/B OTA image
./build.sh ab -b recomputer-rk3576-devkit

# Encrypted + signed recovery image (64-char passphrase!)
CRYPTROOT_PASSPHRASE='<64-char-passphrase>' \
./build.sh recovery secure-boot --minimal -b recomputer-rk3576-devkit

# Encrypted + signed A/B image
CRYPTROOT_PASSPHRASE='<64-char-passphrase>' \
./build.sh ab secure-boot -b recomputer-rk3576-devkit
```

Images land in `output/images/`, logs in `output/logs/`.

## Applying an Update on the Device

```bash
armbian-ota start <package>_OTA.tar.gz    # mode auto-detected from the package
reboot
armbian-ota status                        # check state after reboot
armbian-ota switch-slot [a|b]             # A/B firmware only
```

Details and troubleshooting: [docs/03-ota-recovery.md](docs/03-ota-recovery.md),
[docs/04-ota-ab.md](docs/04-ota-ab.md).

## Feature Matrix

| Feature | Key flags | Description |
|---|---|---|
| Recovery OTA | `OTA_ENABLE=yes`, `AB_PART_OTA` unset | Single-system OTA applied in initramfs after reboot |
| A/B OTA | `OTA_ENABLE=yes AB_PART_OTA=yes` | Dual-slot OTA with health checks and automatic rollback |
| LUKS root | `CRYPTROOT_ENABLE=yes` | Encrypted root filesystem (upstream Armbian flow) |
| Secure rootfs | `RK_OPTEE_BOOT_ENABLE=yes` | LUKS + OP-TEE/SSKR automatic unlock, unsigned bootchain |
| Secure boot | `RK_SECURE_UBOOT_ENABLE=yes` | Secure rootfs plus Rockchip signed boot flow |

OTA flags combine freely with the encryption tiers (plain / secure-rootfs / secure-boot).

## Documentation

| Guide | What you will learn |
|---|---|
| [docs/01-getting-started.md](docs/01-getting-started.md) | Prepare the environment, stage the wrapper, run your first build |
| [docs/02-build-reference.md](docs/02-build-reference.md) | Every `build.sh` profile/option and every environment variable, linked to source |
| [docs/03-ota-recovery.md](docs/03-ota-recovery.md) | Recovery OTA end to end: build → flash → update → troubleshoot |
| [docs/04-ota-ab.md](docs/04-ota-ab.md) | A/B OTA end to end: slots, rollback layers, slot switching |
| [docs/05-encryption.md](docs/05-encryption.md) | LUKS + automatic unlock: how the secret flows, what to guard |
| [docs/06-secure-boot.md](docs/06-secure-boot.md) | Signed bootchain, signing keys, the mkimage/PSS salt pitfall |
| [docs/07-tools-and-ci.md](docs/07-tools-and-ci.md) | Offline FIT re-signing, deb release chain, CI builds |
| [`armbian-ota/README.md`](armbian-ota/README.md) | OTA internals reference (developer-oriented) |
| [`CHANGELOG.md`](CHANGELOG.md) | Notable changes |

## Repository Layout

```text
seeed_armbian_extension/
├── seeed_armbian_extension.sh    # Entry: flag checks + sub-extension dispatch only
├── armbian-ota/                  # OTA build hooks + runtime (common / recovery / ab)
├── rk_secure-disk-encryption/    # Encryption, auto-unlock, secure boot hooks
├── ssh-protect/                  # SSH power-loss recovery (always enabled)
├── initramfs/                    # Boot-device root anchor (init-top)
├── rk-uboot-postprocess/         # U-Boot post-processing (always enabled)
├── security-hardening/           # Board security hardening (always enabled)
├── scripts/                      # build.sh, repack-fit.sh, deb release chain
└── docs/                         # The guides linked above
```

Board U-Boot defconfigs live in the Armbian build tree
(`patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig/`); secure-boot fragments,
kernel FIT ITS templates, and the ATF+OP-TEE FIT generator live in
`rk_secure-disk-encryption/u-boot/`.

## Entry-Script Rules

`seeed_armbian_extension.sh` only composes flags — it implements nothing:

1. `RK_SECURE_UBOOT_ENABLE` and `RK_OPTEE_BOOT_ENABLE` are mutually exclusive.
2. Either one auto-enables `CRYPTROOT_ENABLE=yes` + `RK_AUTO_DECRYP=yes`.
3. `RK_AUTO_DECRYP=yes` without one of them is rejected.
4. Auto-decrypt forces `CRYPTROOT_SSH_UNLOCK=no` — the unlock passphrase has
   exactly one source, no SSH side channel.
5. `OTA_ENABLE=yes` enables the OTA hooks (mode selected by `AB_PART_OTA`).

The passphrase is validated **non-empty only** at build time; use 64
characters — that is the exact byte count the initramfs reads back at unlock
([docs/05-encryption.md](docs/05-encryption.md)).
