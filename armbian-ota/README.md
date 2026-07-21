# Armbian OTA Support

This extension provides two different OTA (Over-The-Air) update mechanisms for Armbian:

1. **Recovery OTA** - Single partition recovery mode (existing implementation)
2. **AB Partition OTA** - Dual partition A/B update mode with automatic rollback

Note: When `OTA_ENABLE=yes`, OTA runtime is installed into the firmware by mode:
- `AB_PART_OTA=yes`: install AB OTA runtime/tools.
- without `AB_PART_OTA`: install Recovery OTA runtime/tools.

## Directory Structure

```
extensions/armbian-ota/
├── ota-support.sh                          # Main build hook entry point
├── common/                                 # Shared OTA functionality
│   ├── build-hooks/
│   │   ├── image-naming.sh                 # Image/package naming helpers
│   │   ├── package-create.sh               # OTA package creation hook
│   │   ├── partitions.sh                   # Common partition primitives
│   │   ├── rootfs-install.sh               # Rootfs rsync helper
│   │   └── userdata-resize.sh              # Shared userdata resize hook
│   └── rootfs/                             # Shared CLI, runtime and userdata resize service
│
├── recovery/                               # Recovery OTA mode
│   ├── build-hooks/
│   │   ├── overlayroot.sh                  # Recovery full-root overlayroot setup
│   │   ├── partitions.sh                   # Recovery rootfs + userdata layout
│   │   └── runtime-install.sh              # Recovery rootfs and initramfs setup
│   └── rootfs/
│       ├── etc/initramfs-tools/            # Initramfs hooks and scripts
│       └── usr/share/armbian-ota/recovery/ # Recovery backend
│
└── ab/                                     # A/B partition OTA mode
    ├── build-hooks/
    │   ├── partitions.sh                   # A/B partition hooks
    │   ├── overlayroot.sh                  # A/B overlayroot setup
    │   └── runtime-install.sh              # A/B rootfs and services setup
    └── rootfs/
        ├── etc/systemd/system/             # A/B systemd units
        └── usr/
            ├── lib/armbian/                # A/B runtime executables
            └── share/armbian-ota/ab/       # A/B backend and libraries
```

The build hooks install `common/rootfs` first, then install the selected mode
overlay with `rsync`.  Files under each `rootfs/` directory therefore mirror
their final paths in the image.

## Recovery OTA Mode

### Configuration

Set these environment variables to enable Recovery OTA:

```bash
OTA_ENABLE=yes
# Do not set AB_PART_OTA
```

### How It Works

1. OTA package is extracted to `userdata/ota-recovery/ota_work/`
2. Initramfs hooks are installed and `update-initramfs` is executed
3. On reboot, initramfs applies OTA payload to current rootfs
4. A separate userdata partition supplies persistent overlays for `/etc`,
   `/home`, and `/var/lib`
5. System reboots into updated firmware

### Usage

```bash
# On target system
armbian-ota start <path-to-ota-package.tar.gz>
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

User data survives OTA updates differently depending on the OTA mode.

User account database files (`/etc/passwd`, `/etc/shadow`, `/etc/group`,
`/etc/gshadow`, `/etc/subuid`, `/etc/subgid`) remain normal files in the
overlay filesystem. This is required because tools such as `useradd` and
`groupadd` update those files by writing a temporary file and renaming it over
the original.

Both OTA modes use overlayroot with the final `userdata` partition as the
writable upper layer. The rootfs is the read-only lower layer, so runtime
writes—including `/home` and `/var/lib`—persist on `armbi_usrdata` without
changing the OTA rootfs. Encrypted A/B and Recovery images use the
initramfs-unlocked `/dev/mapper/armbian-userdata` mapper as the overlayroot
backing device.

Recovery OTA stores its pending payload and state in `userdata/ota-recovery/`
rather than the overlay rootfs. The initramfs mounts this transaction store,
rewrites only the raw rootfs lower layer, and leaves userdata intact.

Neither OTA mode migrates data from older single-rootfs Recovery images;
this layout is intended for new development images.

On first boot, `armbian-resize-userdata.service` expands the final `userdata`
partition to use available disk space in both modes. For encrypted Recovery
images it then expands the existing `armbian-userdata` LUKS mapping and its
inner ext4 filesystem.

### U-Boot Environment Variables

| Variable | Purpose |
|----------|---------|
| `boot_slot` | Current active slot (a or b) |
| `boot_success` | Last successfully booted slot |
| `ota_in_progress` | OTA in progress flag (0 or 1) |

### How It Works

1. User initiates OTA with `armbian-ota start <package>`
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
armbian-ota start Armbian_xxx-OTA.tar.gz

# System will reboot and apply update automatically

# Manually switch to the other boot slot after OTA has completed
armbian-ota switch-slot
```

