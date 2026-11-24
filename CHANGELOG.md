# UniMount Changelog

Full release history, commit mapping, and artifact checksums for [HazY-Codes/Unimount](https://github.com/HazY-Codes/Unimount).

> **Most recent major release — [v2.5.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.5.0)**
> Two-pass minimal-ancestor directory mirror engine (`DIR_MIRROR_INJECT=1`), RAM-synced active mount ledger (`/dev/unimount_active_mounts`), lock-guarded `--unmount-all` detach, redesigned WebUI, and GNU GPL v3.0 license.

---

## Releases

| Release | `versionCode` | Date | Commit | Package | Highlight |
| :--- | :---: | :---: | :---: | :--- | :--- |
| `v2.5.1` *(staging on `main`)* | `251` | 2026-11-23 | `main` | Local build | Flat Cool Slate & Periwinkle WebUI (3-mode theme + Monet), `grep -c` count fix, safe `config.conf` parser, deduplicated mount helpers, disclaimers |
| [v2.5.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.5.0) *(latest, major)* | `250` | 2026-11-22 | [`630c741`](https://github.com/HazY-Codes/Unimount/commit/630c7419acad6b800eaa46c181d02e7b65b1b8cf) | [UniMount-v2.5.0-KSU-WebUI.zip](https://github.com/HazY-Codes/Unimount/releases/download/v2.5.0/UniMount-v2.5.0-KSU-WebUI.zip) | Two-pass directory mirror engine, RAM mount ledger, `--unmount-all`, WebUI overhaul, GPL-3.0 |
| [v2.4.4](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.4) | `244` | 2026-11-19 | [`f5cb122`](https://github.com/HazY-Codes/Unimount/commit/f5cb1220bb910c307b5d1c478e84f0ae666f2167) | [UniMount-v2.4.4-KSU-WebUI.zip](https://github.com/HazY-Codes/Unimount/releases/download/v2.4.4/UniMount-v2.4.4-KSU-WebUI.zip) | Added `assets/banner.svg`, live GitHub badges, and README restructuring |
| [v2.4.3](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.3) | `243` | 2026-11-19 | [`e13216b`](https://github.com/HazY-Codes/Unimount/commit/e13216b1920bcbda782ddb998b15b64928a75673) | [UniMount-v2.4.3-KSU-WebUI.zip](https://github.com/HazY-Codes/Unimount/releases/download/v2.4.3/UniMount-v2.4.3-KSU-WebUI.zip) | Single-metamodule conflict guard, Safe Mode & bootloop circuit breaker, fail-closed SELinux verification |
| [v2.4.2](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.2) | `242` | 2026-11-19 | [`e799c6f`](https://github.com/HazY-Codes/Unimount/commit/e799c6fe384073e3d139f53651d2589cf4a6cc92) | [UniMount-v2.4.2-KSU-WebUI.zip](https://github.com/HazY-Codes/Unimount/releases/download/v2.4.2/UniMount-v2.4.2-KSU-WebUI.zip) | Externalized `webroot/known_dirs.json` catalog, dynamic `/data/adb` resolver, expanded orphan cleanup |
| [v2.4.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.0) | `240` | 2026-11-16 | [`6962436`](https://github.com/HazY-Codes/Unimount/commit/6962436092b6a2f754a73bbc1cff6da301b936a9) | [UniMount-v2.4.0-KSU-WebUI.zip](https://github.com/HazY-Codes/Unimount/releases/download/v2.4.0/UniMount-v2.4.0-KSU-WebUI.zip) | Initial Knox `0x0`-safe KernelSU metamodule, SELinux context mirroring, and offline WebUI |

---

## Commit History

| Commit | Linked Release | Date | Diff | Summary |
| :--- | :--- | :---: | :---: | :--- |
| [`630c741`](https://github.com/HazY-Codes/Unimount/commit/630c7419acad6b800eaa46c181d02e7b65b1b8cf) | [v2.5.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.5.0) | 2026-11-22 | [`v2.4.4...v2.5.0`](https://github.com/HazY-Codes/Unimount/compare/v2.4.4...v2.5.0) | `[v2.5.0] feat(engine,webui): add 2-pass directory mirror engine, RAM mount ledger, M3 Expressive WebUI, and GPL-3.0 license` |
| [`f5cb122`](https://github.com/HazY-Codes/Unimount/commit/f5cb1220bb910c307b5d1c478e84f0ae666f2167) | [v2.4.4](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.4) | 2026-11-19 | [`v2.4.3...v2.4.4`](https://github.com/HazY-Codes/Unimount/compare/v2.4.3...v2.4.4) | `[v2.4.4] docs(readme): add hero SVG banner, live GitHub badges, and typing tagline header` |
| [`e13216b`](https://github.com/HazY-Codes/Unimount/commit/e13216b1920bcbda782ddb998b15b64928a75673) | [v2.4.3](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.3) | 2026-11-19 | [`v2.4.2...v2.4.3`](https://github.com/HazY-Codes/Unimount/compare/v2.4.2...v2.4.3) | `[v2.4.3] feat(safety): add metamodule conflict, bootloop, and SELinux mount safeguards` |
| [`e799c6f`](https://github.com/HazY-Codes/Unimount/commit/e799c6fe384073e3d139f53651d2589cf4a6cc92) | [v2.4.2](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.2) | 2026-11-19 | [`v2.4.0...v2.4.2`](https://github.com/HazY-Codes/Unimount/compare/v2.4.0...v2.4.2) | `[v2.4.2] refactor(webui): generalize KNOWN_ADB_DIRS and fix orphan cleanup` |
| [`6962436`](https://github.com/HazY-Codes/Unimount/commit/6962436092b6a2f754a73bbc1cff6da301b936a9) | [v2.4.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.0) | 2026-11-16 | — | `Initial commit` |

---

## Detailed Release Notes

### v2.5.1 *(Staging on `main`)*

- **Shell Engine Refactor & Hardening (`metamount.sh`, `customize.sh`, `post-fs-data.sh`, `service.sh`, `boot-completed.sh`, `action.sh`, `uninstall.sh`):**
  - Added a `busybox awk` fallback shim (for KSU/APatch/Magisk) and pure POSIX `get_selinux_ctx` so scripts never fail when `/system/bin/awk` is absent.
  - Hardened `.lock` acquisition with atomic `mv` stale-lock reclamation, positive numeric PID validation, and PID-verified `EXIT`/`INT`/`TERM` trap cleanup that exits properly on signals.
  - Added active foreign-metamodule and `disable`/`remove` stand-down checks before creating runtime directories across `metamount.sh`, `post-fs-data.sh`, `service.sh`, `boot-completed.sh`, and `action.sh`.
  - Fixed a POSIX `grep -c ... || echo 0` bug that emitted a double zero (`0\n0`) when active mirror or bind counts were zero.
  - Replaced `. "$CONF_DIR/config.conf"` sourcing with an EOF-safe `KEY=VALUE` parser (`load_config`) restricted to the 7 supported config keys.
  - Consolidated duplicated `/proc/self/mountinfo` / `/proc/mounts` queries and unmount loops into shared `read_mount_table`, `umount_one`, and `umount_under_prefix` helpers, and verified `system_server` PID stability in the detached 25s late-load health check.
- **WebUI Redesign (`webroot/`):**
  - Replaced blur/glass styling with a flat Cool Slate & Periwinkle utility interface featuring a status hero card, 2-column stat tiles, collapsible environment details (Android version, ABI list, Seccomp status), hairline-outlined behaviour cards with Material 3 switches, and a bottom navigation bar.
  - Added 3-mode theming (`System`, `Light`, `Dark`) with acyclic KernelSU Monet dynamic color binding (`localStorage` persisted) and top-bar theme cycling.
  - Hardened `webroot/app.js`: added `busybox awk` fallback, `/proc/self/mountinfo` + full Safe Mode checks, newline padding after every `cat` in `SCAN_SCRIPT`, `errno` verification before success toasts, disabled root controls when offline, `grep --` option guards, and `ksuExec` timer cleanup.
- **Documentation:**
  - Added `CHANGELOG.md` with Shizuku+-style release and commit tables, cleaned up `README.md`, and added explicit Responsibility and AI Assistance disclaimers.

---

### [v2.5.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.5.0) — 2026-11-22

- **Two-Pass Hybrid Mount Engine (`metamount.sh`):**
  - Pass 1 (`DIR_MIRROR_INJECT=1`) composes minimal-ancestor directory mirrors in `/data/adb/unimount/mirror/merged`, bind-mounting untouched sibling subdirectories read-only and merging module additions with mirrored SELinux contexts and POSIX permissions.
  - Pass 2 (`FILE_BIND`) bind-mounts remaining existing-file overrides.
  - Added SAR cross-partition symlink routing (`/system/{vendor,product,system_ext,odm}` -> real partition roots) and a detached 25s post-mount `system_server` health check for late-load ephemeral root.
- **RAM-Synced Mount Ledger & Emergency Detach:**
  - Synced active `DIR_MIRROR` and `FILE_BIND` entries between `/dev/unimount_active_mounts` and `/data/adb/unimount/active_mounts.list`.
  - Added lock-guarded `metamount.sh --unmount-all`, expanded SELinux policy directory protection, and `[SUMMARY]` run telemetry.
- **WebUI & License:**
  - Added Active Mounts Ledger viewer, `<dialog>` unmount confirmation, all 7 `config.conf` toggles, segmented log viewer, and verbatim GNU GPL v3.0 (`LICENSE`).
- **SHA-256 (`UniMount-v2.5.0-KSU-WebUI.zip`):** `a3d0f8da945c7c5c5bb3e8afd5c62bf51f91242f080c5cbe52920e62d56e148a`
- **Compare:** [`v2.4.4...v2.5.0`](https://github.com/HazY-Codes/Unimount/compare/v2.4.4...v2.5.0)

---

### [v2.4.4](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.4) — 2026-11-19

- Added `assets/banner.svg`, live GitHub release/commit/download badges, and restructured `README.md`.
- Synchronized `v2.4.4` (`versionCode=244`) across scripts, WebUI, and metadata.
- **SHA-256 (`UniMount-v2.4.4-KSU-WebUI.zip`):** `8ad4349b5cb69cc39ad20f8813ec01d456d99e5847048088583901637fd6315e`
- **Compare:** [`v2.4.3...v2.4.4`](https://github.com/HazY-Codes/Unimount/compare/v2.4.3...v2.4.4)

---

### [v2.4.3](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.3) — 2026-11-19

- Added single-metamodule conflict abort guard and competing mount-engine warnings in `customize.sh`.
- Added Safe Mode bypass, per-`boot_id` bootloop circuit breaker (`BOOTLOOP_GUARD`), and `boot-completed.sh` reset.
- Added critical system path protection (`PROTECT_CRITICAL_PATHS`), strict Enforcing SELinux fail-closed `chcon` checks, POSIX permission/owner mirroring, `remount,ro,bind`, and atomic `.lock` PID guard.
- Added soft-reboot stale mount reconciliation via `active_mounts.list` and `boot_id` tracking in `service.sh`.
- **SHA-256 (`UniMount-v2.4.3-KSU-WebUI.zip`):** `df08ae625811a03c82f05c8821961468377680663302eddd0f3f5b6f2190ad64`
- **Compare:** [`v2.4.2...v2.4.3`](https://github.com/HazY-Codes/Unimount/compare/v2.4.2...v2.4.3)

---

### [v2.4.2](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.2) — 2026-11-19

- Expanded `cleanup_orphan_dir` allowlist in `customize.sh`.
- Replaced hardcoded directory lists in `webroot/app.js` with `CORE_ADB_DIRS`, `webroot/known_dirs.json`, optional `/data/adb/unimount/known_dirs.json` overrides, and dynamic `module.prop` resolution.
- **SHA-256 (`UniMount-v2.4.2-KSU-WebUI.zip`):** `67d945954ea1b70bb50d8d5fdb3dec7f23d5bb8f4389756a77c84b403d066d09`
- **Compare:** [`v2.4.0...v2.4.2`](https://github.com/HazY-Codes/Unimount/compare/v2.4.0...v2.4.2)

---

### [v2.4.0](https://github.com/HazY-Codes/Unimount/releases/tag/v2.4.0) — 2026-11-16

- Initial Knox `0x0`-safe KernelSU metamodule (`id=unimount`, `metamodule=1`) with SELinux context mirroring, auto/manual mount modes, Zygisk-only skipping, `/data/adb/metamodule` symlink wiring, and offline KSU WebUI.
- **SHA-256 (`UniMount-v2.4.0-KSU-WebUI.zip`):** `e739d59785197b36f8a8c457da11293cf0848d03c8ed004d20f97c85eb7e8866`
