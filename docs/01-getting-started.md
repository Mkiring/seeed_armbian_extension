# 1. Getting Started

Goal of this chapter: from a clean machine to a flashed, booting image.

> **Skip the build?** CI-built images are published at
> [Seeed-Studio/armbian-build releases](https://github.com/Seeed-Studio/armbian-build/releases).
> Each release carries a download table per board (rk3576 / rk3588 devkit):
> one row per distribution (Debian 13 / Ubuntu 26.04) × variant (Gnome /
> Minimal CLI) × type (**AB** / **RECOVERY**), with an **IMAGE** link
> (`.img.xz`, flash-ready GPT) and an **OTA** link (update payload for the
> paired image) per row. The matching `.sha256` sidecar sits next to each
> file on OneDrive — verify after downloading. The pre-release is recreated
> on every CI run, so always take the newest one. Flash it with
> [§5 Flash and boot](#5-flash-and-boot); read on only if you need to build
> your own image.

1. [Prerequisites](#1-prerequisites)
2. [Get the trees](#2-get-the-trees)
3. [Stage the build wrapper](#3-stage-the-build-wrapper)
4. [Your first build](#4-your-first-build)
5. [Flash and boot](#5-flash-and-boot)
6. [Next steps](#6-next-steps)

## 1. Prerequisites

- Linux build host (Ubuntu 22.04/24.04 work well), ~50 GB free disk.
- Docker installed and usable without sudo (the build runs in a container).
- Baseline knowledge: [Armbian build system](https://docs.armbian.com/Developer-Guide_Build-Preparation/).
- No serial cable required for normal use, but it is the best debugging tool
  when a board does not boot — recommended.

If your host has a global HTTP proxy, expect build failures in chroot/APT.
The examples below unset proxies and pass `APT_PROXY_ADDR=none`.

## 2. Get the trees

The extension is consumed by the Armbian build. Clone both:

```bash
mkdir -p ~/armbian && cd ~/armbian
git clone https://github.com/armbian/build.git          # Armbian build tree
cd build
mkdir -p userextensions
git clone https://github.com/Seeed-Studio/seeed_armbian_extension.git \
    userextensions/seeed_armbian_extension
```

> The extension is enabled with `ENABLE_EXTENSIONS=seeed_armbian_extension`
> (set automatically by the wrapper in the next step).

## 3. Stage the build wrapper

[`scripts/build.sh`](../scripts/build.sh) is the single entry point for all
profiles. It **must sit next to `compile.sh`** in the build tree root — it
refuses to run anywhere else:

```bash
cp userextensions/seeed_armbian_extension/scripts/build.sh .
./build.sh -h    # usage
```

Why staging: the wrapper drives `./compile.sh` in the same directory and
manages caches relative to the build tree. CI does exactly the same copy step.

## 4. Your first build

The simplest useful image — Recovery OTA, plain (unencrypted), rk3576 devkit:

```bash
./build.sh recovery -b recomputer-rk3576-devkit
```

What happens: the wrapper resolves the profile into environment variables
(`OTA_ENABLE=yes` …), runs `compile.sh` in Docker, and produces:

- image: `output/images/Armbian_*_RECOVERY_*.img.xz` (GPT, write-ready)
- logs: `output/logs/`

First run downloads toolchains/sources and can take an hour or more;
subsequent builds reuse the cache.

**Verification checkpoint** — the build log ends with the image path and no
`error` lines:

```bash
ls -lh output/images/
```

Variants you will use most (all combinations of profile + board):

```bash
./build.sh recovery -b recomputer-rk3588-devkit   # rk3588 variant
./build.sh ab -b recomputer-rk3576-devkit         # A/B instead of Recovery
./build.sh recovery --minimal -b recomputer-rk3576-devkit   # CLI, no desktop
```

Encrypted/signed builds need a passphrase — see
[05-encryption.md](05-encryption.md) before attempting them.

The full option/variable reference is [02-build-reference.md](02-build-reference.md).

## 5. Flash and boot

Flash the `.img`/`.img.xz` with your usual Rockchip tooling (rkdevtool from
Maskrom/RKDevTool, USB boot, or plain `dd` to the target disk). The image is a
complete GPT layout — no partition math required.

**On device, first boot:**

- The rootfs is overlayed (`overlayroot`); runtime writes persist on the
  `userdata` partition, which auto-expands to fill the disk on first boot.
- Log in with the Armbian default credentials of your release, then change them.

Verify the OTA runtime is present (**on device**):

```bash
armbian-ota status    # prints mode + status; "unknown" before any OTA is fine
```

## 6. Next steps

- Deliver updates: [03-ota-recovery.md](03-ota-recovery.md)
- Or switch to rollback-safe dual-slot firmware: [04-ota-ab.md](04-ota-ab.md)
- Need confidentiality or a signed bootchain? [05-encryption.md](05-encryption.md) / [06-secure-boot.md](06-secure-boot.md)
