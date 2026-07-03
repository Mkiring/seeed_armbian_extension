# Armbian OTA Support

This extension provides two different OTA (Over-The-Air) update mechanisms for Armbian:

1. **Recovery OTA** - Single partition recovery mode (existing implementation)
2. **AB Partition OTA** - Dual partition A/B update mode with automatic rollback

Note: When `OTA_ENABLE=yes`, OTA runtime is installed into the firmware by mode:
- `AB_PART_OTA=yes`: install AB OTA runtime/tools.
- without `AB_PART_OTA`: install Recovery OTA runtime/tools.
Payload still includes `ota_tools/` as a fallback/offline bundle.

## Directory Structure

```
extensions/armbian-ota/
├── ota-support.sh                          # Main entry point
│
├── recovery/                           # Recovery OTA mode
│   ├── runtime/
│   │   └── backend.sh                      # Recovery OTA backend
│   ├── initramfs_hooks/
│   │   ├── 99-copy-tools                   # Initramfs hook for recovery OTA
│   │   └── 99-ota-apply                    # Recovery OTA apply script
│
├── runtime/                                # Unified OTA runtime
│   ├── bin/
│   │   └── armbian-ota                     # Unified CLI entrypoint
│   ├── lib/
│   │   ├── common.sh                       # Shared runtime helpers
│   │   ├── persist.sh                      # Shared userdata persistence helper
│   │   └── preserve.sh                     # Shared local config preserve helper
│   └── policy/
│       └── back-list.txt                   # Default local config preserve list
│
├── ab/                                 # AB Partition OTA mode
│   ├── runtime/
│   │   └── backend.sh                      # AB OTA backend
│   ├── lib/
│   │   ├── armbian-ota-health-check        # First boot health check
│   │   ├── armbian-ota-init-uboot          # U-Boot environment initializer
│   │   └── armbian-resize-userdata         # Resize shared userdata partition
│   ├── systemd/
│   │   ├── armbian-ota-firstboot.service   # Health check service
│   │   ├── armbian-ota-mark-success.service # Mark success service
│   │   ├── armbian-ota-rollback.service    # Rollback service
│   │   └── armbian-resize-userdata.service # Resize shared userdata partition
```

## Recovery OTA Mode

### Configuration

Set these environment variables to enable Recovery OTA:

```bash
OTA_ENABLE=yes
# Do not set AB_PART_OTA
```

### How It Works

1. OTA package is extracted to `/ota_work/`
2. Initramfs hooks are installed and `update-initramfs` is executed
3. On reboot, initramfs applies OTA payload to current rootfs
4. System reboots into updated firmware

### Usage

```bash
# On target system
armbian-ota start --mode=recovery <path-to-ota-package.tar.gz>
reboot
```

## AB Partition OTA Mode

### Configuration

Set this environment variable to enable AB Partition OTA:

```bash
OTA_ENABLE=yes
AB_PART_OTA=yes
```

**Important**: AB OTA and Recovery OTA are mutually exclusive. You cannot enable both at the same time.

### Partition Layout

| Partition | Label | Purpose |
|-----------|-------|---------|
| nvme0n1p1 | armbi_boota | Boot slot A |
| nvme0n1p2 | armbi_bootb | Boot slot B |
| nvme0n1p3 | armbi_roota | Root slot A |
| nvme0n1p4 | armbi_rootb | Root slot B |
| nvme0n1p5 | armbi_usrdata | User data (shared) |

### Persistent Data

OTA images configure `armbi_usrdata` as `/userdata` and keep cross-slot data
under `/userdata/.persist`. The default persistent bind mounts are:

| Source | Target |
|--------|--------|
| `/userdata/.persist/etc/passwd` | `/etc/passwd` |
| `/userdata/.persist/etc/shadow` | `/etc/shadow` |
| `/userdata/.persist/etc/group` | `/etc/group` |
| `/userdata/.persist/etc/gshadow` | `/etc/gshadow` |
| `/userdata/.persist/etc/subuid` | `/etc/subuid` |
| `/userdata/.persist/etc/subgid` | `/etc/subgid` |
| `/userdata/.persist/home` | `/home` |