## Build Configuration

Add to your board configuration or build command:

```bash
# For AB Partition OTA
OTA_ENABLE=yes
AB_PART_OTA=yes
OTA_BOOT_SIZE=256       # Boot partition size in MiB
# OTA_ROOTFS_SIZE=4096  # Optional rootfs partition size override
OTA_USERDATA_SIZE=1024  # Userdata partition size in MiB
OTA_SECURITY_SIZE=4     # Security partition size in MiB (encrypted images)

# For Recovery OTA
OTA_ENABLE=yes
# leave AB_PART_OTA unset
OTA_BOOT_SIZE=256       # Used when a separate boot partition is required
# OTA_ROOTFS_SIZE=4096  # Optional rootfs partition size override
OTA_USERDATA_SIZE=1024  # Userdata partition size in MiB
OTA_SECURITY_SIZE=4     # Security partition size in MiB (encrypted images)
```

When unset, `OTA_ROOTFS_SIZE` is calculated from the built rootfs size plus
`EXTRA_ROOTFS_MIB_SIZE`, then adds 30% headroom. The same size-variable
policy applies to both A/B and Recovery OTA modes.

Both OTA modes require a GPT partition table. Their boot, rootfs, userdata,
and security partitions are located by GPT partition labels.
Both OTA layouts boot through U-Boot and do not include BIOS or UEFI
partitions.

## OTA Package Contents

The OTA package (`*-OTA.tar.gz`) contains:

- `rootfs.tar.gz` - Root filesystem image (required)
- `rootfs.sha256` - Root filesystem checksum (required)
- `boot.tar.gz` - Boot partition image (optional)
- `boot.sha256` - Boot partition checksum (optional)
- `package.env` - OTA mode and package metadata
- `boot.itb` - FIT boot image (for secure boot)
- `version.txt` - Image name, version, build commit, and extension commit

The package does not include an offline `ota_tools/` bundle; the required OTA
runtime is installed into the firmware at image build time.

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

### Automatic Rollback

Rollback is triggered by `armbian-ota-rollback.service` if first boot health checks fail during A/B OTA verification.
Use `armbian-ota switch-slot [a|b]` for manual slot maintenance after OTA has completed.

### A/B Boot State

Non-secure A/B images store boot state in the fixed raw U-Boot environment
offset (`0x3f8000`, size `0x8000`) on the selected boot disk.  This works the
same way for SD, eMMC, and NVMe images. The A/B backend uses an internal
helper to manage this `fw_setenv` state.

For Secure Boot A/B packages, the A/B backend verifies `boot.itb` and writes
it directly to the inactive raw `boot_a` or `boot_b` partition. It never
mounts a FIT boot partition or treats the FIT image as `boot.tar.gz`.
When automatic rootfs decryption is enabled, both A/B modes create a shared
`security` partition and format both rootfs slots as LUKS-backed ext4.
Slot-state transitions use the A/B backend's internal U-Boot environment
helper.

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

1. For Recovery OTA: Modify files in `recovery/rootfs/` or `recovery/build-hooks/`
2. For AB OTA: Modify files in `ab/rootfs/` or `ab/build-hooks/`
3. For shared functionality: Use `common/rootfs/` or `common/build-hooks/`

### Build Hook Entry Points

In `ota-support.sh` and `*/build-hooks/*.sh`:
- Recovery initramfs hook installation: `pre_update_initramfs__*`
- Runtime/assets installation: `pre_update_initramfs__89x_*`
- Resize userdata service enablement: `pre_umount_final_image__896_*`
- OTA package creation: `pre_umount_final_image__901_*`
- U-Boot env tool build: `pre_package_uboot_image__*`

## License

This extension is part of the Armbian project and follows the same license.
