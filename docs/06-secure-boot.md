# 6. Secure Boot (Signed Rockchip Bootchain)

On top of [encryption](05-encryption.md), the `secure-boot` tier signs the
whole boot path: if any piece is replaced, the board refuses to boot it. This
defends the device against persistent bootchain implants on hardware an
attacker can physically touch.

1. [What gets signed](#1-what-gets-signed)
2. [Build a secure-boot image](#2-build-a-secure-boot-image)
3. [Signing keys: keep them or regenerate them](#3-signing-keys-keep-them-or-regenerate-them)
4. [The mkimage PSS salt pitfall](#4-the-mkimage-pss-salt-pitfall)
5. [Device-tree overlays on secure-boot images](#5-device-tree-overlays-on-secure-boot-images)
6. [Updates on a signed system](#6-updates-on-a-signed-system)

## 1. What gets signed

```text
ROM → loader (idbloader, signed by rk_sign_tool cc/lk/sb/vb)
    → SPL ── verifies ──> U-Boot FIT u-boot.itb (ATF BL31 + OP-TEE BL32, RSA)
    → U-Boot ── verifies ──> kernel FIT boot.itb (kernel + dtb + initrd, RSA-PSS)
    → kernel unlocks LUKS root (see 05-encryption.md)
```

- The public key is embedded into the SPL device tree at build time — the
  SPL is the root of trust; everything above it is verified at each hop.
- The kernel FIT lives on a **raw boot partition** (no ext4): secure-boot
  images have no `/boot` filesystem at all, so nothing on it can be quietly
  edited at runtime.
- Build-time implementation:
  [`secure-boot-uboot.sh`](../rk_secure-disk-encryption/build-hooks/secure-boot-uboot.sh)
  (U-Boot FIT + loader signing) and
  [`secure-boot-image.sh`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh)
  (kernel FIT + raw boot flash); ITS templates per SoC under
  [`u-boot/fit-kernel/`](../rk_secure-disk-encryption/u-boot/fit-kernel).

## 2. Build a secure-boot image

```bash
CRYPTROOT_PASSPHRASE='<64-char-passphrase>' \
./build.sh recovery secure-boot -b recomputer-rk3576-devkit
```

This turns on: LUKS + automatic unlock + signed bootchain + Maskrom usbplug
build (`RK_COMPILE_USBPLUG`, opt out with `--no-usbplug`). The build fails if
any signature step does not verify — a signed image that boots is already
proof the chain is intact (build-time `fit_check_sign` gate).

## 3. Signing keys: keep them or regenerate them

Without configuration, **fresh RSA keys are generated per build** — every
build's images only verify against their own SPL. That is fine for
experimentation, wrong for a fleet.

For reproducible signing across builds, point the build at a persistent key
directory:

```bash
export UBOOT_FIT_KEYS_BACKUP_DIR=/secure/place/fit-keys   # passed through, never copied by the build
```

Rules ([`secure-boot-uboot.sh`](../rk_secure-disk-encryption/build-hooks/secure-boot-uboot.sh)):

- The directory must already contain `private_key.pem` (created once via
  `rk_sign_tool kk`); the build restores keys from it and saves newly
  generated keys back.
- Only the **path** crosses into the build container — the key material
  itself stays on the host.
- Lose the keys → future updates cannot be signed for already-flashed
  devices. Back the directory up like the
  [passphrase](05-encryption.md#2-build-an-encrypted-image).

## 4. The mkimage PSS salt pitfall

The board-side verifier only accepts RSA-PSS signatures with **maximum salt
length**. U-Boot's own `mkimage`, when built on a host with OpenSSL ≥ 3.5,
silently signs PSS with digest-length salt — the image verifies on the build
host and is **rejected by the board**.

This extension therefore signs with the **Rockchip rkbin prebuilt `mkimage`**
(resolved from the `rockchip_sdk_tools` cache; any signing-capable prebuilt
is accepted — the per-SoC rkbin builds differ, so the resolver filters by
capability, [`secure-boot-image.sh:131`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh#L131)).
The prebuilt is static and pins the max-salt behavior regardless of the
build container's OpenSSL. The tree-built `fit_check_sign` still runs as a
build-time verifier, so future toolchain drift fails the build instead of
the boot. Override with `RK_SECURE_BOOT_MKIMAGE` if you must.

The same rule applies offline: [repack-fit.sh](07-tools-and-ci.md) prefers
the prebuilt for re-signing and warns when falling back to a tree mkimage.

## 5. Device-tree overlays on secure-boot images

Normal Armbian loads `.dtbo` overlays from `/boot` at boot time — impossible
here, there is no `/boot` filesystem. Instead, the build **bakes** the
overlay set from `DEFAULT_OVERLAYS` into the FIT's device tree
([`secure-boot-image.sh:48`](../rk_secure-disk-encryption/build-hooks/secure-boot-image.sh#L48)).
To change overlays on an existing image without a full rebuild, use
[`repack-fit.sh`](07-tools-and-ci.md).

## 6. Updates on a signed system

OTA packages for secure-boot devices carry the signed `boot.itb` (verified
FIT magic, size, and written raw to the boot partition) and an encrypted,
manifest-signed rootfs payload — see
[Recovery OTA](03-ota-recovery.md#6-encrypted-images) /
[A/B OTA](04-ota-ab.md). The OTA public key is installed into the firmware
at build time; a payload whose manifest signature fails to verify is
refused (a manifest without a signature is accepted with a warning).
