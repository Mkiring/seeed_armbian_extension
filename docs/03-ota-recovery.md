# 3. Recovery OTA (Single System)

Recovery OTA updates a single-system device: the new rootfs is staged on the
`userdata` partition and applied by the initramfs on the next reboot. Simple,
disk-efficient — one rootfs partition — but the update window is not
rollback-protected (unlike [A/B OTA](04-ota-ab.md)).

1. [Build the firmware](#1-build-the-firmware)
2. [Partition layout you are creating](#2-partition-layout-you-are-creating)
3. [Build the update package](#3-build-the-update-package)
4. [Apply an update on the device](#4-apply-an-update-on-the-device)
5. [What happens during the update reboot](#5-what-happens-during-the-update-reboot)
6. [Encrypted images](#6-encrypted-images)
7. [Troubleshooting](#7-troubleshooting)

## 1. Build the firmware

```bash
./build.sh recovery -b recomputer-rk3576-devkit
```

Flash the resulting image; the OTA runtime is preinstalled. From now on,
updates are just packages — no reflash.

## 2. Partition layout you are creating

Created by [`recovery/build-hooks/partitions.sh`](../armbian-ota/recovery/build-hooks/partitions.sh), located by GPT labels:

```text
plain:         [ boot ext4 ][ rootfs ext4 ][ userdata ext4 ]
auto-decrypt:  [ boot ext4 ][ security 4M ][ rootfs LUKS+ext4 ][ userdata LUKS+ext4 ]
secure boot:   [ boot raw FIT ][ security 4M ][ rootfs LUKS+ext4 ][ userdata LUKS+ext4 ]
```

| PARTLABEL | fs label | Role |
|---|---|---|
| `boot` | `armbi_boot` | `/boot`, mounted directly (never overlayed) — or raw FIT under secure boot |
| `security` | — | key material (encrypted images only) |
| `rootfs` | `armbi_root` | read-only rootfs lower layer |
| `userdata` | `armbi_usrdata` | overlay upper layer + OTA transaction store; auto-expands on first boot |

Sizes: [`OTA_BOOT_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L31)
(default 512 MiB), `OTA_ROOTFS_SIZE` (computed +30% headroom),
[`OTA_USERDATA_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L34)
(default 1024 MiB) — see [Build Reference](02-build-reference.md).

Because the rootfs is overlayed (`overlayroot` with `recurse=0`), runtime
writes — installed packages, `/home`, `/var/lib` — land on `userdata` and
survive updates. Only `/boot` is a direct mount, so kernel upgrades and
`armbianEnv.txt` edits are seen by U-Boot.

## 3. Build the update package

Any later build with the same profile **also** emits an OTA package next to
the image:

```text
output/images/Armbian_*_RECOVERY_*_OTA.tar.gz
```

Contents (assembled by [`package-create.sh`](../armbian-ota/common/build-hooks/package-create.sh)):

| File | Required | Notes |
|---|---|---|
| `rootfs.tar.gz` + `rootfs.sha256` | yes | new rootfs |
| `boot.tar.gz` + `boot.sha256` | ext4 boot | new `/boot` contents |
| `boot.itb` | secure boot | signed FIT, written raw — mutually exclusive with `boot.tar.gz` |
| `package.env` | yes | `OTA_MODE`, `OTA_ENCRYPTED`, board/release/branch/version/kernel metadata |
| `version.txt` | yes | image name, build commit, extension commit |
| `rootfs.tar.gz.enc`, `payload.manifest`, `payload.manifest.sig` | encrypted images | see [below](#6-encrypted-images) |

Transfer the package to the device any way you like (scp, USB, download).

## 4. Apply an update on the device

**On device:**

```bash
armbian-ota start /path/to/Armbian_..._RECOVERY_..._OTA.tar.gz
reboot
```

`armbian-ota start` ([source](../armbian-ota/common/rootfs/usr/sbin/armbian-ota)):

- takes exactly one argument — no options; the mode is auto-detected from
  `package.env` and must match the firmware (`OTA_MODE=recovery`),
- refuses a package whose encryption state differs from the device
  (`OTA_ENCRYPTED` vs. actual),
- verifies checksums (and, on encrypted images, the manifest signature),
- stages everything under `userdata/ota-recovery/ota_work/` and marks the
  state `prepared`.

Then reboot. The initramfs does the rest — see next section.

After the update reboot:

```bash
armbian-ota status     # STATUS=success
```

## 5. What happens during the update reboot

The initramfs hook
([`scripts/init-premount/99-ota-apply`](../armbian-ota/recovery/initramfs/scripts/init-premount/99-ota-apply),
with helpers in
[`recovery/initramfs/recovery/`](../armbian-ota/recovery/initramfs/recovery))
runs before the real root is mounted:

1. Anchors every device lookup to the disk U-Boot actually booted from
   (`armbian.bootdev`/`armbian.bootdevnum` cmdline tokens) — with several
   disks attached, a cloned disk can never capture the update.
2. Unlocks LUKS if needed, mounts the transaction store and root.
3. Validates the staged state and payload.
4. Applies the new rootfs with a single verified `tar` pass onto the root
   partition; applies `boot.tar.gz` to the boot partition (or dd-writes the
   verified `boot.itb` to the raw boot partition).
5. Patches `armbianEnv.txt`/fstab/crypttab for the new UUIDs, merges overlay
   settings, removes the staging area, marks `STATUS=success`, reboots.

**Failure behavior:** any error makes the hook exit 0 and boot the old
system; the staged payload is retried on every subsequent boot until it
succeeds. There is no retry counter and no automatic fallback to a previous
rootfs — if you need that, use [A/B OTA](04-ota-ab.md).

## 6. Encrypted images

On encrypted builds the update flow is identical from the user's perspective,
but:

- the package carries `rootfs.tar.gz.enc` instead of plaintext; the device
  verifies `payload.manifest.sig` (RSA-PSS) before decrypting, then re-checks
  digests — key derivation and verification in
  [`common.sh`](../armbian-ota/common/rootfs/usr/share/armbian-ota/common.sh);
- the initramfs applies the payload through `/dev/mapper/armbian-root`;
- the same passphrase/keys unlock everything — see
  [05-encryption.md](05-encryption.md).

## 7. Troubleshooting

**On device:**

```bash
armbian-ota status                    # state machine position
cat /var/log/armbian-ota/ota.log      # start-time verification/staging log
cat /run/initramfs/ota.log            # initramfs apply log (after reboot)
ls /dev/disk/by-partlabel/            # verify partitions are on the boot disk
```

| Symptom | Meaning |
|---|---|
| `OTA package encryption mismatch` | Package tier ≠ device tier — flash matching firmware or rebuild the package |
| `STATUS=prepared` persists after reboot | Initramfs apply keeps failing — read `/run/initramfs/ota.log` |
| Partition not found | It must live on the U-Boot boot disk (multi-disk anchoring) |

Developer internals (hook ordering, runtime file layout):
[`armbian-ota/README.md`](../armbian-ota/README.md).
