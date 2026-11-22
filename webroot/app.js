/* SPDX-License-Identifier: GPL-3.0-or-later */
(function () {
  "use strict";

  let cbSeq = 0;

  // Dual-mode KernelSU Root Shell Bridge (supports 3-arg callback, 2-arg callback, and sync return)
  function ksuExec(command, timeoutMs) {
    const limit = typeof timeoutMs === "number" && timeoutMs > 0 ? timeoutMs : 8000;
    return new Promise((resolve) => {
      if (typeof window.ksu === "undefined" || typeof window.ksu.exec !== "function") {
        resolve({ errno: 127, stdout: "", stderr: "window.ksu bridge not detected" });
        return;
      }

      const cbName = "__unimount_cb_" + (++cbSeq) + "_" + Date.now();
      let settled = false;

      window[cbName] = function (errno, stdout, stderr) {
        if (settled) return;
        settled = true;
        delete window[cbName];
        resolve({
          errno: typeof errno === "number" ? errno : 0,
          stdout: String(stdout || ""),
          stderr: String(stderr || "")
        });
      };

      try {
        const ret = window.ksu.exec(command, "{}", cbName);
        if (typeof ret === "string" && !settled) {
          settled = true;
          delete window[cbName];
          resolve({ errno: 0, stdout: ret, stderr: "" });
        }
      } catch (err) {
        try {
          const ret2 = window.ksu.exec(command, cbName);
          if (typeof ret2 === "string" && !settled) {
            settled = true;
            delete window[cbName];
            resolve({ errno: 0, stdout: ret2, stderr: "" });
          }
        } catch (err2) {
          if (!settled) {
            settled = true;
            delete window[cbName];
            resolve({ errno: 1, stdout: "", stderr: String(err2) });
          }
        }
      }

      setTimeout(() => {
        if (!settled) {
          settled = true;
          delete window[cbName];
          resolve({ errno: 124, stdout: "", stderr: "ksu.exec timed out" });
        }
      }, limit);
    });
  }

  let toastTimer = null;
  function showToast(msg) {
    if (typeof window.ksu !== "undefined" && typeof window.ksu.toast === "function") {
      try { window.ksu.toast(msg); return; } catch (e) {}
    }
    const box = document.getElementById("toast-box");
    if (!box) return;
    box.textContent = msg;
    box.classList.add("show");
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => box.classList.remove("show"), 2600);
  }

  // Core root-manager and UniMount directories (never flagged as orphans)
  const CORE_ADB_DIRS = {
    ksu: {
      name: "KernelSU Core Working Dir",
      role: "Core KernelSU binaries, busybox, and allowlist database (/data/adb/ksu)",
      systemCore: true
    },
    magisk: {
      name: "Magisk Core Working Dir",
      role: "Core Magisk binaries, busybox, and policy database (/data/adb/magisk)",
      systemCore: true
    },
    ap: {
      name: "APatch Core Working Dir",
      role: "Core APatch binaries and superkey/module state (/data/adb/ap)",
      systemCore: true
    },
    modules: {
      name: "Active Modules",
      role: "Installed root modules directory (/data/adb/modules)",
      systemCore: true
    },
    modules_update: {
      name: "Pending Module Updates",
      role: "Staged module updates awaiting reboot (/data/adb/modules_update)",
      systemCore: true
    },
    "post-fs-data.d": {
      name: "Global Early-Boot Scripts",
      role: "General post-fs-data boot scripts directory (/data/adb/post-fs-data.d)",
      systemCore: true
    },
    "post-mount.d": {
      name: "Global Post-Mount Scripts",
      role: "General post-mount boot scripts directory (/data/adb/post-mount.d)",
      systemCore: true
    },
    "service.d": {
      name: "Global Late-Start Scripts",
      role: "General late_start boot scripts directory (/data/adb/service.d)",
      systemCore: true
    },
    "boot-completed.d": {
      name: "Global Boot-Completed Scripts",
      role: "General boot-completed scripts directory (/data/adb/boot-completed.d)",
      systemCore: true
    },
    unimount: {
      name: "UniMount Config & Mirror",
      role: "UniMount whitelist, config.conf, and SELinux context state (/data/adb/unimount)",
      systemCore: true
    }
  };

  function normalizeKey(value) {
    return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  }

  function isSafeModuleId(id) {
    return typeof id === "string" && id.length > 0 && id !== "." && id !== ".." && /^[A-Za-z0-9._-]+$/.test(id);
  }

  function isSafeModulePath(modPath, modId) {
    if (!isSafeModuleId(modId) || typeof modPath !== "string") return false;
    return modPath === "/data/adb/modules/" + modId || modPath === "/data/adb/modules_update/" + modId;
  }

  function isSafeOrphanDirName(name) {
    if (!isSafeModuleId(name)) return false;
    if (Object.prototype.hasOwnProperty.call(CORE_ADB_DIRS, name)) return false;
    return true;
  }

  async function loadExternalDirCatalog(url) {
    try {
      const res = await fetch(url || "./known_dirs.json", { cache: "no-store" });
      if (!res.ok) return {};
      const parsed = await res.json();
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (e) {
      return {};
    }
  }

  function parseJsonObject(rawText) {
    const trimmed = String(rawText || "").trim();
    if (!trimmed) return {};
    try {
      const parsed = JSON.parse(trimmed);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (e) {
      return {};
    }
  }

  /**
   * Pure resolver for any /data/adb/<dirName> entry.
   * Priority: CORE_ADB_DIRS -> merged external/user catalog -> dynamic module.prop inference -> generic fallback.
   */
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
        (mod) =>
          catalogEntry.expectedModIds.includes(mod.id) ||
          expectedNorms.has(normalizeKey(mod.id))
      ) || null;
    }

    if (!matchedMod) {
      matchedMod = modList.find((mod) => {
        const normId = normalizeKey(mod.id);
        const normName = normalizeKey(mod.name);
        return normId === normDir || normName === normDir;
      }) || null;
    }

    if (!matchedMod && normDir.length >= 4) {
      matchedMod = modList.find((mod) => {
        const normId = normalizeKey(mod.id);
        const normName = normalizeKey(mod.name);
        return (
          (normId.length >= 4 && (normId.includes(normDir) || normDir.includes(normId))) ||
          (normName.length >= 4 && normName.includes(normDir))
        );
      }) || null;
    }

    if (catalogEntry) {
      const isCore = Boolean(catalogEntry.systemCore);
      return {
        name: catalogEntry.name || dirName,
        role: catalogEntry.role || ("Standalone /data/adb data directory (/data/adb/" + dirName + ")"),
        expectedModIds: Array.isArray(catalogEntry.expectedModIds) ? catalogEntry.expectedModIds : [dirName],
        systemCore: isCore,
        matchedModuleId: matchedMod ? matchedMod.id : null,
        isOrphan: !isCore && !matchedMod
      };
    }

    if (matchedMod) {
      return {
        name: matchedMod.name || matchedMod.id,
        role: (matchedMod.description || "Module runtime data directory") + " (/data/adb/" + dirName + ")",
        expectedModIds: [matchedMod.id],
        systemCore: false,
        matchedModuleId: matchedMod.id,
        inferred: true,
        isOrphan: false
      };
    }

    return {
      name: dirName,
      role: "Standalone /data/adb data directory (/data/adb/" + dirName + ")",
      expectedModIds: [dirName],
      systemCore: false,
      matchedModuleId: null,
      inferred: true,
      isOrphan: true
    };
  }

  function detectZygiskProvider(modules, adbDirs) {
    const modByNorm = (kw) => modules.find((m) => normalizeKey(m.id).includes(kw) || normalizeKey(m.name).includes(kw));
    const dirHas = (name) => adbDirs.some((d) => d.name === name);

    const zygiskNext = modByNorm("zygisknext") || modByNorm("zygisksu");
    if (zygiskNext || dirHas("zygisksu")) return zygiskNext ? zygiskNext.name : "Zygisk Next (zygisksu)";

    const rezygisk = modByNorm("rezygisk");
    if (rezygisk || dirHas("rezygisk")) return rezygisk ? rezygisk.name : "ReZygisk";

    const neozygisk = modByNorm("neozygisk");
    if (neozygisk) return neozygisk.name;

    return "Standard / Native";
  }

  const state = {
    bridgeOnline: false,
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

  // Single-pass shell scanner to gather accurate live filesystem telemetry
  const SCAN_SCRIPT = `
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
mkdir -p /data/adb/unimount
[ -f /data/adb/unimount/modules.txt ] || touch /data/adb/unimount/modules.txt
[ -f /data/adb/unimount/config.conf ] || printf "MOUNT_MODE=auto\nSELINUX_MIRROR=1\nDIR_MIRROR_INJECT=1\nSKIP_ZYGISK_ONLY=1\nLOG_VERBOSE=1\nBOOTLOOP_GUARD=1\nPROTECT_CRITICAL_PATHS=1\n" > /data/adb/unimount/config.conf

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

_active_count=0
_mirror_count=0
if [ -n "$_ledger_file" ] && [ -s "$_ledger_file" ]; then
  _active_count=$(wc -l < "$_ledger_file" 2>/dev/null | tr -d ' ')
  _mirror_count=$(grep -c '|DIR_MIRROR$' "$_ledger_file" 2>/dev/null || echo 0)
else
  _active_count=$(grep -Ec '/data/adb/modules/|/data/adb/unimount/mirror/merged' /proc/mounts 2>/dev/null || echo 0)
  _mirror_count=$(grep -c '/data/adb/unimount/mirror/merged' /proc/mounts 2>/dev/null || echo 0)
fi

_guard_bypassed=0
[ -n "$_boot_id" ] && [ "$_bypass_boot" = "$_boot_id" ] && _guard_bypassed=1

echo "===SYS==="
echo "MODEL=$(getprop ro.product.model) ($(getprop ro.build.display.id))"
echo "KERNEL=$(uname -r)"
echo "SELINUX=$(getenforce 2>/dev/null || echo Enforcing)"
echo "KNOX=$(getprop ro.boot.warranty_bit 2>/dev/null || echo 0)"
echo "VBKNOX=$(getprop ro.warranty_bit 2>/dev/null || echo 0)"
echo "DISK=$(df -h /data/adb 2>/dev/null | tail -n 1 | awk '{print $3 " / " $2 " (" $5 ")"}')"
echo "METAMOD=$(readlink /data/adb/metamodule 2>/dev/null || echo 'None')"
echo "KSUD=$(/data/adb/ksud --version 2>/dev/null || echo 'Present')"
echo "BINDCOUNT=$_active_count"
echo "MIRRORCOUNT=$_mirror_count"
echo "LEDGERSRC=$_ledger_src"
echo "BOOTFAIL=$(cat /data/adb/unimount/.boot_fail_count 2>/dev/null || echo 0)"
echo "GUARDBYPASSED=$_guard_bypassed"
echo "SAFEMODE=$(getprop persist.sys.safemode 2>/dev/null || echo 0)"

echo "===ACTIVE_MOUNTS==="
[ -n "$_ledger_file" ] && [ -s "$_ledger_file" ] && cat "$_ledger_file" 2>/dev/null

echo "===CONFIG==="
cat /data/adb/unimount/config.conf 2>/dev/null

echo "===WHITELIST==="
cat /data/adb/unimount/modules.txt 2>/dev/null

echo "===USER_CATALOG==="
[ -f /data/adb/unimount/known_dirs.json ] && cat /data/adb/unimount/known_dirs.json 2>/dev/null

echo "===MODULES==="
for base in /data/adb/modules /data/adb/modules_update; do
  [ -d "$base" ] || continue
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    mod_id=$(basename "$d")
    echo "---MOD:$base:$mod_id---"
    [ -f "$d/module.prop" ] && cat "$d/module.prop"
    overlays=""
    for p in system vendor product system_ext odm prism optics; do
      [ -d "$d/$p" ] && overlays="$overlays/$p "
    done
    echo "__OVERLAYS=$overlays"
    [ -f "$d/disable" ] && echo "__DISABLED=1"
    [ -f "$d/remove" ] && echo "__REMOVE=1"
    [ -f "$d/skip_mount" ] && echo "__SKIP_MOUNT=1"
    [ -f "$d/skip_unimount" ] && echo "__SKIP_UNIMOUNT=1"
    if ([ -n "$_ledger_file" ] && [ -s "$_ledger_file" ] && awk -F'|' -v m="$mod_id" 'index("," $1 ",", "," m ",") > 0 { found=1; exit } END { exit !found }' "$_ledger_file" 2>/dev/null) || grep -Fq "$d/" /proc/mounts 2>/dev/null; then
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
    const lines = raw.split(/\r?\n/);
    for (const line of lines) {
      if (line.startsWith("===") && line.endsWith("===")) {
        current = line.slice(3, -3);
        sections[current] = [];
      } else if (current) {
        sections[current].push(line);
      }
    }

    // 1. Parse System Info
    const sys = {};
    for (const l of (sections.SYS || [])) {
      const idx = l.indexOf("=");
      if (idx > 0) sys[l.slice(0, idx)] = l.slice(idx + 1).trim();
    }
    state.ledgerSource = sys.LEDGERSRC || "none";

    // 2. Parse Active Mounts Ledger
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

    // 3. Parse Config
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

    // 4. Parse Whitelist & Optional User Directory Catalog
    const whitelist = new Set(
      (sections.WHITELIST || []).map((x) => x.trim()).filter(Boolean)
    );
    const userCatalog = parseJsonObject((sections.USER_CATALOG || []).join("\n"));
    state.externalCatalog = Object.assign({}, state.bundledCatalog, userCatalog);

    // 5. Parse Modules from /data/adb/modules and /data/adb/modules_update
    const modMap = new Map();
    let curMod = null;
    let hasUpdatePending = false;

    for (const l of (sections.MODULES || [])) {
      if (l.startsWith("---MOD:") && l.endsWith("---")) {
        const parts = l.slice(7, -3).split(":");
        const baseDir = parts[0];
        const modId = parts[1];
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

    // 6. Parse /data/adb directories & dynamically resolve against installed modules
    const installedModulesList = Array.from(modMap.values());
    const adbDirs = [];
    for (const l of (sections.ADB_DIRS || [])) {
      const [kind, name, target] = l.split("|");
      if (!name || name === "modules" || name === "modules_update") continue;

      const meta =
        kind === "DIR"
          ? resolveAdbDirMeta(name, installedModulesList, state.externalCatalog)
          : null;
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

    updateDashboardUI(sys);
    updateConfigUI();
    renderModules();
    renderActiveMounts();
    renderHygiene();
  }

  function updateDashboardUI(sys) {
    const dot = document.getElementById("bridge-dot");
    const kpiBridge = document.getElementById("kpi-bridge");
    if (state.bridgeOnline) {
      dot.className = "status-dot online";
      kpiBridge.textContent = "Connected (UID 0)";
      kpiBridge.className = "kpi-val accent-green";
    } else {
      dot.className = "status-dot offline";
      kpiBridge.textContent = "Bridge Offline";
      kpiBridge.className = "kpi-val accent-red";
    }

    document.getElementById("kpi-ksud").textContent = "ksud: " + (sys.KSUD || "offline");
    const knoxBit = (sys.KNOX === "0" || !sys.KNOX) ? "0x0" : sys.KNOX;
    document.getElementById("kpi-knox").textContent = knoxBit;
    document.getElementById("kpi-selinux").textContent = sys.SELINUX || "--";
    document.getElementById("kpi-mounts").textContent = sys.BINDCOUNT || String(state.activeMounts.length);
    document.getElementById("kpi-metamod").textContent = "link: " + (sys.METAMOD || "None");

    document.getElementById("sys-device").textContent = sys.MODEL || "--";
    document.getElementById("sys-kernel").textContent = sys.KERNEL || "--";
    document.getElementById("sys-disk").textContent = sys.DISK || "--";
    document.getElementById("sys-symlink").textContent = sys.METAMOD || "--";
    document.getElementById("sys-zygisk").textContent = detectZygiskProvider(state.modules, state.adbDirs);

    const dirMirrorsEl = document.getElementById("sys-dir-mirrors");
    if (dirMirrorsEl) dirMirrorsEl.textContent = sys.MIRRORCOUNT || "0";

    let guardLabel = state.config.BOOTLOOP_GUARD === "0"
      ? "Disabled"
      : ("Armed (" + state.bootFailCount + "/2 fails)");
    if (sys.SAFEMODE === "1") guardLabel = "Safe Mode Bypass Active";
    else if (state.guardBypassed) guardLabel = "Bypassed (" + state.bootFailCount + " fails) — Reset Needed";
    document.getElementById("sys-guard").textContent = state.bridgeOnline ? guardLabel : "--";

    const guardBanner = document.getElementById("bootloop-banner");
    guardBanner.style.display = state.bridgeOnline && state.guardBypassed ? "flex" : "none";

    const syncBtn = document.getElementById("btn-sync-updates");
    const banner = document.getElementById("pending-banner");
    if (state.bridgeOnline && state.pendingUpdates) {
      syncBtn.style.display = "inline-flex";
      banner.style.display = "flex";
    } else {
      syncBtn.style.display = "none";
      banner.style.display = "none";
    }

    const unmountBtn = document.getElementById("btn-emergency-unmount");
    if (unmountBtn) {
      unmountBtn.disabled = !state.bridgeOnline;
    }
    const runBtn = document.getElementById("btn-run-metamount");
    if (runBtn) {
      runBtn.disabled = !state.bridgeOnline;
    }
  }

  function renderActiveMounts() {
    const listEl = document.getElementById("active-mounts-list");
    const pillEl = document.getElementById("active-mounts-pill");
    const srcBadge = document.getElementById("ledger-source-badge");
    const searchWrap = document.getElementById("mount-search-wrap");
    if (!listEl) return;

    const total = state.activeMounts.length;
    if (pillEl) pillEl.textContent = total + " active";
    if (srcBadge) {
      srcBadge.textContent = state.ledgerSource && state.ledgerSource !== "none"
        ? state.ledgerSource
        : "ledger: idle";
    }

    if (!state.bridgeOnline) {
      if (searchWrap) searchWrap.style.display = "none";
      listEl.innerHTML = `<div class="empty-state">Connect KSU root bridge to inspect <code>/dev/unimount_active_mounts</code>.</div>`;
      return;
    }

    if (searchWrap) {
      searchWrap.style.display = total > 4 ? "block" : "none";
    }

    if (total === 0) {
      listEl.innerHTML = `<div class="empty-state">No active mounts recorded in <code>/dev/unimount_active_mounts</code> for this boot.</div>`;
      return;
    }

    const q = state.mountSearch.toLowerCase();
    const filtered = q
      ? state.activeMounts.filter((item) =>
          (item.modsRaw + " " + item.dst + " " + item.type + " " + item.src).toLowerCase().includes(q)
        )
      : state.activeMounts;

    if (filtered.length === 0) {
      listEl.innerHTML = `<div class="empty-state">No active mounts match "${escapeHtml(state.mountSearch)}".</div>`;
      return;
    }

    listEl.innerHTML = filtered.map((item) => {
      const isMirror = item.type === "DIR_MIRROR";
      const typeClass = isMirror ? "indigo" : "blue";
      const modBadges = item.mods.map((m) => `<span class="badge green">${escapeHtml(m)}</span>`).join("");
      return `
        <div class="mount-row">
          <div class="mount-row-head">
            <div class="badge-row" style="margin-bottom:0;">
              <span class="badge ${typeClass}">${escapeHtml(item.type)}</span>
              ${modBadges}
            </div>
          </div>
          <div class="mount-target">${escapeHtml(item.dst)}</div>
          ${item.src ? `<div class="mount-source">&larr; ${escapeHtml(item.src)}</div>` : ""}
        </div>
      `;
    }).join("");
  }

  function updateConfigUI() {
    document.getElementById("cfg-manual-mode").checked = state.config.MOUNT_MODE === "manual";
    document.getElementById("cfg-selinux-mirror").checked = state.config.SELINUX_MIRROR !== "0";
    const dirMirrorEl = document.getElementById("cfg-dir-mirror");
    if (dirMirrorEl) dirMirrorEl.checked = state.config.DIR_MIRROR_INJECT !== "0";
    const skipZygiskEl = document.getElementById("cfg-skip-zygisk");
    if (skipZygiskEl) skipZygiskEl.checked = state.config.SKIP_ZYGISK_ONLY !== "0";
    document.getElementById("cfg-bootloop-guard").checked = state.config.BOOTLOOP_GUARD !== "0";
    document.getElementById("cfg-protect-critical").checked = state.config.PROTECT_CRITICAL_PATHS !== "0";
    document.getElementById("cfg-log-verbose").checked = state.config.LOG_VERBOSE !== "0";
  }

  function renderModules() {
    const listEl = document.getElementById("module-list");
    const countEl = document.getElementById("nav-mod-count");
    countEl.textContent = String(state.modules.length);

    if (!state.bridgeOnline) {
      listEl.innerHTML = `<div class="empty-state">
        <strong>KernelSU JavaScript Bridge Not Detected</strong><br/>
        Open this page directly inside KernelSU / KernelSU-Next Manager &rarr; Modules &rarr; UniMount &rarr; WebUI.<br/>
        (Zero fake/mock modules are rendered when root bridge is offline.)
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
        badges.push(`<span class="badge amber">Standalone /data/adb Folder</span>`);
      } else if (hasOverlay) {
        badges.push(`<span class="badge blue">Overlays: ${escapeHtml(m.overlays.join(", "))}</span>`);
      } else {
        badges.push(`<span class="badge">Zygisk / Service-Only</span>`);
      }

      if (m.mounted) {
        const details = [];
        if (m.mountMirrors > 0) details.push(m.mountMirrors + " mirror" + (m.mountMirrors > 1 ? "s" : ""));
        if (m.mountBinds > 0) details.push(m.mountBinds + " bind" + (m.mountBinds > 1 ? "s" : ""));
        const suffix = details.length > 0 ? " · " + details.join(", ") : " (SELinux Mirrored)";
        badges.push(`<span class="badge green">Mounted${escapeHtml(suffix)}</span>`);
      }
      if (m.isUpdatePending) {
        badges.push(`<span class="badge amber">Pending in modules_update</span>`);
      }
      if (m.disabled) {
        badges.push(`<span class="badge red">Disabled</span>`);
      }
      if (m.skipUnimount || m.skipMount) {
        badges.push(`<span class="badge amber">Excluded</span>`);
      }
      if (m.isOrphanCandidate) {
        badges.push(`<span class="badge red">Orphan Candidate</span>`);
      }

      const canDelete = m.sourceType === "standalone" && m.isOrphanCandidate && isSafeOrphanDirName(m.id);
      const controlsHtml = m.sourceType === "module" ? `
        <div class="mod-controls">
          <label class="toggle-item">
            <span>Manual Whitelist</span>
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
        </div>
      ` : `
        <div class="mod-controls">
          <span class="subtitle">Located at <code>${escapeHtml(m.path)}</code></span>
          ${canDelete ? `<button type="button" class="m3-btn m3-btn-error-tonal m3-btn-sm" data-delete-dir="${escapeAttr(m.id)}">Remove /data/adb/${escapeHtml(m.id)}</button>` : ""}
        </div>
      `;

      return `
        <article class="mod-card ${hasOverlay ? "has-overlay" : ""} ${m.isOrphanCandidate ? "is-orphan" : ""}">
          <div class="mod-top">
            <div class="mod-title-group">
              <span class="mod-name">${escapeHtml(m.name)}</span>
              <span class="mod-id">${escapeHtml(m.id)}</span>
              ${m.version ? `<span class="mod-ver">${escapeHtml(m.version)}</span>` : ""}
            </div>
          </div>
          <div class="badge-row">${badges.join("")}</div>
          <div class="mod-desc">${escapeHtml(m.description || "Installed module package")}</div>
          <div class="mod-path">${escapeHtml(m.path)}</div>
          ${controlsHtml}
        </article>
      `;
    }).join("");
  }

  function renderHygiene() {
    const el = document.getElementById("hygiene-list");
    if (!state.bridgeOnline) {
      el.innerHTML = `<div class="empty-state">Connect KSU bridge to inspect <code>/data/adb</code> directories.</div>`;
      return;
    }

    const items = state.adbDirs.filter((d) => d.kind === "DIR");
    if (items.length === 0) {
      el.innerHTML = `<div class="empty-state">No extra subdirectories found in <code>/data/adb</code>.</div>`;
      return;
    }

    el.innerHTML = items.map((d) => {
      const meta = d.meta || resolveAdbDirMeta(d.name, state.modules, state.externalCatalog);
      const isCore = Boolean(meta.systemCore);
      const isOrphan = !isCore && Boolean(meta.isOrphan);
      const canDelete = isOrphan && isSafeOrphanDirName(d.name);

      let rightControl = `<span class="badge green">Active</span>`;
      if (isCore) {
        rightControl = `<span class="badge indigo">System Core</span>`;
      } else if (canDelete) {
        rightControl = `<button type="button" class="m3-btn m3-btn-error-tonal m3-btn-sm" data-delete-dir="${escapeAttr(d.name)}">Remove Folder</button>`;
      }

      return `
        <div class="hygiene-item">
          <div>
            <div class="setting-title"><code>/data/adb/${escapeHtml(d.name)}</code> ${isOrphan ? `<span class="badge red">Orphan Candidate</span>` : ""}</div>
            <div class="setting-desc">${escapeHtml(meta.role)}</div>
          </div>
          ${rightControl}
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
      updateDashboardUI({});
      renderModules();
      renderActiveMounts();
      renderHygiene();
    }
  }

  async function loadLogs(viewMode) {
    const mode = viewMode || state.logView || "mountlog";
    state.logView = mode;
    const logEl = document.getElementById("log-output");
    if (!logEl) return;

    if (!state.bridgeOnline) {
      logEl.textContent = "KernelSU root bridge offline. Open UniMount WebUI inside KernelSU Manager to inspect live logs.";
      return;
    }

    if (mode === "procmounts") {
      const res = await ksuExec("grep -E 'adb|overlay|ksu|unimount|system|vendor|prism' /proc/mounts 2>/dev/null || cat /proc/mounts");
      logEl.textContent = res.stdout || "No matching mount entries found.";
    } else if (mode === "ledger") {
      const res = await ksuExec("if [ -s /dev/unimount_active_mounts ]; then echo '# Source: /dev/unimount_active_mounts'; cat /dev/unimount_active_mounts; elif [ -s /data/adb/unimount/active_mounts.list ]; then echo '# Source: /data/adb/unimount/active_mounts.list'; cat /data/adb/unimount/active_mounts.list; else echo 'Active mount ledger is empty (0 mounts active).'; fi");
      logEl.textContent = res.stdout || "Active mount ledger is empty.";
    } else {
      const res = await ksuExec("cat /data/adb/unimount/mount.log 2>/dev/null || echo 'mount.log is empty. Tap [Run metamount.sh Now] on Telemetry tab to populate.'");
      logEl.textContent = res.stdout || "mount.log is empty.";
    }
  }

  async function saveConfig() {
    const mode = document.getElementById("cfg-manual-mode").checked ? "manual" : "auto";
    const selinux = document.getElementById("cfg-selinux-mirror").checked ? "1" : "0";
    const dirMirrorEl = document.getElementById("cfg-dir-mirror");
    const dirMirror = (!dirMirrorEl || dirMirrorEl.checked) ? "1" : "0";
    const skipZygiskEl = document.getElementById("cfg-skip-zygisk");
    const skipZygisk = (!skipZygiskEl || skipZygiskEl.checked) ? "1" : "0";
    const verbose = document.getElementById("cfg-log-verbose").checked ? "1" : "0";
    const guard = document.getElementById("cfg-bootloop-guard").checked ? "1" : "0";
    const critical = document.getElementById("cfg-protect-critical").checked ? "1" : "0";

    const cmd = `mkdir -p /data/adb/unimount && printf "MOUNT_MODE=${mode}\nSELINUX_MIRROR=${selinux}\nDIR_MIRROR_INJECT=${dirMirror}\nSKIP_ZYGISK_ONLY=${skipZygisk}\nLOG_VERBOSE=${verbose}\nBOOTLOOP_GUARD=${guard}\nPROTECT_CRITICAL_PATHS=${critical}\n" > /data/adb/unimount/config.conf`;
    await ksuExec(cmd);
    showToast("Saved /data/adb/unimount/config.conf");
    await refreshAll();
  }

  async function copyText(text) {
    if (!text) return false;
    try {
      if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (e) {}
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
    } catch (e) {
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

  // Event Wiring
  document.addEventListener("DOMContentLoaded", async () => {
    state.bundledCatalog = await loadExternalDirCatalog("./known_dirs.json");

    // Tab Switching
    document.querySelectorAll(".nav-tab").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".nav-tab").forEach((b) => {
          b.classList.remove("active");
          b.setAttribute("aria-selected", "false");
        });
        document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
        btn.classList.add("active");
        btn.setAttribute("aria-selected", "true");
        const target = btn.getAttribute("data-tab");
        const panel = document.getElementById("panel-" + target);
        if (panel) panel.classList.add("active");
        if (target === "logs") loadLogs(state.logView);
      });
    });

    // Filter Chips
    document.querySelectorAll("#filter-chips .chip").forEach((chip) => {
      chip.addEventListener("click", () => {
        document.querySelectorAll("#filter-chips .chip").forEach((c) => c.classList.remove("active"));
        chip.classList.add("active");
        state.filter = chip.getAttribute("data-filter");
        renderModules();
      });
    });

    // Search Input + Clear Button
    const searchInput = document.getElementById("module-search");
    const clearSearchBtn = document.getElementById("btn-clear-search");
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

    // Active Mounts Search Filter
    const mountSearchInput = document.getElementById("mount-search");
    if (mountSearchInput) {
      mountSearchInput.addEventListener("input", (e) => {
        state.mountSearch = e.target.value.trim();
        renderActiveMounts();
      });
    }

    // Rescan Button
    document.getElementById("btn-refresh").addEventListener("click", async () => {
      showToast("Rescanning /data/adb...");
      await refreshAll();
    });

    // Reset Bootloop Guard Button
    document.getElementById("btn-reset-guard").addEventListener("click", async () => {
      await ksuExec("echo 0 > /data/adb/unimount/.boot_fail_count && rm -f /data/adb/unimount/.bypass_boot_id");
      showToast("Bootloop guard counter reset");
      await refreshAll();
    });

    // Merge modules_update into modules
    const mergeUpdates = async () => {
      const cmd = `
        mkdir -p /data/adb/modules
        for d in /data/adb/modules_update/*; do
          [ -d "$d" ] || continue
          id=$(basename "$d")
          rm -rf "/data/adb/modules/$id"
          mv "$d" "/data/adb/modules/$id"
        done
      `;
      await ksuExec(cmd, 15000);
      showToast("Merged modules_update into /data/adb/modules");
      await refreshAll();
    };
    document.getElementById("btn-merge-now").addEventListener("click", mergeUpdates);
    document.getElementById("btn-sync-updates").addEventListener("click", mergeUpdates);

    // Run metamount.sh immediately
    document.getElementById("btn-run-metamount").addEventListener("click", async () => {
      showToast("Executing metamount.sh...");
      await ksuExec("sh /data/adb/modules/unimount/metamount.sh 2>&1 || sh /data/adb/metamodule/metamount.sh 2>&1", 20000);
      showToast("metamount.sh completed");
      await refreshAll();
    });

    // Emergency Unmount All (Native Material 3 <dialog> Confirmation)
    const unmountDialog = document.getElementById("unmount-dialog");
    const unmountDesc = document.getElementById("unmount-dialog-desc");
    const openUnmountBtn = document.getElementById("btn-emergency-unmount");
    const cancelUnmountBtn = document.getElementById("btn-cancel-unmount");
    const confirmUnmountBtn = document.getElementById("btn-confirm-unmount");

    const runEmergencyUnmount = async () => {
      showToast("Detaching all UniMount overlays...");
      const res = await ksuExec(
        "sh /data/adb/modules/unimount/metamount.sh --unmount-all 2>&1 || sh /data/adb/metamodule/metamount.sh --unmount-all 2>&1",
        15000
      );
      const summary = (res.stdout || "").trim().split(/\r?\n/).pop();
      showToast(summary || "Emergency unmount completed");
      await refreshAll();
      if (state.logView === "ledger" || state.logView === "mountlog") {
        loadLogs(state.logView);
      }
    };

    if (openUnmountBtn) {
      openUnmountBtn.addEventListener("click", () => {
        const mirrors = state.activeMounts.filter((m) => m.type === "DIR_MIRROR").length;
        const binds = state.activeMounts.length - mirrors;
        if (unmountDesc) {
          unmountDesc.innerHTML =
            `Detach <strong>${binds}</strong> file bind(s) and <strong>${mirrors}</strong> directory mirror(s) currently tracked in <code>/dev/unimount_active_mounts</code> without rebooting. Standalone non-UniMount daemons are not touched.`;
        }
        if (unmountDialog && typeof unmountDialog.showModal === "function") {
          unmountDialog.showModal();
        } else {
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

    // Config switches (all 7 config.conf policy flags)
    [
      "cfg-manual-mode",
      "cfg-selinux-mirror",
      "cfg-dir-mirror",
      "cfg-skip-zygisk",
      "cfg-bootloop-guard",
      "cfg-protect-critical",
      "cfg-log-verbose"
    ].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.addEventListener("change", saveConfig);
    });

    // Delegated clicks for Module Toggles (with strict ID & path validation)
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
          await ksuExec(`grep -Fxq "${modId}" /data/adb/unimount/modules.txt 2>/dev/null || echo "${modId}" >> /data/adb/unimount/modules.txt`);
          showToast(`Added ${modId} to modules.txt`);
        } else {
          await ksuExec(`grep -Fxv "${modId}" /data/adb/unimount/modules.txt > /data/adb/unimount/.modules.tmp 2>/dev/null || true; mv /data/adb/unimount/.modules.tmp /data/adb/unimount/modules.txt`);
          showToast(`Removed ${modId} from modules.txt`);
        }
      } else if (action === "skip_unimount") {
        if (!isSafeModulePath(modPath, modId)) {
          showToast("Blocked invalid module path");
          return;
        }
        if (t.checked) {
          await ksuExec(`touch "${modPath}/skip_unimount"`);
          showToast(`Created skip_unimount for ${modId}`);
        } else {
          await ksuExec(`rm -f "${modPath}/skip_unimount"`);
          showToast(`Removed skip_unimount for ${modId}`);
        }
      } else if (action === "skip_mount") {
        if (!isSafeModulePath(modPath, modId)) {
          showToast("Blocked invalid module path");
          return;
        }
        if (t.checked) {
          await ksuExec(`touch "${modPath}/skip_mount"`);
          showToast(`Created skip_mount for ${modId}`);
        } else {
          await ksuExec(`rm -f "${modPath}/skip_mount"`);
          showToast(`Removed skip_mount for ${modId}`);
        }
      }
      await refreshAll();
    });

    // Two-tap safe orphan directory removal (works cleanly inside Android WebViews)
    document.body.addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-delete-dir]");
      if (!btn) return;
      const dirName = btn.getAttribute("data-delete-dir");
      if (!isSafeOrphanDirName(dirName)) {
        showToast("Blocked deletion of protected or invalid directory");
        return;
      }

      if (btn.dataset.armed !== "1") {
        btn.dataset.armed = "1";
        const origText = btn.textContent;
        btn.textContent = "Tap Again to Delete";
        setTimeout(() => {
          if (btn.isConnected && btn.dataset.armed === "1") {
            btn.dataset.armed = "0";
            btn.textContent = origText;
          }
        }, 4000);
        return;
      }

      await ksuExec(`rm -rf "/data/adb/${dirName}"`);
      showToast(`Deleted orphaned /data/adb/${dirName}`);
      await refreshAll();
    });

    // Log segmented tabs & action buttons
    document.querySelectorAll("#log-view-tabs .seg-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll("#log-view-tabs .seg-btn").forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        loadLogs(btn.getAttribute("data-log-view"));
      });
    });

    const copyLogBtn = document.getElementById("btn-copy-log");
    if (copyLogBtn) {
      copyLogBtn.addEventListener("click", async () => {
        const logEl = document.getElementById("log-output");
        const ok = await copyText(logEl ? logEl.textContent : "");
        showToast(ok ? "Copied telemetry to clipboard" : "Copy unavailable in this WebView");
      });
    }

    document.getElementById("btn-clear-log").addEventListener("click", async () => {
      await ksuExec("echo '=== Log Cleared ===' > /data/adb/unimount/mount.log");
      document.querySelectorAll("#log-view-tabs .seg-btn").forEach((b) => {
        b.classList.toggle("active", b.getAttribute("data-log-view") === "mountlog");
      });
      loadLogs("mountlog");
    });

    await refreshAll();
  });
})();
