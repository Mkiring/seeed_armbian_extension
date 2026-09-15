# 7. Tools and CI

The utility belt around the firmware: offline FIT re-signing, the deb
release chain, CI builds — plus the always-on `ssh-protect` robustness
feature.

1. [repack-fit.sh — offline FIT re-signing](#1-repack-fitsh--offline-fit-re-signing)
2. [ssh-protect — SSH power-loss recovery](#2-ssh-protect--ssh-power-loss-recovery)
3. [Deb packaging and release chain](#3-deb-packaging-and-release-chain)
4. [CI builds (Seeed Build workflow)](#4-ci-builds-seeed-build-workflow)

## 1. repack-fit.sh — offline FIT re-signing

[`scripts/repack-fit.sh`](../scripts/repack-fit.sh) rebuilds a signed kernel
FIT from an **existing** `boot.itb` — extract components, apply a new dtbo
list, re-sign with the same RSA key. No Armbian rebuild, no build tree
needed. Typical use: change the device-tree overlay set of a secure-boot
image ([why overlays need this](06-secure-boot.md#5-device-tree-overlays-on-secure-boot-images)).

```bash
./scripts/repack-fit.sh \
  --source-boot-itb boot.itb \
  --dtbo-list 'overlays/uart7-m2.dtbo' \
  --linux-source <linux-source-tree> \
  --u-boot-dir <u-boot-workdir-with-keys> \
  --keys-source-dir <fit-keys-dir> \
  --boot-soc rk3576 \
  --output boot-new.itb
# then dd boot-new.itb to the raw boot partition (carefully — verify the target!)
```

Required: the seven options above. Useful optional flags: `--bootargs`
(defaults to the source FIT's), `--rkbin-dir` (prebuilt mkimage location,
auto-detected from the Armbian cache), `--docker-image` (sign inside a
specific image), `--cache-dir`/`--no-cache`, `--keep-workdir`.

Safety rails: it refuses to re-sign the build-time staging artifact in
place; it prefers the Rockchip prebuilt `mkimage` for signing (the
[PSS salt pitfall](06-secure-boot.md#4-the-mkimage-pss-salt-pitfall)) and
warns before falling back to a tree mkimage; the result is verified with
`fit_check_sign` when available.

## 2. ssh-protect — SSH power-loss recovery

Included in **every** image (enabled unconditionally in
[`seeed_armbian_extension.sh`](../seeed_armbian_extension.sh)). Power loss
during first boot can zero-fill or truncate `/etc/ssh` files (ext4 delayed
allocation); sshd then refuses to start and the board is unreachable.

The fix ([`ssh-protect/rootfs`](../ssh-protect/ssh-protect.sh)): a systemd
drop-in runs
[`/usr/lib/armbian/ssh-protect`](../ssh-protect/rootfs/usr/lib/armbian/ssh-protect)
as `ExecStartPre` of `ssh.service`. It repairs, before sshd starts:

- broken host keys — missing/empty/unparseable keys are removed and
  regenerated (`ssh-keygen -A`);
- a broken `sshd_config` — restored from the distro default with the Armbian
  essentials re-applied, written atomically (temp file + rename + sync) so a
  power loss during the repair itself cannot corrupt it again.

Healthy systems: complete no-op. Nothing to configure.

## 3. Deb packaging and release chain

Three scripts, normally driven by CI ([below](#4-ci-builds-seeed-build-workflow)):

| Script | Purpose |
|---|---|
| [`build-all-debs.sh`](../scripts/build-all-debs.sh) | Build the five board debs (FCS960K AI camera, Morse WiFi tools, USB gadget) into an output dir |
| [`generate-deb-index.sh`](../scripts/generate-deb-index.sh) | Generate the repository index HTML (categories, apt usage snippets, stats) |
| [`publish-aptly.sh`](../scripts/publish-aptly.sh) | Publish debs into an aptly repo (`stable`/`main`/arm64), export the GPG key — requires `ARMBIAN_APT_GPG_KEY_ID` |

Local use example:

```bash
./scripts/build-all-debs.sh out/debs
```

## 4. CI builds (Seeed Build workflow)

[`.github/workflows/seeed-build.yml`](../.github/workflows/seeed-build.yml)
builds firmware on GitHub Actions — useful when you want images without a
local build environment.

**Trigger**: Actions → *Seeed Build* → *Run workflow*. Select via checkboxes:

- boards (rk3576 / rk3588 devkits), releases (trixie / resolute), tier (cli / mid)
- OTA mode (recovery / ab), security (plain / **secure-boot** — requires the
  `DEV_CRT` + `PRIVATE_KEY_PEM` repository secrets for signing)
- desktop environment, full/minimal mode, extension ref (default `main`)

Optional: `publish_release` creates a GitHub Release with download tables;
OneDrive upload is available via the `upload_onedrive` input and
`RCLONE_CONFIG` secret. Artifacts are attached to the workflow run
(`actions/upload-artifact`) — download from the run page, flash as usual.

Everything CI does is the documented local flow — the wrapper staging step,
profiles, and secrets map 1:1 to [02-build-reference.md](02-build-reference.md).
