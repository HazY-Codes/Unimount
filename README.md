## UniMount
(`v2.4.3`) is a Knox `0x0`-safe, soft-reboot friendly KernelSU metamodule based on NanoMount, built specifically for use with UniRoot (and compatible temporary/systemless root setups). Inspired in name by Kuuky, it manages systemless partition overlays, SELinux security context mirroring, bootloop/conflict safeguards, and Zygisk-only module handling without touching physical partitions.

---

## Features

- **Built for UniRoot & Soft Reboots:** Engineered specifically for Lateload environments, retaining clean, reliable bind-mount behavior across soft reboots without requiring full hardware reboots or risking Knox `0x0` warranty status.
- **Metamodule Conflict & Bootloop Safeguards:**
  - **Single-Metamodule Guard:** Aborts installation cleanly if another active `metamodule=1` package owns `/data/adb/metamodule` or exists in `/data/adb/modules` / `modules_update`, and warns on competing standalone mount engines.
  - **Safe Mode & Bootloop Circuit Breaker (`BOOTLOOP_GUARD=1`):** Skips all overlays automatically in Android/KSU Safe Mode or after two consecutive incomplete early boots, and resets automatically via `boot-completed.sh` or the WebUI.
  - **Critical Path Protection (`PROTECT_CRITICAL_PATHS=1`):** Blocks bind-mounts over panic-critical binaries and SELinux policy files (`/system/bin/init`, `/system/bin/linker*`, `/system/bin/vold`, `*servicemanager`, `/system/etc/selinux/*`, `/vendor/etc/selinux/*`).
  - **SELinux Fail-Closed + Permission Mirroring:** Mirrors POSIX mode/UID/GID and SELinux contexts (`chcon`) from targets before binding, refuses to mount unmirrored files while SELinux is `Enforcing`, applies best-effort read-only bind remounting (`remount,ro,bind`), prevents duplicate/symlink stacking, and lazily unmounts stale binds from disabled or skipped modules across soft reboots.
- **Multi-Partition Overlay Support:** Automatically detects and mounts module overlays across `system`, `vendor`, `product`, `system_ext`, `odm`, `prism`, and `optics`.
- **Flexible Mount Modes:**
  - **Auto Mode:** Automatically mounts all enabled modules containing valid partition directories.
  - **Manual Mode:** Restricts mounting strictly to module IDs whitelisted in `/data/adb/unimount/modules.txt`.
- **Integrated WebUI:** Includes a built-in dark-mode WebUI accessible directly from KernelSU Manager to manage configuration flags, bootloop guard resets, module whitelists, mount logs, and dynamic `/data/adb` directory hygiene (`webroot/known_dirs.json` + optional `/data/adb/unimount/known_dirs.json` overrides).

---

## Directory Structure

```text
/data/adb/
├── metamodule -> /data/adb/modules/unimount  # Active metamodule symlink
├── modules/unimount/
│   ├── customize.sh                          # Conflict-guarded installer & residue cleanup
│   ├── metamount.sh                          # Hardened overlay, SELinux & stale-mount engine
│   ├── post-fs-data.sh                       # Early boot lock cleanup & config initialization
│   ├── service.sh                            # Boot-ID tracked late boot service fallback
│   ├── boot-completed.sh                     # Resets bootloop guard counter on clean boot
│   ├── action.sh                             # KernelSU Manager action trigger
│   ├── uninstall.sh                          # Clean metamodule symlink removal
│   └── webroot/
│       ├── index.html                        # WebUI layout
│       ├── styles.css                        # Dark Material slate theme
│       ├── app.js                            # Dynamic module & /data/adb resolver
│       └── known_dirs.json                   # External ecosystem directory catalog
└── unimount/
    ├── config.conf                           # Runtime configuration variables
    ├── modules.txt                           # Whitelist of module IDs (used in manual mode)
    ├── known_dirs.json                       # Optional user directory catalog overrides
    ├── active_mounts.list                    # Current-boot bind-mount ledger for soft-reboot cleanup
    ├── mount.log                             # Detailed execution and mount telemetry log
    └── mirror/                               # Mirror workspace directory
```

## Installation
- Uninstall any other active KernelSU metamodule first (UniMount's installer aborts automatically if another active `metamodule=1` package is detected).
- Download the UniMount module ZIP archive.
- Open KernelSU Manager (within your UniRoot environment).
- Navigate to **Modules -> Install from storage** and select the ZIP file.
- Perform a soft reboot (or full reboot). During installation, UniMount links `/data/adb/metamodule` to `/data/adb/modules/unimount` if no active metamodule exists.

## Configuration
Runtime settings are stored in `/data/adb/unimount/config.conf` and can be edited via the WebUI or a root shell:

| Variable | Default | Description |
|---|---|---|
| `MOUNT_MODE` | `auto` | Set to `auto` to mount all eligible modules, or `manual` to mount only modules listed in `modules.txt`. |
| `SELINUX_MIRROR` | `1` | Set to `1` to clone target SELinux contexts (`chcon`, fail-closed under Enforcing) and POSIX permissions before bind-mounting. |
| `SKIP_ZYGISK_ONLY` | `1` | Set to `1` to bypass overlay processing for modules without partition folders. |
| `LOG_VERBOSE` | `1` | Enables detailed mount, skip, and unmount logging to `/data/adb/unimount/mount.log`. |
| `BOOTLOOP_GUARD` | `1` | Automatically bypasses all overlays after 2 consecutive incomplete early boots; resets via `boot-completed.sh` or WebUI. |
| `PROTECT_CRITICAL_PATHS` | `1` | Blocks bind-mounts over panic-critical binaries (`init`, `linker*`, `vold`, `*servicemanager`) and SELinux policy directories. |

## Skipping Individual Modules
To prevent UniMount from mounting a specific module in auto mode without disabling the module itself, place an empty file named `skip_unimount` (or `skip_mount`) inside `/data/adb/modules/<module_id>/`.

## Usage & WebUI
- **WebUI Management:** Open **KernelSU Manager -> Modules -> UniMount** to launch the WebUI dashboard for toggling mount modes, bootloop guard settings, editing `modules.txt`, inspecting `/data/adb` hygiene, and viewing live mount logs.
- **Custom Directory Catalog Overrides:** Add custom `/data/adb/<dir>` metadata entries in `/data/adb/unimount/known_dirs.json` to override or extend the bundled `webroot/known_dirs.json` without editing `app.js`.
- **Logs:** Inspect `/data/adb/unimount/mount.log` to verify bind-mount targets, applied SELinux contexts, blocked paths, and unmounted stale binds.

## Credits & Acknowledgments
- **NanoMount:** Core architectural foundation and lightweight systemless mounting approach.
- **Kuuky:** Creator of UniRoot and inspiration behind the UniMount name.
- **UniRoot:** Primary target environment for temporary, Knox `0x0`-safe, soft-reboot root workflows.

## Uninstallation
Remove UniMount from KernelSU Manager and soft-reboot. The `uninstall.sh` script automatically cleans up `/data/adb/metamodule` if it points to UniMount.