Both AB OTA and Recovery OTA use the shared `persist.sh` helper to initialize
these files from the currently active rootfs before switching or cleaning the
target rootfs, if the userdata partition exists and `.persist` has not been
populated yet.

Local device configuration is preserved with `/etc/armbian-ota/back-list.txt`;
the default source file is `runtime/policy/back-list.txt`. Recovery OTA backs up those
paths before cleaning the current rootfs and restores them after extraction. AB
OTA applies the same list by copying those paths from the currently running
slot into the newly staged target slot before boot switching.

### U-Boot Environment Variables

| Variable | Purpose |
|----------|---------|
| `boot_slot` | Current active slot (a or b) |
| `boot_success` | Last successfully booted slot |
| `ota_in_progress` | OTA in progress flag (0 or 1) |

### How It Works

1. User initiates OTA with `armbian-ota start --mode=ab <package>`
2. OTA payload is copied to target (inactive) slot partitions
3. `ota_in_progress=1` and `boot_slot` are set to target slot
4. System reboots
5. System boots from target slot
7. Health checks run on first boot
8. If checks pass: OTA marked successful, `ota_in_progress=0`
9. If checks fail: Automatic rollback to previous slot

### Usage

```bash
# Check status
armbian-ota status

# Start OTA update
armbian-ota start --mode=ab Armbian_xxx-OTA.tar.gz

# System will reboot and apply update automatically

# Manual rollback (if needed)
armbian-ota rollback

# Mark as successful (if automatic marking failed)
armbian-ota mark-success
```

## Build Configuration

Add to your board configuration or build command:

```bash
# For AB Partition OTA
OTA_ENABLE=yes
AB_PART_OTA=yes
AB_BOOT_SIZE=256        # Boot partition size in MiB
AB_ROOTFS_SIZE=4608     # Rootfs partition size in MiB
USERDATA=256            # Userdata partition size in MiB

# For Recovery OTA
OTA_ENABLE=yes
# leave AB_PART_OTA unset
```

## OTA Package Contents

The OTA package (`*-OTA.tar.gz`) contains:

- `rootfs.tar.gz` - Root filesystem image (required)
- `rootfs.sha256` - Root filesystem checksum (required)
- `boot.tar.gz` - Boot partition image (optional)
- `boot.sha256` - Boot partition checksum (optional)
- `ota_manifest.env` - OTA mode and package metadata
- `boot.itb` - FIT boot image (for secure boot)

## Troubleshooting

### Check OTA Status

```bash
armbian-ota status
```

### View Logs

```bash
# OTA manager logs
cat /var/log/armbian-ota/ota.log

# Health check logs
cat /var/log/armbian-ota/health-check.log

# Initramfs logs
cat /run/initramfs/ab-ota.log
```

### Manual Rollback

```bash
armbian-ota rollback
```

### Check U-Boot Environment

```bash
fw_printenv
fw_printenv -n boot_slot
fw_printenv -n ota_in_progress
```

### Set U-Boot Environment Manually

```bash
fw_setenv boot_slot a
fw_setenv boot_success a
fw_setenv ota_in_progress 0
```

## Development

### Adding New Features

1. For Recovery OTA: Modify files in `recovery/`
2. For AB OTA: Modify files in `ab/`
3. For shared functionality: Use `runtime/`

### Build Hook Entry Points

In `ota-support.sh`:
- Runtime/assets installation: `pre_umount_final_image__89x_*`
- OTA package creation: `pre_umount_final_image__901_*`
- U-Boot env tool build: `pre_package_uboot_image__*`

## License

This extension is part of the Armbian project and follows the same license.
