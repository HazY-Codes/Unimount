# UniMount - KernelSU Metamodule

<div align="center">

<img src="./assets/banner.svg" alt="UniMount - KernelSU Metamodule" width="600" />

<br/>

![Compatible with](https://img.shields.io/badge/Compatible%20with-KernelSU%20%7C%20KernelSU--Next%20%7C%20UniRoot%20%7C%20APatch-0369A1?style=flat&labelColor=1E222A)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-818CF8?style=flat&labelColor=1E222A)](./LICENSE)

[![Latest Release](https://img.shields.io/github/v/release/HazY-Codes/Unimount?label=Latest%20Release&logo=git&logoColor=white&color=15803D&labelColor=1E222A&style=flat)](https://github.com/HazY-Codes/Unimount/releases/latest)
[![Total Commits](https://img.shields.io/github/commit-activity/t/HazY-Codes/Unimount?label=Total%20Commits&logo=git&logoColor=white&color=15803D&labelColor=1E222A&style=flat)](https://github.com/HazY-Codes/Unimount/commits)

[![Last Commit](https://img.shields.io/github/last-commit/HazY-Codes/Unimount?label=Last%20Commit&logo=git&logoColor=white&color=15803D&labelColor=1E222A&style=flat)](https://github.com/HazY-Codes/Unimount/commits)
[![Total Downloads](https://img.shields.io/github/downloads/HazY-Codes/Unimount/total?label=Total%20Downloads&logo=github&logoColor=white&color=15803D&labelColor=1E222A&style=flat)](https://github.com/HazY-Codes/Unimount/releases)

<br/>

<img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=15&duration=3200&pause=1000&color=38BDF8&center=true&vCenter=true&width=520&height=30&lines=Knox+0x0+Safe+Systemless+Overlay+Engine;Soft-Reboot+Friendly+KernelSU+Metamodule;SELinux-Mirrored+%26+Bootloop+Guarded" alt="UniMount Tagline" />

</div>

---

## 📖 About

**UniMount** (`v2.5.0`) is a Knox `0x0`-safe, soft-reboot friendly KernelSU metamodule based on **NanoMount**, built specifically for use with **UniRoot** (and compatible ephemeral/temporary or systemless root setups such as **DFRoot** and **GhostLock**). Inspired in name by **Kuuky**, it manages systemless partition overlays, minimal-ancestor directory mirror injection for new files and folders, RAM-synced active mount tracking, one-tap emergency detach, SELinux security context mirroring, bootloop/conflict safeguards, and Zygisk-only module handling without touching physical partitions or requiring kernel `OverlayFS` / `tmpfs`.

---

## ✨ Features

- **Built for UniRoot, Ephemeral Root & Soft Reboots:** Engineered specifically for late-load and ephemeral environments (`UniRoot`, `DFRoot`, `GhostLock`), retaining clean, reliable bind-mount behavior across soft reboots without requiring full hardware reboots or risking Knox `0x0` warranty status.
- **Two-Pass Mount Engine & Minimal-Ancestor `MIRROR_ROOT` Injection (`DIR_MIRROR_INJECT=1`):**
  - **Pass 1 — Minimal-Ancestor Directory Mirror Composition:** Automatically detects new files, new directories, and symlink replacements across eligible modules, resolves the deepest existing real directory ancestor (`_anc`), and stages a composite mirror under `/data/adb/unimount/mirror/merged`. Untouched sibling subdirectories inside `_anc` are zero-copy bind-mounted (`ro,bind`) onto stub directories, while modified subtrees merge files from all eligible modules with cloned or ancestor-inherited SELinux contexts and POSIX permissions.
  - **Pass 2 — Direct Existing-File Bind Mounts:** Directly bind-mounts remaining existing-file overrides not already covered by a Pass 1 directory mirror.
  - **SAR Cross-Partition Symlink Routing:** Automatically routes `$MOD/system/{vendor,product,system_ext,odm}` subtrees to their real partition roots (`/{vendor,product,system_ext,odm}`) when `/system/<subpart>` is a SAR symlink, preventing cross-partition symlink shadowing.
- **Active Mount Ledger & Emergency Unmount All (`metamount.sh --unmount-all`):**
  - Synchronizes every active `DIR_MIRROR` and `FILE_BIND` entry between the RAM-backed runtime ledger (`/dev/unimount_active_mounts`, auto-cleared on cold reboot) and `/data/adb/unimount/active_mounts.list`.
  - Provides instant, lock-guarded emergency teardown via `sh /data/adb/modules/unimount/metamount.sh --unmount-all` or directly inside the WebUI confirmation modal—detaching all UniMount-tracked binds and directory mirrors cleanly without rebooting or disturbing non-UniMount daemons.
- **Metamodule Conflict & Bootloop Safeguards:**
  - **Single-Metamodule Guard:** Aborts installation cleanly if another active `metamodule=1` package owns `/data/adb/metamodule` or exists in `/data/adb/modules` / `modules_update`, and warns on competing standalone mount engines.
  - **Ephemeral-Root Aware Safe Mode & Bootloop Circuit Breaker (`BOOTLOOP_GUARD=1`):** Skips all overlays automatically in Android/KSU Safe Mode or after two consecutive incomplete boots/mount runs. Supports both early-boot root (`boot-completed.sh`) and late-load ephemeral root (`UniRoot`, `DFRoot`, `GhostLock`) where `metamount.sh` runs after `sys.boot_completed=1`, verifying post-mount `system_server` health after 25 seconds before clearing the fail counter.
  - **Critical Path & Sub-Mount Protection (`PROTECT_CRITICAL_PATHS=1`):** Blocks bind-mounts and directory mirrors over panic-critical binaries (`/system/bin/init`, `/system/bin/linker*`, `/system/bin/vold`, `*servicemanager`), SELinux policy directories (`/{system,vendor,system/vendor,system_ext,product,odm}/etc/selinux/*`), partition roots, `/system/apex/*`, and any ancestor containing active non-UniMount child sub-mounts.
  - **SELinux Fail-Closed + Permission Mirroring:** Mirrors POSIX mode/UID/GID and SELinux contexts (`chcon` / `chcon -h`) from targets or nearest ancestors before binding, refuses to mount unmirrored files or directory mirrors while SELinux is `Enforcing`, applies best-effort read-only bind remounting (`remount,ro,bind`), and safely tears down inner mirror bind-mounts before refreshing `/data/adb/unimount/mirror/merged`.
- **Multi-Partition Overlay Support:** Automatically detects and mounts module overlays across `system`, `vendor`, `product`, `system_ext`, `odm`, `prism`, and `optics`.
- **Flexible Mount Modes:**
  - **Auto Mode:** Automatically mounts all enabled modules containing valid partition directories.
  - **Manual Mode:** Restricts mounting strictly to module IDs whitelisted in `/data/adb/unimount/modules.txt`.
- **Material 3 Expressive WebUI:** Built-in offline-first Material 3 Expressive Slate & Light Blue/Indigo WebUI (`#0F172A`, `#1E222A`, `#38BDF8`, `#818CF8`) with optical glass surfaces, responsive M3 navigation bar, live Active Mounts Ledger inspector, native `<dialog>` Emergency Unmount confirmation, full `config.conf` switch controls (`MOUNT_MODE`, `SELINUX_MIRROR`, `DIR_MIRROR_INJECT`, `SKIP_ZYGISK_ONLY`, `BOOTLOOP_GUARD`, `PROTECT_CRITICAL_PATHS`, `LOG_VERBOSE`), segmented log viewer, and dynamic `/data/adb` directory hygiene (`webroot/known_dirs.json` + optional `/data/adb/unimount/known_dirs.json` overrides).

---

## 📁 Directory Structure

```text
/dev/
└── unimount_active_mounts                    # Live RAM-backed FILE_BIND & DIR_MIRROR mount ledger

/data/adb/
├── metamodule -> /data/adb/modules/unimount  # Active metamodule symlink
├── modules/unimount/
│   ├── LICENSE                               # GNU General Public License v3.0
│   ├── assets/banner.svg                     # README hero banner
│   ├── customize.sh                          # Conflict-guarded installer & residue cleanup
│   ├── metamount.sh                          # 2-pass minimal-ancestor mirror, bind & --unmount-all engine
│   ├── post-fs-data.sh                       # Early boot lock cleanup & config initialization
│   ├── service.sh                            # Boot-ID tracked late boot service fallback
│   ├── boot-completed.sh                     # Resets bootloop guard counter on clean boot
│   ├── action.sh                             # KernelSU Manager action trigger
│   ├── uninstall.sh                          # Clean metamodule symlink & runtime state removal
│   └── webroot/
│       ├── index.html                        # Material 3 Expressive WebUI layout
│       ├── styles.css                        # Material 3 Expressive Slate & Optical Glass tokens
│       ├── app.js                            # Dual-mode ksu.exec() bridge, live ledger & /data/adb resolver
│       └── known_dirs.json                   # External ecosystem directory catalog
└── unimount/
    ├── config.conf                           # Runtime configuration variables
    ├── modules.txt                           # Whitelist of module IDs (used in manual mode)
    ├── known_dirs.json                       # Optional user directory catalog overrides
    ├── active_mounts.list                    # Current-boot FILE_BIND & DIR_MIRROR mount ledger
    ├── mount.log                             # Detailed execution and mount telemetry log
    └── mirror/merged/                        # Minimal-ancestor composite directory mirror workspace
```

---

## 🚀 Installation

1. Uninstall any other active KernelSU metamodule first (UniMount's installer aborts automatically if another active `metamodule=1` package is detected).
2. Download the latest UniMount module ZIP archive from [Releases](https://github.com/HazY-Codes/Unimount/releases/latest).
3. Open **KernelSU Manager** (within your UniRoot environment).
4. Navigate to **Modules -> Install from storage** and select the ZIP file.
5. Perform a **soft reboot** (or full reboot). During installation, UniMount links `/data/adb/metamodule` to `/data/adb/modules/unimount` if no active metamodule exists.

---

## ⚙️ Configuration

Runtime settings are stored in `/data/adb/unimount/config.conf` and can be edited via the WebUI or a root shell:

| Variable | Default | Description |
|---|---|---|
| `MOUNT_MODE` | `auto` | Set to `auto` to mount all eligible modules, or `manual` to mount only modules listed in `modules.txt`. |
| `SELINUX_MIRROR` | `1` | Set to `1` to clone target SELinux contexts (`chcon`, fail-closed under Enforcing) and POSIX permissions before bind-mounting. |
| `DIR_MIRROR_INJECT` | `1` | Set to `1` to compose minimal-ancestor directory mirrors in `/data/adb/unimount/mirror/merged` for injecting new files, folders, and symlinks without OverlayFS/tmpfs. |
| `SKIP_ZYGISK_ONLY` | `1` | Set to `1` to bypass overlay processing for modules without partition folders. |
| `LOG_VERBOSE` | `1` | Enables detailed mount, mirror stage, skip, and unmount logging to `/data/adb/unimount/mount.log`. |
| `BOOTLOOP_GUARD` | `1` | Automatically bypasses all overlays after 2 consecutive incomplete boots/mount runs; resets via `boot-completed.sh`, 25s post-mount health verification, or WebUI. |
| `PROTECT_CRITICAL_PATHS` | `1` | Blocks bind-mounts and directory mirrors over panic-critical binaries (`init`, `linker*`, `vold`, `*servicemanager`) and SELinux policy directories. |

---

## 🛡️ Skipping Individual Modules & Emergency Detach

To prevent UniMount from mounting a specific module in auto mode without disabling the module itself, create an empty `skip_unimount` (or `skip_mount`) file inside `/data/adb/modules/<module_id>/`:

```shell
touch /data/adb/modules/<module_id>/skip_unimount
```

To immediately detach all active UniMount `DIR_MIRROR` trees and `FILE_BIND` overlays without rebooting:

```shell
sh /data/adb/modules/unimount/metamount.sh --unmount-all
```

---

## 🖥️ Usage & WebUI

- **WebUI Management:** Open **KernelSU Manager -> Modules -> UniMount** to launch the Material 3 Expressive WebUI dashboard for toggling all 7 `config.conf` flags, inspecting the live Active Mounts Ledger (`/dev/unimount_active_mounts`), triggering Emergency Unmount All, resetting the bootloop guard, editing `modules.txt`, inspecting `/data/adb` hygiene, and viewing/copying live mount logs.
- **Custom Directory Catalog Overrides:** Add custom `/data/adb/<dir>` metadata entries in `/data/adb/unimount/known_dirs.json` to override or extend the bundled `webroot/known_dirs.json` without editing `app.js`.
- **Logs:** Inspect `/data/adb/unimount/mount.log` to verify bind-mount targets, applied SELinux contexts, blocked paths, unmounted stale binds, and end-of-run `[SUMMARY]` telemetry.

---

## 🙏 Credits & Acknowledgments

- **NanoMount:** Core architectural foundation and lightweight systemless mounting approach.
- **Kuuky:** Creator of UniRoot and inspiration behind the UniMount name.
- **UniRoot:** Primary target environment for temporary, Knox `0x0`-safe, soft-reboot root workflows.

---

## 🗑️ Uninstallation

Remove UniMount from KernelSU Manager and soft-reboot. The `uninstall.sh` script automatically cleans up `/data/adb/metamodule` if it points to UniMount along with `/dev/unimount_active_mounts` and `/data/adb/unimount/.lock`.

---

## 📄 License

UniMount is free software licensed under the **GNU General Public License v3.0** (`GPL-3.0-or-later`). See [LICENSE](./LICENSE) for full license terms.
