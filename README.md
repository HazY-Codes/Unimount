## UniMount
(`v2.4.2`) is a Knox `0x0`-safe, soft-reboot friendly KernelSU metamodule based on NanoMount, built specifically for use with UniRoot (and compatible temporary/systemless root setups). Inspired in name by Kuuky, it manages systemless partition overlays, SELinux security context mirroring, and Zygisk-only module handling without touching physical partitions.

---

## Features

- **Built for UniRoot & Soft Reboots:** Engineered specifically for Lateload environments, retaining clean, reliable bind-mount behavior across soft reboots without requiring full hardware reboots or risking Knox `0x0` warranty status.
- **NanoMount Architecture:** Forked from upstream NanoMount's lightweight overlay philosophy and refined with added features, WebUI, and modular design.
- **Multi-Partition Overlay Support:** Automatically detects and mounts module overlays across `system`, `vendor`, `product`, `system_ext`, `odm`, `prism`, and `optics`.
- **SELinux Context Mirroring:** Reads the original security context (`ls -Z`) of target files and mirrors them onto overlaid source files (`chcon`) prior to bind-mounting (`mount -o bind`).
- **Flexible Mount Modes:**
  - **Auto Mode:** Automatically mounts all enabled modules containing valid partition directories.
  - **Manual Mode:** Restricts mounting strictly to module IDs whitelisted in `/data/adb/unimount/modules.txt`.
- **Zygisk / Service-Only Detection:** Identifies and skips partition overlay passes for Zygisk or background service modules that lack partition directories.
- **Integrated WebUI:** Includes a built-in dark-mode WebUI accessible directly from KernelSU Manager to manage configuration flags, module whitelists, mount logs, and dynamic `/data/adb` directory hygiene (`webroot/known_dirs.json` + optional `/data/adb/unimount/known_dirs.json` overrides).

---

## Directory Structure

```text
/data/adb/
├── metamodule -> /data/adb/modules/unimount  # Active metamodule symlink
├── modules/unimount/
│   ├── customize.sh                          # Installer & environment setup
│   ├── metamount.sh                          # Core overlay & SELinux mount engine
│   ├── post-fs-data.sh                       # Early boot directory & config initialization
│   ├── service.sh                            # Late boot service execution
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
    ├── mount.log                             # Detailed execution and mount telemetry log
    └── mirror/                               # Mirror workspace directory
```

## Installation
- Download the UniMount module ZIP archive.
- Open KernelSU Manager (within your UniRoot environment).
- Navigate to **Modules -> Install from storage** and select the ZIP file.
- Perform a soft reboot (or full reboot). During installation, UniMount automatically links `/data/adb/metamodule` to `/data/adb/modules/unimount` if no active metamodule exists.

## Configuration
Runtime settings are stored in `/data/adb/unimount/config.conf` and can be edited via the WebUI or a root shell:

| Variable | Default | Description |
|---|---|---|
| `MOUNT_MODE` | `auto` | Set to `auto` to mount all eligible modules, or `manual` to mount only modules listed in `modules.txt`. |
| `SELINUX_MIRROR` | `1` | Set to `1` to clone target file SELinux contexts onto source files before bind-mounting. |
| `SKIP_ZYGISK_ONLY` | `1` | Set to `1` to bypass overlay processing for modules without partition folders. |
| `LOG_VERBOSE` | `1` | Enables detailed mount and skip logging to `/data/adb/unimount/mount.log`. |

## Skipping Individual Modules
To prevent UniMount from mounting a specific module in auto mode without disabling the module itself, place an empty file named `skip_unimount` (or `skip_mount`) inside `/data/adb/modules/<module_id>/`.

## Usage & WebUI
- **WebUI Management:** Open **KernelSU Manager -> Modules -> UniMount** to launch the WebUI dashboard for toggling mount modes, editing `modules.txt`, inspecting `/data/adb` hygiene, and viewing live mount logs.
- **Custom Directory Catalog Overrides:** Add custom `/data/adb/<dir>` metadata entries in `/data/adb/unimount/known_dirs.json` to override or extend the bundled `webroot/known_dirs.json` without editing `app.js`.
- **Logs:** Inspect `/data/adb/unimount/mount.log` to verify bind-mount targets, applied SELinux contexts, and skipped modules.

## Credits & Acknowledgments
- **NanoMount:** Core architectural foundation and lightweight systemless mounting approach.
- **Kuuky:** Creator of UniRoot and inspiration behind the UniMount name.
- **UniRoot:** Primary target environment for temporary, Knox `0x0`-safe, soft-reboot root workflows.

## Uninstallation
Remove UniMount from KernelSU Manager and soft-reboot. The `uninstall.sh` script automatically cleans up `/data/adb/metamodule` if it points to UniMount.
