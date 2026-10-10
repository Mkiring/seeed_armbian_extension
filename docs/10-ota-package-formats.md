# 10. OTA Package Formats and Apply Hooks

Specification for payload-format negotiation and package-provided apply hooks.
Mechanics background: [OTA Internals](09-ota-internals.md).

1. [Package layout](#1-package-layout)
2. [Format negotiation](#2-format-negotiation)
3. [Format map](#3-format-map)
4. [Apply hooks](#4-apply-hooks)
5. [Compatibility matrix and the transition train](#5-compatibility-matrix-and-the-transition-train)
6. [Build-side variables](#6-build-side-variables)

## 1. Package layout

Members at the package root (outer tar; see format map for compression):

| Member | Required | Role |
|---|---|---|
| `package.env` | yes | first member; mode, format, hook declaration |
| `boot.tar.<fmt>` | no | boot partition payload |
| `boot.sha256` | with boot tar | checksum |
| `boot.itb` | secure boot | raw FIT image (replaces boot tar) |
| `rootfs.tar.<fmt>` | yes | rootfs payload |
| `rootfs.sha256` | yes | checksum |
| `rootfs.tar.<fmt>.enc` | encrypted builds | replaces plaintext rootfs tar |
| `payload.manifest` + `.sig` | encrypted builds | cipher params + plaintext hashes, RSA-PSS signed |
| `ota-apply-hook.sh` | no | package-provided apply logic (see §4) |
| `hook.sha256` | with hook | checksum |
| `version.txt` | yes | provenance |

## 2. Format negotiation

The package declares what it needs; the runtime declares what it can do.
Phase 1 fails fast with actionable errors instead of dying in the initramfs.

`package.env` keys (all additive; old packages simply lack them):

| Key | Meaning | Default when absent |
|---|---|---|
| `PAYLOAD_FORMAT` | payload compression: `gz`, `xz`, `zstd` | inferred from the suffix actually staged (legacy behavior) |
| `MIN_RUNTIME_VERSION` | minimum `OTA_RUNTIME_VERSION` required | no check |
| `OTA_APPLY_HOOK` | filename of the apply hook at package root | conventional name `ota-apply-hook.sh` if present, else none |

Runtime constants (`common.sh`, mirrored in the initramfs lib):

```sh
OTA_RUNTIME_VERSION="1.1"
OTA_RUNTIME_FORMATS="gz xz"   # what this runtime's initramfs can decode
```

Phase-1 checks, in order:

1. `MIN_RUNTIME_VERSION` > device `OTA_RUNTIME_VERSION` →
   `device OTA runtime too old (have X, need Y); upgrade the OTA tooling first`
2. `PAYLOAD_FORMAT` ∉ `OTA_RUNTIME_FORMATS` →
   `device OTA runtime cannot decode '<fmt>' payloads (supports: ...)`; note
   the check applies to the **initramfs** capability set even though phase 1
   runs in the full system
3. suffix resolution and the magic-byte sniff must agree with the declaration

`OTA_RUNTIME_VERSION` tracks the `armbian-ota` deb version and must be bumped
whenever `OTA_RUNTIME_FORMATS` or the hook contract changes.

## 3. Format map

One table, mirrored in three places (`package-create.sh` build side,
`common.sh`, the initramfs payload lib). Adding a format means adding one row
everywhere — no scattered `if/else`:

| fmt | suffix | magic (first bytes) | build command | tar extract flag | initramfs tool |
|---|---|---|---|---|---|
| gz | `.tar.gz` | `1f 8b` | `tar -czf` | `-xzf` | gzip |
| xz | `.tar.xz` | `fd 37 7a 58 5a 00` | `tar -cf - \| xz -6 -T0` (multi-block for threaded decode) | `-xJf` | xz + liblzma |
| zstd | `.tar.zst` | `28 b5 2f fd` | `tar -cf - \| zstd -19 -T0 --long=27` | `--zstd` | zstd + libzstd |

The magic sniff (`ota_verify_tar_magic`) runs before extraction: a suffix that
disagrees with the file contents is refused, so a renamed archive cannot bypass
negotiation. Extraction flags are unified across modes: recovery-phase-2
extraction uses the same `--xattrs --acls --numeric-owner` set as A/B.

zstd is wired through the map and the build selector, but `OTA_RUNTIME_FORMATS`
only lists it once the image actually ships the zstd CLI (the initramfs hook
copies zstd + libzstd into the initrd whenever the rootfs has them, ~2 MB).

## 4. Apply hooks

A package may carry its own application logic so that format or layout changes
can ship to deployed runtimes without a tool upgrade first.

### Trigger and priority

Phase 1 validates the hook like any payload member (existence + `hook.sha256`;
in encrypted builds the hook name and hash are covered by the signed
`payload.manifest`). The hook rides the staging directory into phase 2.

Phase 2 checks the staging directory for the declared (or conventional) hook
name. **Hook present → `hook_main()` replaces the payload-application section.
Absent → the built-in path runs unchanged.** Mounting, device detection, state
commits, unmounting, and reboot stay with the orchestrator in both modes.

### Contract

The hook is **sourced**, then `hook_main()` is called. It must be POSIX `sh`
(recovery hooks execute under busybox in the initramfs; AB hooks under bash in
the live system). Contract version: `OTA_HOOK_API=1`.

Injected environment:

| Variable | Recovery (initramfs) | AB (live system) |
|---|---|---|
| `OTA_HOOK_MODE` | `recovery` | `ab` |
| `OTA_DIR` | staging dir on userdata | staging dir |
| `ROOT_MNT`, `BOOT_MNT` | mounted root/boot targets | mounted target-slot root/boot |
| `ROOTFS_TAR`, `BOOT_TAR`, `BOOT_ITB` | resolved payload paths | same |
| `HAS_BOOT_PART`, `ROOT_UUID`, `BOOT_UUID`, `AUTO_DECRYPT_MODE` | device facts | same |

Callable helpers (recovery): `log`, `start_heartbeat`/`stop_heartbeat`,
`extract_tar`, `write_raw_boot_itb`, `ota_patch_config`, the `device.sh`
primitives. AB hooks use the `log_*` family and `ab_*` helpers.

Rules:

- `hook_main` returns 0 on success, non-zero on fatal failure (orchestrator
  aborts exactly like a built-in failure)
- hooks must **not** unmount anything, write the state file, or reboot — the
  orchestrator owns teardown and state transitions in both success and failure
  paths
- scope is payload application only: rootfs/boot apply, raw FIT write, and any
  custom partition layout the package brings

### Security

Plain packages: the hook runs as root, but the package already ships an entire
rootfs — no new trust boundary; the hook is checksummed like every member.
Encrypted/secure-boot packages: the signed manifest covers the hook name and
hash, so a tampered hook fails signature verification.

## 5. Compatibility matrix and the transition train

| Device runtime \ Package | gz (legacy) | xz/zstd, no hook | with hook |
|---|---|---|---|
| legacy (no negotiation, no hook) | works | clean refusal at extraction | hook ignored — behaves like the previous column |
| this runtime (`1.1`) | works | works (format within capability set) | hook takes over |

A hook cannot rescue a runtime that predates hook support — that code cannot
look for one. Therefore one release discipline applies:

> **Transition train:** the first runtime with negotiation + hooks ships to
> the installed base inside a **legacy gz package** (the new runtime is simply
> part of that rootfs). Every later format or layout evolution rides an apply
> hook, and deployed devices never need a two-step "upgrade tool, then
> upgrade system" dance again.

`version.txt` carries `RUNTIME_BOOTSTRAP=yes` on that one package so operators
can identify it.

## 6. Build-side variables

| Variable | Values | Effect |
|---|---|---|
| `OTA_PAYLOAD_COMP` | `xz` (default), `gz`, `zstd` | payload + outer package layout (see `package-create.sh`) |
| `OTA_APPLY_HOOK_SCRIPT` | path | file shipped as `ota-apply-hook.sh` + `hook.sha256`; absent by default |
| `OTA_MIN_RUNTIME_VERSION` | version | stamped into `package.env` |
