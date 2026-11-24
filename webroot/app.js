/* SPDX-License-Identifier: GPL-3.0-or-later */
(function () {
  "use strict";

  const APP_VERSION = "v2.5.1";
  const APP_VERSION_CODE = "251";
  const THEME_STORAGE_KEY = "unimount.theme";
  const DYNAMIC_STORAGE_KEY = "unimount.dynamicColor";
  const THEME_MODES = ["system", "light", "dark"];
  const CONFIG_SWITCH_IDS = [
    "cfg-manual-mode",
    "cfg-selinux-mirror",
    "cfg-dir-mirror",
    "cfg-skip-zygisk",
    "cfg-bootloop-guard",
    "cfg-protect-critical",
    "cfg-log-verbose"
  ];

  let cbSeq = 0;
  let toastTimer = null;

  const $ = (id) => document.getElementById(id);
  const setText = (id, val) => {
    const el = $(id);
    if (el) el.textContent = val;
  };

  // Dual-mode KernelSU root shell bridge (3-arg callback, 2-arg callback, or sync string return)
  function ksuExec(command, timeoutMs) {
    const limit = typeof timeoutMs === "number" && timeoutMs > 0 ? timeoutMs : 8000;
    return new Promise((resolve) => {
      if (typeof window.ksu === "undefined" || typeof window.ksu.exec !== "function") {
        resolve({ errno: 127, stdout: "", stderr: "window.ksu bridge not detected" });
        return;
      }

      const cbName = "__unimount_cb_" + (++cbSeq) + "_" + Date.now();
      let settled = false;
      let timerId = null;

      const finish = (errno, stdout, stderr) => {
        if (settled) return;
        settled = true;
        if (timerId !== null) clearTimeout(timerId);
        delete window[cbName];
        const code = Number(errno);
        resolve({
          errno: Number.isFinite(code) ? code : 0,
          stdout: String(stdout || ""),
          stderr: String(stderr || "")
        });
      };

      window[cbName] = finish;
      timerId = setTimeout(() => finish(124, "", "ksu.exec timed out"), limit);

      try {
        const ret = window.ksu.exec(command, "{}", cbName);
        if (typeof ret === "string") finish(0, ret, "");
      } catch (_err) {
        try {
          const ret2 = window.ksu.exec(command, cbName);
          if (typeof ret2 === "string") finish(0, ret2, "");
        } catch (err2) {
          finish(1, "", String(err2));
        }
      }
    });
  }

  function showToast(msg) {
    if (typeof window.ksu !== "undefined" && typeof window.ksu.toast === "function") {
      try {
        window.ksu.toast(msg);
        return;
      } catch (_e) {}
    }
    const box = $("toast-box");
    if (!box) return;
    box.textContent = msg;
    box.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => box.classList.remove("show"), 2600);
  }

  // 3-Mode Theme & Dynamic Color Controller
  function readPref(key, fallback) {
    try {
      const val = window.localStorage.getItem(key);
      return val !== null ? val : fallback;
    } catch (_e) {
      return fallback;
    }
  }

  function writePref(key, val) {
    try {
      window.localStorage.setItem(key, val);
    } catch (_e) {}
  }

  function applyTheme(mode, dynamicColor) {
    const safeMode = THEME_MODES.includes(mode) ? mode : "system";
    const safeDyn = Boolean(dynamicColor);
    const root = document.documentElement;
    root.setAttribute("data-theme", safeMode);
    root.setAttribute("data-dynamic-color", safeDyn ? "true" : "false");

    const prefersDark =
      window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
    const isDark = safeMode === "dark" || (safeMode === "system" && prefersDark);
    const metaTheme = $("meta-theme-color");
    if (metaTheme) metaTheme.setAttribute("content", isDark ? "#1B1D24" : "#F6F8FC");

    const labels = { system: "Follow System", light: "Light", dark: "Dark" };
    const cycleBtn = $("btn-theme-cycle");
    if (cycleBtn) {
      const label = "Theme: " + labels[safeMode];
      cycleBtn.title = label;
      cycleBtn.setAttribute("aria-label", label + " (tap to cycle)");
    }

    document.querySelectorAll("#theme-mode-tabs .seg-btn").forEach((btn) => {
      const active = btn.getAttribute("data-theme-set") === safeMode;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-checked", active ? "true" : "false");
    });
    const dynToggle = $("cfg-dynamic-color");
    if (dynToggle) dynToggle.checked = safeDyn;

    state.themeMode = safeMode;
    state.dynamicColor = safeDyn;
  }

  // Core /data/adb directories (never flagged as orphans)
  const CORE_ADB_DIRS = {
    ksu: { name: "KernelSU Core", role: "KernelSU binaries and allowlist database (/data/adb/ksu)", systemCore: true },
    magisk: { name: "Magisk Core", role: "Magisk binaries and policy database (/data/adb/magisk)", systemCore: true },
    ap: { name: "APatch Core", role: "APatch binaries and module state (/data/adb/ap)", systemCore: true },
    metamodule: { name: "Active Metamodule", role: "Active metamodule link (/data/adb/metamodule)", systemCore: true },
    modules: { name: "Active Modules", role: "Installed root modules (/data/adb/modules)", systemCore: true },
    modules_update: { name: "Staged Updates", role: "Pending module updates (/data/adb/modules_update)", systemCore: true },
    "post-fs-data.d": { name: "Early-Boot Scripts", role: "Global post-fs-data scripts (/data/adb/post-fs-data.d)", systemCore: true },
    "post-mount.d": { name: "Post-Mount Scripts", role: "Global post-mount scripts (/data/adb/post-mount.d)", systemCore: true },
    "service.d": { name: "Late-Start Scripts", role: "Global service scripts (/data/adb/service.d)", systemCore: true },
    "boot-completed.d": { name: "Boot-Completed Scripts", role: "Global boot-completed scripts (/data/adb/boot-completed.d)", systemCore: true },
    unimount: { name: "UniMount State", role: "UniMount config, whitelist, mirror, and logs (/data/adb/unimount)", systemCore: true }
  };

  function normalizeKey(value) {
    return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  }

  function isSafeModuleId(id) {
    return typeof id === "string" && id.length > 0 && id !== "." && id !== ".." && /^[A-Za-z0-9._][A-Za-z0-9._-]*$/.test(id);
  }

  function isSafeModulePath(modPath, modId) {
    if (!isSafeModuleId(modId) || typeof modPath !== "string") return false;
    return modPath === "/data/adb/modules/" + modId || modPath === "/data/adb/modules_update/" + modId;
  }

  function isSafeOrphanDirName(name) {
    return isSafeModuleId(name) && !Object.prototype.hasOwnProperty.call(CORE_ADB_DIRS, name);
  }

  function parseJsonObject(rawText) {
    const trimmed = String(rawText || "").trim();
    if (!trimmed) return {};
    try {
      const parsed = JSON.parse(trimmed);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (_e) {
      return {};
    }
  }

  async function loadExternalDirCatalog(url) {
    try {
      const res = await fetch(url || "./known_dirs.json", { cache: "no-store" });
      if (!res.ok) return {};
      const parsed = await res.json();
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (_e) {
      return {};
    }
  }

  function resolveAdbDirMeta(dirName, installedModules, externalCatalog) {
    if (Object.prototype.hasOwnProperty.call(CORE_ADB_DIRS, dirName)) {
      return Object.assign({ matchedModuleId: null, isOrphan: false }, CORE_ADB_DIRS[dirName]);
    }

    const catalogEntry =
      externalCatalog && Object.prototype.hasOwnProperty.call(externalCatalog, dirName)
        ? externalCatalog[dirName]
        : null;

    const normDir = normalizeKey(dirName);
    const modList = Array.isArray(installedModules) ? installedModules : [];

    let matchedMod = null;
    if (catalogEntry && Array.isArray(catalogEntry.expectedModIds)) {
      const expectedNorms = new Set(catalogEntry.expectedModIds.map(normalizeKey).filter(Boolean));
      matchedMod = modList.find(
        (m) => catalogEntry.expectedModIds.includes(m.id) || expectedNorms.has(normalizeKey(m.id))
      ) || null;
    }

    if (!matchedMod) {
      matchedMod = modList.find(
        (m) => normalizeKey(m.id) === normDir || normalizeKey(m.name) === normDir
      ) || null;
    }

    if (!matchedMod && normDir.length >= 4) {
      matchedMod = modList.find((m) => {
        const nid = normalizeKey(m.id);
        const nname = normalizeKey(m.name);
        return (nid.length >= 4 && (nid.includes(normDir) || normDir.includes(nid))) ||
          (nname.length >= 4 && nname.includes(normDir));
      }) || null;
    }

    if (catalogEntry) {
      const isCore = Boolean(catalogEntry.systemCore);
      return {
        name: catalogEntry.name || dirName,
        role: catalogEntry.role || ("Standalone directory (/data/adb/" + dirName + ")"),
        expectedModIds: Array.isArray(catalogEntry.expectedModIds) ? catalogEntry.expectedModIds : [dirName],
        systemCore: isCore,
        matchedModuleId: matchedMod ? matchedMod.id : null,
        isOrphan: !isCore && !matchedMod
      };
    }

    if (matchedMod) {
      return {
        name: matchedMod.name || matchedMod.id,
        role: (matchedMod.description || "Module runtime data") + " (/data/adb/" + dirName + ")",
        expectedModIds: [matchedMod.id],
        systemCore: false,
        matchedModuleId: matchedMod.id,
        isOrphan: false
      };
    }

    return {
      name: dirName,
      role: "Standalone directory (/data/adb/" + dirName + ")",
      expectedModIds: [dirName],
      systemCore: false,
      matchedModuleId: null,
      isOrphan: true
    };
  }

  function detectZygiskProvider(modules, adbDirs) {
    const findMod = (kw) => modules.find((m) => normalizeKey(m.id).includes(kw) || normalizeKey(m.name).includes(kw));
    const hasDir = (name) => adbDirs.some((d) => d.name === name);

    const znext = findMod("zygisknext") || findMod("zygisksu");
    if (znext || hasDir("zygisksu")) return znext ? znext.name : "Zygisk Next (zygisksu)";

    const rezygisk = findMod("rezygisk");
    if (rezygisk || hasDir("rezygisk")) return rezygisk ? rezygisk.name : "ReZygisk";

    const neozygisk = findMod("neozygisk");
    if (neozygisk || hasDir("neo_zygisk")) return neozygisk ? neozygisk.name : "NeoZygisk";

    return "None detected";
  }

  const state = {
    bridgeOnline: false,
    themeMode: "system",
    dynamicColor: true,
    filter: "all",
    search: "",
    mountSearch: "",
    logView: "mountlog",
    modules: [],
    activeMounts: [],
    ledgerSource: "none",
    adbDirs: [],
    bundledCatalog: {},
    externalCatalog: {},
    pendingUpdates: false,
    guardBypassed: false,
    bootFailCount: 0,
    config: {
      MOUNT_MODE: "auto",
      SELINUX_MIRROR: "1",
      DIR_MIRROR_INJECT: "1",
      SKIP_ZYGISK_ONLY: "1",
      LOG_VERBOSE: "1",
      BOOTLOOP_GUARD: "1",
      PROTECT_CRITICAL_PATHS: "1"
    }
  };

  // Single-pass shell scanner with busybox awk fallback, newline padding, and mountinfo support
  const SCAN_SCRIPT = `
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
if ! command -v awk >/dev/null 2>&1; then
  for _bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$_bb" ]; then
      _UM_BB="$_bb"
      awk() { "$_UM_BB" awk "$@"; }
      break
    fi
  done
fi

mkdir -p /data/adb/unimount
[ -f /data/adb/unimount/modules.txt ] || touch /data/adb/unimount/modules.txt
[ -f /data/adb/unimount/config.conf ] || printf "MOUNT_MODE=auto\\nSELINUX_MIRROR=1\\nDIR_MIRROR_INJECT=1\\nSKIP_ZYGISK_ONLY=1\\nLOG_VERBOSE=1\\nBOOTLOOP_GUARD=1\\nPROTECT_CRITICAL_PATHS=1\\n" > /data/adb/unimount/config.conf

_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "")
_last_mount_boot=$(cat /data/adb/unimount/.last_mount_boot_id 2>/dev/null || echo "")
_bypass_boot=$(cat /data/adb/unimount/.bypass_boot_id 2>/dev/null || echo "")

_ledger_file=""
_ledger_src="none"
if [ -r /dev/unimount_active_mounts ]; then
  _ledger_file="/dev/unimount_active_mounts"
  _ledger_src="/dev/unimount_active_mounts"
elif [ -n "$_boot_id" ] && [ "$_boot_id" = "$_last_mount_boot" ] && [ -r /data/adb/unimount/active_mounts.list ]; then
  _ledger_file="/data/adb/unimount/active_mounts.list"
  _ledger_src="active_mounts.list"
fi

if [ -n "$_ledger_file" ] && [ -s "$_ledger_file" ]; then
  _active_count=$(wc -l < "$_ledger_file" 2>/dev/null | tr -d ' ')
  _mirror_count=$(awk -F'|' '$4 == "DIR_MIRROR" { c++ } END { print c + 0 }' "$_ledger_file" 2>/dev/null)
elif [ -r /proc/self/mountinfo ]; then
  _active_count=$(awk '$4 ~ /\\/adb\\/modules\\/|\\/unimount\\/mirror\\/merged/ { c++ } END { print c + 0 }' /proc/self/mountinfo 2>/dev/null)
  _mirror_count=$(awk '$4 ~ /\\/unimount\\/mirror\\/merged/ { c++ } END { print c + 0 }' /proc/self/mountinfo 2>/dev/null)
else
  _active_count=$(awk '/\\/data\\/adb\\/modules\\/|\\/data\\/adb\\/unimount\\/mirror\\/merged/ { c++ } END { print c + 0 }' /proc/mounts 2>/dev/null)
  _mirror_count=$(awk '/\\/data\\/adb\\/unimount\\/mirror\\/merged/ { c++ } END { print c + 0 }' /proc/mounts 2>/dev/null)
fi

_seccomp_raw=$(awk '/^Seccomp:/ { print $2; exit }' /proc/self/status 2>/dev/null || echo "")
case "$_seccomp_raw" in
  0) _seccomp="Disabled" ;;
  1) _seccomp="Strict" ;;
  2) _seccomp="Filter" ;;
  *) _seccomp="Unknown" ;;
esac

_guard_bypassed=0
[ -n "$_boot_id" ] && [ "$_bypass_boot" = "$_boot_id" ] && _guard_bypassed=1

_safemode=0
if [ "$(getprop persist.sys.safemode 2>/dev/null)" = "1" ] || [ "$(getprop ro.sys.safemode 2>/dev/null)" = "1" ] || [ -f /data/adb/ksu/.safemode ]; then
  _safemode=1
fi

echo "===SYS==="
echo "MODEL=$(getprop ro.product.model) ($(getprop ro.build.display.id))"
echo "ANDROID=$(getprop ro.build.version.release) ($(getprop ro.build.version.sdk))"
echo "ABI=$(getprop ro.product.cpu.abilist 2>/dev/null || uname -m)"
echo "KERNEL=$(uname -r) ($(uname -m))"
echo "SELINUX=$(getenforce 2>/dev/null || echo Enforcing)"
echo "SECCOMP=$_seccomp"
echo "KNOX=$(getprop ro.boot.warranty_bit 2>/dev/null || echo 0)"
echo "DISK=$(df -h /data/adb 2>/dev/null | tail -n 1 | awk '{print $3 " / " $2 " (" $5 ")"}')"
echo "METAMOD=$(readlink /data/adb/metamodule 2>/dev/null || echo 'None')"
echo "KSUD=$(/data/adb/ksud --version 2>/dev/null || echo 'Present')"
echo "BINDCOUNT=\${_active_count:-0}"
echo "MIRRORCOUNT=\${_mirror_count:-0}"
echo "LEDGERSRC=$_ledger_src"
echo "BOOTFAIL=$(cat /data/adb/unimount/.boot_fail_count 2>/dev/null || echo 0)"
echo "GUARDBYPASSED=$_guard_bypassed"
echo "SAFEMODE=$_safemode"

echo "===ACTIVE_MOUNTS==="
[ -n "$_ledger_file" ] && [ -s "$_ledger_file" ] && { cat "$_ledger_file" 2>/dev/null; echo ""; }

echo "===CONFIG==="
[ -r /data/adb/unimount/config.conf ] && { cat /data/adb/unimount/config.conf 2>/dev/null; echo ""; }

echo "===WHITELIST==="
[ -r /data/adb/unimount/modules.txt ] && { cat /data/adb/unimount/modules.txt 2>/dev/null; echo ""; }

echo "===USER_CATALOG==="
[ -f /data/adb/unimount/known_dirs.json ] && { cat /data/adb/unimount/known_dirs.json 2>/dev/null; echo ""; }

echo "===MODULES==="
for base in /data/adb/modules /data/adb/modules_update; do
  [ -d "$base" ] || continue
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    mod_id=$(basename "$d")
    echo "---MOD:$base:$mod_id---"
    [ -f "$d/module.prop" ] && { cat "$d/module.prop" 2>/dev/null; echo ""; }
    overlays=""
    for p in system vendor product system_ext odm prism optics; do
      [ -d "$d/$p" ] && overlays="$overlays/$p "
    done
    echo "__OVERLAYS=$overlays"
    [ -f "$d/disable" ] && echo "__DISABLED=1"
    [ -f "$d/remove" ] && echo "__REMOVE=1"
    [ -f "$d/skip_mount" ] && echo "__SKIP_MOUNT=1"
    [ -f "$d/skip_unimount" ] && echo "__SKIP_UNIMOUNT=1"
    if ([ -n "$_ledger_file" ] && [ -s "$_ledger_file" ] && awk -F'|' -v m="$mod_id" 'index("," $1 ",", "," m ",") > 0 { found=1; exit } END { exit !found }' "$_ledger_file" 2>/dev/null) || grep -Fq "/modules/$mod_id/" /proc/self/mountinfo 2>/dev/null || grep -Fq "$d/" /proc/mounts 2>/dev/null; then
      echo "__MOUNTED=1"
    fi
  done
done

echo "===ADB_DIRS==="
for item in /data/adb/*; do
  [ -e "$item" ] || continue
  bname=$(basename "$item")
  if [ -L "$item" ]; then
    echo "LINK|$bname|$(readlink "$item" 2>/dev/null)"
  elif [ -d "$item" ]; then
    echo "DIR|$bname"
  else
    echo "FILE|$bname"
  fi
done
`;

  function parseScanOutput(raw) {
    const sections = {};
    let current = "";
    for (const line of raw.split(/\r?\n/)) {
      if (line.startsWith("===") && line.endsWith("===")) {
        current = line.slice(3, -3);
        sections[current] = [];
      } else if (current) {
        sections[current].push(line);
      }
    }

    const sys = {};
    for (const l of (sections.SYS || [])) {
      const idx = l.indexOf("=");
      if (idx > 0) sys[l.slice(0, idx)] = l.slice(idx + 1).trim();
    }
    state.ledgerSource = sys.LEDGERSRC || "none";

    const activeMounts = [];
    const perModMounts = new Map();
    for (const l of (sections.ACTIVE_MOUNTS || [])) {
      const trimmed = l.trim();
      if (!trimmed) continue;
      const parts = trimmed.split("|");
      if (parts.length < 2) continue;
      const modsRaw = parts[0] || "";
      const dst = parts[1] || "";
      const src = parts[2] || "";
      const type = parts[3] || (src.includes("/unimount/mirror/") ? "DIR_MIRROR" : "FILE_BIND");
      const mods = modsRaw.split(",").map((x) => x.trim()).filter(Boolean);
      activeMounts.push({ modsRaw, mods, dst, src, type });
      for (const mId of mods) {
        const cur = perModMounts.get(mId) || { binds: 0, mirrors: 0 };
        if (type === "DIR_MIRROR") cur.mirrors += 1;
        else cur.binds += 1;
        perModMounts.set(mId, cur);
      }
    }
    state.activeMounts = activeMounts;

    const cfg = {
      MOUNT_MODE: "auto",
      SELINUX_MIRROR: "1",
      DIR_MIRROR_INJECT: "1",
      SKIP_ZYGISK_ONLY: "1",
      LOG_VERBOSE: "1",
      BOOTLOOP_GUARD: "1",
      PROTECT_CRITICAL_PATHS: "1"
    };
    for (const l of (sections.CONFIG || [])) {
      const idx = l.indexOf("=");
      if (idx > 0) cfg[l.slice(0, idx).trim()] = l.slice(idx + 1).trim();
    }
    state.config = cfg;
    state.bootFailCount = parseInt(sys.BOOTFAIL || "0", 10) || 0;
    state.guardBypassed = sys.GUARDBYPASSED === "1" || state.bootFailCount >= 2;

    const whitelist = new Set((sections.WHITELIST || []).map((x) => x.trim()).filter(Boolean));
    const userCatalog = parseJsonObject((sections.USER_CATALOG || []).join("\n"));
    state.externalCatalog = Object.assign({}, state.bundledCatalog, userCatalog);

    const modMap = new Map();
    let curMod = null;
    let hasUpdatePending = false;

    for (const l of (sections.MODULES || [])) {
      if (l.startsWith("---MOD:") && l.endsWith("---")) {
        const inner = l.slice(7, -3);
        const splitIdx = inner.indexOf(":");
        if (splitIdx < 1) continue;
        const baseDir = inner.slice(0, splitIdx);
        const modId = inner.slice(splitIdx + 1);
        const isUpdate = baseDir.endsWith("modules_update");
        if (isUpdate) hasUpdatePending = true;

        const mStats = perModMounts.get(modId) || { binds: 0, mirrors: 0 };
        curMod = modMap.get(modId) || {
          id: modId,
          name: modId,
          version: "",
          author: "",
          description: "",
          path: baseDir + "/" + modId,
          isUpdatePending: isUpdate,
          overlays: [],
          disabled: false,
          remove: false,
          skipMount: false,
          skipUnimount: false,
          mounted: mStats.binds > 0 || mStats.mirrors > 0,
          mountBinds: mStats.binds,
          mountMirrors: mStats.mirrors,
          whitelisted: whitelist.has(modId),
          sourceType: "module"
        };
        if (isUpdate) curMod.isUpdatePending = true;
        modMap.set(modId, curMod);
      } else if (curMod) {
        if (l.startsWith("__OVERLAYS=")) {
          curMod.overlays = l.slice(11).trim().split(/\s+/).filter(Boolean);
        } else if (l === "__DISABLED=1") curMod.disabled = true;
        else if (l === "__REMOVE=1") curMod.remove = true;
        else if (l === "__SKIP_MOUNT=1") curMod.skipMount = true;
        else if (l === "__SKIP_UNIMOUNT=1") curMod.skipUnimount = true;
        else if (l === "__MOUNTED=1") curMod.mounted = true;
        else {
          const eq = l.indexOf("=");
          if (eq > 0) {
            const k = l.slice(0, eq).trim();
            const v = l.slice(eq + 1).trim();
            if (k === "name") curMod.name = v;
            else if (k === "version") curMod.version = v;
            else if (k === "author") curMod.author = v;
            else if (k === "description") curMod.description = v;
          }
        }
      }
    }

    const installedList = Array.from(modMap.values());
    const adbDirs = [];
    for (const l of (sections.ADB_DIRS || [])) {
      const [kind, name, target] = l.split("|");
      if (!name || name === "modules" || name === "modules_update") continue;
      const meta = kind === "DIR" ? resolveAdbDirMeta(name, installedList, state.externalCatalog) : null;
      adbDirs.push({ kind, name, target: target || "", meta });

      if (kind === "DIR" && meta && !meta.systemCore && !meta.matchedModuleId && !modMap.has(name)) {
        modMap.set(name, {
          id: name,
          name: meta.name,
          version: "standalone",
          author: "/data/adb/" + name,
          description: meta.role,
          path: "/data/adb/" + name,
          isUpdatePending: false,
          overlays: [],
          disabled: false,
          remove: false,
          skipMount: false,
          skipUnimount: false,
          mounted: false,
          mountBinds: 0,
          mountMirrors: 0,
          whitelisted: whitelist.has(name),
          sourceType: "standalone",
          isOrphanCandidate: Boolean(meta.isOrphan)
        });
      }
    }

    state.modules = Array.from(modMap.values()).sort((a, b) => {
      if (a.overlays.length !== b.overlays.length) return b.overlays.length - a.overlays.length;
      return a.name.localeCompare(b.name);
    });
    state.adbDirs = adbDirs;
    state.pendingUpdates = hasUpdatePending;

    updateStatusUI(sys);
    updateConfigUI();
    renderModules();
    renderActiveMounts();
    renderHygiene();
  }

  function updateStatusUI(sys) {
    const heroCard = $("hero-card");
    const alertPill = $("hero-pill-alert");
    const knoxBit = !sys.KNOX || sys.KNOX === "0" ? "0x0" : sys.KNOX;
    const isDegraded = !state.bridgeOnline || state.guardBypassed || sys.SAFEMODE === "1";

    if (heroCard) heroCard.classList.toggle("is-degraded", isDegraded);

    if (!state.bridgeOnline) {
      setText("hero-title", "Bridge Offline");
      if (alertPill) {
        alertPill.style.display = "inline-block";
        alertPill.textContent = "No root bridge";
      }
    } else if (sys.SAFEMODE === "1") {
      setText("hero-title", "Safe Mode");
      if (alertPill) {
        alertPill.style.display = "inline-block";
        alertPill.textContent = "Mounts paused";
      }
    } else if (state.guardBypassed) {
      setText("hero-title", "Guard Bypassed");
      if (alertPill) {
        alertPill.style.display = "inline-block";
        alertPill.textContent = "Reset needed";
      }
    } else {
      setText("hero-title", "Working");
      if (alertPill) alertPill.style.display = "none";
    }

    setText("hero-version", "Version: " + APP_VERSION + " (" + APP_VERSION_CODE + ")");
    setText("hero-pill-knox", "Knox " + knoxBit);
    setText("hero-pill-mode", state.config.MOUNT_MODE === "manual" ? "Manual" : "Auto");

    const activeCount = sys.BINDCOUNT || String(state.activeMounts.length);
    const modCount = state.modules.filter((m) => m.sourceType === "module").length;
    setText("kpi-mounts", state.bridgeOnline ? activeCount : "0");
    setText("kpi-modules", state.bridgeOnline ? String(modCount) : "0");

    const metamod = sys.METAMOD || "None";
    setText(
      "sys-symlink",
      state.bridgeOnline
        ? (metamod.includes("unimount") ? "Installed | UniMount | " + APP_VERSION : metamod)
        : "--"
    );
    setText("sys-bridge", state.bridgeOnline ? "Connected (UID 0) | " + (sys.KSUD || "ksud") : "Offline");
    setText("sys-kernel", sys.KERNEL || "--");
    setText("sys-android", sys.ANDROID || "--");
    setText("sys-abi", sys.ABI || "--");
    setText("sys-selinux", sys.SELINUX || "--");
    setText("sys-seccomp", sys.SECCOMP || "--");
    setText("sys-device", sys.MODEL || "--");
    setText("sys-zygisk", state.bridgeOnline ? detectZygiskProvider(state.modules, state.adbDirs) : "--");

    const mirrorCount = parseInt(sys.MIRRORCOUNT || "0", 10) || 0;
    const bindCount = Math.max(0, (parseInt(activeCount, 10) || 0) - mirrorCount);
    setText(
      "sys-ledger",
      state.bridgeOnline
        ? `${mirrorCount} mirror(s), ${bindCount} bind(s) · ${state.ledgerSource}`
        : "--"
    );

    let guardLabel = state.config.BOOTLOOP_GUARD === "0"
      ? "Disabled"
      : `Armed (${state.bootFailCount}/2 fails)`;
    if (sys.SAFEMODE === "1") guardLabel = "Safe Mode bypass active";
    else if (state.guardBypassed) guardLabel = `Bypassed (${state.bootFailCount} fails) — reset required`;
    setText("sys-guard", state.bridgeOnline ? guardLabel : "--");
    setText("sys-disk", sys.DISK || "--");

    const guardBanner = $("bootloop-banner");
    if (guardBanner) guardBanner.style.display = state.bridgeOnline && state.guardBypassed ? "flex" : "none";

    const syncBtn = $("btn-sync-updates");
    const pendingBanner = $("pending-banner");
    const showPending = state.bridgeOnline && state.pendingUpdates;
    if (syncBtn) syncBtn.style.display = showPending ? "inline-flex" : "none";
    if (pendingBanner) pendingBanner.style.display = showPending ? "flex" : "none";

    ["btn-run-metamount", "btn-emergency-unmount", "btn-clear-log"].forEach((id) => {
      const el = $(id);
      if (el) el.disabled = !state.bridgeOnline;
    });
    CONFIG_SWITCH_IDS.forEach((id) => {
      const el = $(id);
      if (el) el.disabled = !state.bridgeOnline;
    });
  }

  function renderActiveMounts() {
    const listEl = $("active-mounts-list");
    const searchWrap = $("mount-search-wrap");
    if (!listEl) return;

    const total = state.activeMounts.length;
    setText("active-mounts-meta", `${total} active`);

    if (!state.bridgeOnline) {
      if (searchWrap) searchWrap.style.display = "none";
      listEl.innerHTML = `<div class="empty-state">Open inside KernelSU Manager WebUI to read <code>/dev/unimount_active_mounts</code>.</div>`;
      return;
    }

    if (searchWrap) searchWrap.style.display = total > 4 ? "block" : "none";

    if (total === 0) {
      listEl.innerHTML = `<div class="empty-state">No active mounts recorded for this boot.</div>`;
      return;
    }

    const q = state.mountSearch.toLowerCase();
    const filtered = q
      ? state.activeMounts.filter((item) =>
          (item.modsRaw + " " + item.dst + " " + item.type + " " + item.src).toLowerCase().includes(q)
        )
      : state.activeMounts;

    if (filtered.length === 0) {
      listEl.innerHTML = `<div class="empty-state">No mounts match "${escapeHtml(state.mountSearch)}".</div>`;
      return;
    }

    listEl.innerHTML = filtered.map((item) => {
      const typeClass = item.type === "DIR_MIRROR" ? "badge-primary" : "badge";
      const modBadges = item.mods.map((m) => `<span class="badge badge-ok">${escapeHtml(m)}</span>`).join("");
      return `
        <div class="mount-row">
          <div class="badge-row">
            <span class="badge ${typeClass}">${escapeHtml(item.type)}</span>
            ${modBadges}
          </div>
          <div class="mount-target">${escapeHtml(item.dst)}</div>
          ${item.src ? `<div class="mount-source">&larr; ${escapeHtml(item.src)}</div>` : ""}
        </div>
      `;
    }).join("");
  }

  function updateConfigUI() {
    const setChecked = (id, val) => {
      const el = $(id);
      if (el) el.checked = val;
    };
    setChecked("cfg-manual-mode", state.config.MOUNT_MODE === "manual");
    setChecked("cfg-selinux-mirror", state.config.SELINUX_MIRROR !== "0");
    setChecked("cfg-dir-mirror", state.config.DIR_MIRROR_INJECT !== "0");
    setChecked("cfg-skip-zygisk", state.config.SKIP_ZYGISK_ONLY !== "0");
    setChecked("cfg-bootloop-guard", state.config.BOOTLOOP_GUARD !== "0");
    setChecked("cfg-protect-critical", state.config.PROTECT_CRITICAL_PATHS !== "0");
    setChecked("cfg-log-verbose", state.config.LOG_VERBOSE !== "0");
  }

  function renderModules() {
    const listEl = $("module-list");
    if (!listEl) return;
    setText("modules-meta", `${state.modules.length} detected`);

    if (!state.bridgeOnline) {
      listEl.innerHTML = `<div class="empty-state">
        <strong>KernelSU bridge not detected</strong><br/>
        Open this page from KernelSU Manager &rarr; Modules &rarr; UniMount &rarr; WebUI.
      </div>`;
      return;
    }

    const filtered = state.modules.filter((m) => {
      if (state.filter === "overlay" && m.overlays.length === 0) return false;
      if (state.filter === "mounted" && !m.mounted) return false;
      if (state.filter === "skipped" && !m.skipUnimount && !m.skipMount) return false;
      if (state.filter === "standalone" && m.sourceType !== "standalone") return false;
      if (state.search) {
        const q = state.search.toLowerCase();
        const hay = (m.name + " " + m.id + " " + m.description + " " + m.overlays.join(" ")).toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });

    if (filtered.length === 0) {
      listEl.innerHTML = `<div class="empty-state">No modules match the current filter.</div>`;
      return;
    }

    listEl.innerHTML = filtered.map((m) => {
      const hasOverlay = m.overlays.length > 0;
      const badges = [];

      if (m.sourceType === "standalone") {
        badges.push(`<span class="badge badge-warn">Standalone</span>`);
      } else if (hasOverlay) {
        badges.push(`<span class="badge badge-primary">${escapeHtml(m.overlays.join(" "))}</span>`);
      } else {
        badges.push(`<span class="badge">Zygisk / Service</span>`);
      }

      if (m.mounted) {
        const parts = [];
        if (m.mountMirrors > 0) parts.push(`${m.mountMirrors} mirror${m.mountMirrors > 1 ? "s" : ""}`);
        if (m.mountBinds > 0) parts.push(`${m.mountBinds} bind${m.mountBinds > 1 ? "s" : ""}`);
        badges.push(`<span class="badge badge-ok">Mounted${parts.length ? " · " + escapeHtml(parts.join(", ")) : ""}</span>`);
      }
      if (m.isUpdatePending) badges.push(`<span class="badge badge-warn">Pending update</span>`);
      if (m.disabled) badges.push(`<span class="badge badge-danger">Disabled</span>`);
      if (m.skipUnimount || m.skipMount) badges.push(`<span class="badge badge-warn">Skipped</span>`);
      if (m.isOrphanCandidate) badges.push(`<span class="badge badge-danger">Orphan</span>`);

      const canDelete = m.sourceType === "standalone" && m.isOrphanCandidate && isSafeOrphanDirName(m.id);
      const controlsHtml = m.sourceType === "module"
        ? `<div class="mod-controls">
            <label class="toggle-item">
              <span>Whitelist</span>
              <span class="switch switch-sm">
                <input type="checkbox" data-action="whitelist" data-id="${escapeAttr(m.id)}" ${m.whitelisted ? "checked" : ""} />
                <span class="slider"></span>
              </span>
            </label>
            <label class="toggle-item">
              <span>skip_unimount</span>
              <span class="switch switch-sm">
                <input type="checkbox" data-action="skip_unimount" data-id="${escapeAttr(m.id)}" data-path="${escapeAttr(m.path)}" ${m.skipUnimount ? "checked" : ""} />
                <span class="slider"></span>
              </span>
            </label>
            <label class="toggle-item">
              <span>skip_mount</span>
              <span class="switch switch-sm">
                <input type="checkbox" data-action="skip_mount" data-id="${escapeAttr(m.id)}" data-path="${escapeAttr(m.path)}" ${m.skipMount ? "checked" : ""} />
                <span class="slider"></span>
              </span>
            </label>
          </div>`
        : `<div class="mod-controls">
            <span class="mod-path">${escapeHtml(m.path)}</span>
            ${canDelete ? `<button type="button" class="btn btn-danger-outline btn-sm" data-delete-dir="${escapeAttr(m.id)}">Remove</button>` : ""}
          </div>`;

      return `
        <article class="mod-card ${m.isOrphanCandidate ? "is-orphan" : ""}">
          <div class="mod-head">
            <span class="mod-name">${escapeHtml(m.name)}</span>
            <span class="mod-id">${escapeHtml(m.id)}</span>
            ${m.version ? `<span class="mod-ver">${escapeHtml(m.version)}</span>` : ""}
          </div>
          <div class="badge-row">${badges.join("")}</div>
          <div class="mod-desc">${escapeHtml(m.description || "Installed module")}</div>
          <div class="mod-path">${escapeHtml(m.path)}</div>
          ${controlsHtml}
        </article>
      `;
    }).join("");
  }

  function renderHygiene() {
    const el = $("hygiene-list");
    if (!el) return;

    if (!state.bridgeOnline) {
      el.innerHTML = `<div class="empty-state">Connect root bridge to inspect <code>/data/adb</code>.</div>`;
      return;
    }

    const items = state.adbDirs.filter((d) => d.kind === "DIR");
    if (items.length === 0) {
      el.innerHTML = `<div class="empty-state">No extra directories found in <code>/data/adb</code>.</div>`;
      return;
    }

    el.innerHTML = items.map((d) => {
      const meta = d.meta || resolveAdbDirMeta(d.name, state.modules, state.externalCatalog);
      const isCore = Boolean(meta.systemCore);
      const isOrphan = !isCore && Boolean(meta.isOrphan);
      const canDelete = isOrphan && isSafeOrphanDirName(d.name);

      let actionHtml = `<span class="badge badge-ok">Active</span>`;
      if (isCore) actionHtml = `<span class="badge badge-primary">Core</span>`;
      else if (canDelete) actionHtml = `<button type="button" class="btn btn-danger-outline btn-sm" data-delete-dir="${escapeAttr(d.name)}">Remove</button>`;

      return `
        <div class="hygiene-row">
          <div class="hygiene-meta">
            <div class="setting-title"><code>/data/adb/${escapeHtml(d.name)}</code> ${isOrphan ? `<span class="badge badge-danger">Orphan</span>` : ""}</div>
            <div class="setting-desc">${escapeHtml(meta.role)}</div>
          </div>
          ${actionHtml}
        </div>
      `;
    }).join("");
  }

  async function refreshAll() {
    const res = await ksuExec(SCAN_SCRIPT);
    if (res.errno === 0 && res.stdout.includes("===SYS===")) {
      state.bridgeOnline = true;
      parseScanOutput(res.stdout);
    } else {
      state.bridgeOnline = false;
      state.activeMounts = [];
      state.ledgerSource = "none";
      updateStatusUI({});
      renderModules();
      renderActiveMounts();
      renderHygiene();
    }
  }

  async function loadLogs(viewMode) {
    const mode = viewMode || state.logView || "mountlog";
    state.logView = mode;
    const logEl = $("log-output");
    if (!logEl) return;

    if (!state.bridgeOnline) {
      logEl.textContent = "Root bridge offline. Open UniMount WebUI inside KernelSU Manager to view logs.";
      return;
    }

    if (mode === "procmounts") {
      const res = await ksuExec("grep -E 'adb|overlay|ksu|unimount|mirror' /proc/mounts 2>/dev/null || cat /proc/mounts");
      logEl.textContent = res.stdout || "No matching mount entries.";
    } else if (mode === "ledger") {
      const res = await ksuExec("if [ -s /dev/unimount_active_mounts ]; then echo '# /dev/unimount_active_mounts'; cat /dev/unimount_active_mounts; elif [ -s /data/adb/unimount/active_mounts.list ]; then echo '# /data/adb/unimount/active_mounts.list'; cat /data/adb/unimount/active_mounts.list; else echo 'Active mount ledger is empty.'; fi");
      logEl.textContent = res.stdout || "Active mount ledger is empty.";
    } else {
      const res = await ksuExec("cat /data/adb/unimount/mount.log 2>/dev/null || echo 'mount.log is empty. Run metamount.sh from the Status tab to populate.'");
      logEl.textContent = res.stdout || "mount.log is empty.";
    }
  }

  async function runRootAction(cmd, successMsg, timeoutMs) {
    if (!state.bridgeOnline) {
      showToast("Root bridge offline");
      return { errno: 127, stdout: "", stderr: "offline" };
    }
    const res = await ksuExec(cmd, timeoutMs);
    if (res.errno === 0) {
      if (successMsg) showToast(successMsg);
    } else {
      showToast(`Action failed (errno ${res.errno})`);
    }
    return res;
  }

  async function saveConfig() {
    if (!state.bridgeOnline) {
      showToast("Root bridge offline");
      updateConfigUI();
      return;
    }
    const flag = (id, defVal) => {
      const el = $(id);
      if (!el) return defVal;
      return el.checked ? "1" : "0";
    };
    const mode = $("cfg-manual-mode") && $("cfg-manual-mode").checked ? "manual" : "auto";
    const payload = [
      `MOUNT_MODE=${mode}`,
      `SELINUX_MIRROR=${flag("cfg-selinux-mirror", "1")}`,
      `DIR_MIRROR_INJECT=${flag("cfg-dir-mirror", "1")}`,
      `SKIP_ZYGISK_ONLY=${flag("cfg-skip-zygisk", "1")}`,
      `LOG_VERBOSE=${flag("cfg-log-verbose", "1")}`,
      `BOOTLOOP_GUARD=${flag("cfg-bootloop-guard", "1")}`,
      `PROTECT_CRITICAL_PATHS=${flag("cfg-protect-critical", "1")}`
    ].join("\\n");

    await runRootAction(
      `mkdir -p /data/adb/unimount && printf '${payload}\\n' > /data/adb/unimount/config.conf`,
      "Saved config.conf"
    );
    await refreshAll();
  }

  function switchTab(target) {
    document.querySelectorAll(".nav-tab").forEach((btn) => {
      const active = btn.getAttribute("data-tab") === target;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-selected", active ? "true" : "false");
    });
    document.querySelectorAll(".tab-panel").forEach((panel) => {
      panel.classList.toggle("active", panel.id === "panel-" + target);
    });
    if (target === "diagnostics") loadLogs(state.logView);
  }

  async function copyText(text) {
    if (!text) return false;
    try {
      if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_e) {}
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      document.body.removeChild(ta);
      return ok;
    } catch (_e) {
      return false;
    }
  }

  function escapeHtml(str) {
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function escapeAttr(str) {
    return escapeHtml(str).replace(/'/g, "&#39;");
  }

  document.addEventListener("DOMContentLoaded", async () => {
    const savedTheme = readPref(THEME_STORAGE_KEY, "system");
    const savedDyn = readPref(DYNAMIC_STORAGE_KEY, "true") !== "false";
    applyTheme(savedTheme, savedDyn);

    if (window.matchMedia) {
      const mq = window.matchMedia("(prefers-color-scheme: dark)");
      if (typeof mq.addEventListener === "function") {
        mq.addEventListener("change", () => {
          if (state.themeMode === "system") applyTheme("system", state.dynamicColor);
        });
      }
    }

    state.bundledCatalog = await loadExternalDirCatalog("./known_dirs.json");

    document.querySelectorAll(".nav-tab").forEach((btn) => {
      btn.addEventListener("click", () => switchTab(btn.getAttribute("data-tab")));
    });

    const tileMounts = $("tile-mounts");
    if (tileMounts) {
      tileMounts.addEventListener("click", () => {
        const sec = $("active-mounts-section");
        if (sec) sec.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    }
    const tileModules = $("tile-modules");
    if (tileModules) {
      tileModules.addEventListener("click", () => switchTab("modules"));
    }

    const envToggle = $("btn-env-toggle");
    const envExtra = $("env-extra");
    if (envToggle && envExtra) {
      envToggle.addEventListener("click", () => {
        const collapsed = envExtra.classList.toggle("collapsed");
        envToggle.setAttribute("aria-expanded", collapsed ? "false" : "true");
      });
    }

    const themeCycleBtn = $("btn-theme-cycle");
    if (themeCycleBtn) {
      themeCycleBtn.addEventListener("click", () => {
        const next = THEME_MODES[(THEME_MODES.indexOf(state.themeMode) + 1) % THEME_MODES.length];
        writePref(THEME_STORAGE_KEY, next);
        applyTheme(next, state.dynamicColor);
      });
    }

    document.querySelectorAll("#theme-mode-tabs .seg-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        const next = btn.getAttribute("data-theme-set");
        writePref(THEME_STORAGE_KEY, next);
        applyTheme(next, state.dynamicColor);
      });
    });

    const dynToggle = $("cfg-dynamic-color");
    if (dynToggle) {
      dynToggle.addEventListener("change", () => {
        writePref(DYNAMIC_STORAGE_KEY, dynToggle.checked ? "true" : "false");
        applyTheme(state.themeMode, dynToggle.checked);
      });
    }

    document.querySelectorAll("#filter-chips .chip").forEach((chip) => {
      chip.addEventListener("click", () => {
        document.querySelectorAll("#filter-chips .chip").forEach((c) => c.classList.remove("active"));
        chip.classList.add("active");
        state.filter = chip.getAttribute("data-filter");
        renderModules();
      });
    });

    const searchInput = $("module-search");
    const clearSearchBtn = $("btn-clear-search");
    if (searchInput) {
      searchInput.addEventListener("input", (e) => {
        state.search = e.target.value.trim();
        if (clearSearchBtn) clearSearchBtn.classList.toggle("visible", state.search.length > 0);
        renderModules();
      });
    }
    if (clearSearchBtn && searchInput) {
      clearSearchBtn.addEventListener("click", () => {
        searchInput.value = "";
        state.search = "";
        clearSearchBtn.classList.remove("visible");
        renderModules();
        searchInput.focus();
      });
    }

    const mountSearchInput = $("mount-search");
    if (mountSearchInput) {
      mountSearchInput.addEventListener("input", (e) => {
        state.mountSearch = e.target.value.trim();
        renderActiveMounts();
      });
    }

    const refreshBtn = $("btn-refresh");
    if (refreshBtn) {
      refreshBtn.addEventListener("click", async () => {
        showToast("Rescanning /data/adb...");
        await refreshAll();
      });
    }

    const resetGuardBtn = $("btn-reset-guard");
    if (resetGuardBtn) {
      resetGuardBtn.addEventListener("click", async () => {
        await runRootAction(
          "echo 0 > /data/adb/unimount/.boot_fail_count && rm -f /data/adb/unimount/.bypass_boot_id",
          "Bootloop guard reset"
        );
        await refreshAll();
      });
    }

    const mergeUpdates = async () => {
      const cmd = `
        mkdir -p /data/adb/modules
        for d in /data/adb/modules_update/*; do
          [ -d "$d" ] || continue
          id=$(basename "$d")
          case "$id" in ''|.|..) continue ;; esac
          rm -rf "/data/adb/modules/$id"
          mv "$d" "/data/adb/modules/$id"
        done
      `;
      await runRootAction(cmd, "Merged modules_update", 15000);
      await refreshAll();
    };
    const mergeBtn = $("btn-merge-now");
    const syncBtn = $("btn-sync-updates");
    if (mergeBtn) mergeBtn.addEventListener("click", mergeUpdates);
    if (syncBtn) syncBtn.addEventListener("click", mergeUpdates);

    const runBtn = $("btn-run-metamount");
    if (runBtn) {
      runBtn.addEventListener("click", async () => {
        showToast("Running metamount.sh...");
        await runRootAction(
          "if [ -f /data/adb/modules/unimount/metamount.sh ]; then sh /data/adb/modules/unimount/metamount.sh 2>&1; else sh /data/adb/metamodule/metamount.sh 2>&1; fi",
          "metamount.sh completed",
          20000
        );
        await refreshAll();
      });
    }

    const unmountDialog = $("unmount-dialog");
    const unmountDesc = $("unmount-dialog-desc");
    const openUnmountBtn = $("btn-emergency-unmount");
    const cancelUnmountBtn = $("btn-cancel-unmount");
    const confirmUnmountBtn = $("btn-confirm-unmount");

    const runEmergencyUnmount = async () => {
      showToast("Detaching active mounts...");
      const res = await runRootAction(
        "if [ -f /data/adb/modules/unimount/metamount.sh ]; then sh /data/adb/modules/unimount/metamount.sh --unmount-all 2>&1; else sh /data/adb/metamodule/metamount.sh --unmount-all 2>&1; fi",
        null,
        15000
      );
      if (res.errno === 0) {
        const summary = (res.stdout || "").trim().split(/\r?\n/).pop();
        showToast(summary || "Unmount completed");
      }
      await refreshAll();
      if (state.logView === "ledger" || state.logView === "mountlog") loadLogs(state.logView);
    };

    if (openUnmountBtn) {
      openUnmountBtn.addEventListener("click", () => {
        const mirrors = state.activeMounts.filter((m) => m.type === "DIR_MIRROR").length;
        const binds = state.activeMounts.length - mirrors;
        const msg =
          `Detach ${binds} file bind(s) and ${mirrors} directory mirror(s) currently tracked in /dev/unimount_active_mounts without rebooting.`;
        if (unmountDesc) unmountDesc.textContent = msg;
        if (unmountDialog && typeof unmountDialog.showModal === "function") {
          unmountDialog.showModal();
        } else if (window.confirm(msg)) {
          runEmergencyUnmount();
        }
      });
    }
    if (cancelUnmountBtn && unmountDialog) {
      cancelUnmountBtn.addEventListener("click", () => unmountDialog.close());
    }
    if (confirmUnmountBtn) {
      confirmUnmountBtn.addEventListener("click", async () => {
        if (unmountDialog && unmountDialog.open) unmountDialog.close();
        await runEmergencyUnmount();
      });
    }
    if (unmountDialog) {
      unmountDialog.addEventListener("click", (e) => {
        if (e.target === unmountDialog) unmountDialog.close();
      });
    }

    CONFIG_SWITCH_IDS.forEach((id) => {
      const el = $(id);
      if (el) el.addEventListener("change", saveConfig);
    });

    document.body.addEventListener("change", async (e) => {
      const t = e.target;
      if (!t || !t.dataset || !t.dataset.action) return;

      const action = t.dataset.action;
      const modId = t.dataset.id;
      const modPath = t.dataset.path;

      if (!isSafeModuleId(modId)) {
        showToast("Blocked invalid module ID");
        return;
      }

      if (action === "whitelist") {
        if (t.checked) {
          await runRootAction(
            `grep -Fxq -- '${modId}' /data/adb/unimount/modules.txt 2>/dev/null || printf '%s\\n' '${modId}' >> /data/adb/unimount/modules.txt`,
            `Added ${modId} to whitelist`
          );
        } else {
          await runRootAction(
            `grep -Fxv -- '${modId}' /data/adb/unimount/modules.txt > /data/adb/unimount/.modules.tmp 2>/dev/null || true; mv /data/adb/unimount/.modules.tmp /data/adb/unimount/modules.txt`,
            `Removed ${modId} from whitelist`
          );
        }
      } else if (action === "skip_unimount" || action === "skip_mount") {
        if (!isSafeModulePath(modPath, modId)) {
          showToast("Blocked invalid module path");
          return;
        }
        if (t.checked) {
          await runRootAction(`touch '${modPath}/${action}'`, `Set ${action} on ${modId}`);
        } else {
          await runRootAction(`rm -f '${modPath}/${action}'`, `Cleared ${action} on ${modId}`);
        }
      }
      await refreshAll();
    });

    document.body.addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-delete-dir]");
      if (!btn) return;
      const dirName = btn.getAttribute("data-delete-dir");
      if (!isSafeOrphanDirName(dirName)) {
        showToast("Blocked deletion of protected directory");
        return;
      }

      if (btn.dataset.armed !== "1") {
        btn.dataset.armed = "1";
        const origText = btn.textContent;
        btn.textContent = "Confirm";
        setTimeout(() => {
          if (btn.isConnected && btn.dataset.armed === "1") {
            btn.dataset.armed = "0";
            btn.textContent = origText;
          }
        }, 4000);
        return;
      }

      await runRootAction(`rm -rf '/data/adb/${dirName}'`, `Removed /data/adb/${dirName}`);
      await refreshAll();
    });

    document.querySelectorAll("#log-view-tabs .seg-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll("#log-view-tabs .seg-btn").forEach((b) => {
          b.classList.remove("active");
          b.setAttribute("aria-selected", "false");
        });
        btn.classList.add("active");
        btn.setAttribute("aria-selected", "true");
        loadLogs(btn.getAttribute("data-log-view"));
      });
    });

    const copyLogBtn = $("btn-copy-log");
    if (copyLogBtn) {
      copyLogBtn.addEventListener("click", async () => {
        const logEl = $("log-output");
        const ok = await copyText(logEl ? logEl.textContent : "");
        showToast(ok ? "Copied to clipboard" : "Copy unavailable");
      });
    }

    const clearLogBtn = $("btn-clear-log");
    if (clearLogBtn) {
      clearLogBtn.addEventListener("click", async () => {
        const res = await runRootAction("echo '=== Log Cleared ===' > /data/adb/unimount/mount.log", "Log cleared");
        if (res.errno === 0) {
          document.querySelectorAll("#log-view-tabs .seg-btn").forEach((b) => {
            const active = b.getAttribute("data-log-view") === "mountlog";
            b.classList.toggle("active", active);
            b.setAttribute("aria-selected", active ? "true" : "false");
          });
          loadLogs("mountlog");
        }
      });
    }

    await refreshAll();
  });
})();
