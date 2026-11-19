(function () {
  "use strict";

  let cbSeq = 0;

  // Dual-mode KernelSU Root Shell Bridge (supports 3-arg callback, 2-arg callback, and sync return)
  function ksuExec(command) {
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
      }, 6000);
    });
  }

  function showToast(msg) {
    if (typeof window.ksu !== "undefined" && typeof window.ksu.toast === "function") {
      try { window.ksu.toast(msg); return; } catch (e) {}
    }
    const box = document.getElementById("toast-box");
    if (!box) return;
    box.textContent = msg;
    box.classList.add("show");
    setTimeout(() => box.classList.remove("show"), 2400);
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

  function isSafeOrphanDirName(name) {
    if (typeof name !== "string" || !name || name === "." || name === "..") return false;
    if (!/^[A-Za-z0-9._-]+$/.test(name)) return false;
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
    modules: [],
    adbDirs: [],
    bundledCatalog: {},
    externalCatalog: {},
    pendingUpdates: false,
    config: {
      MOUNT_MODE: "auto",
      SELINUX_MIRROR: "1",
      LOG_VERBOSE: "1"
    }
  };

  // Single-pass shell scanner to gather accurate live filesystem telemetry
  const SCAN_SCRIPT = `
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:$PATH"
mkdir -p /data/adb/unimount
[ -f /data/adb/unimount/modules.txt ] || touch /data/adb/unimount/modules.txt
[ -f /data/adb/unimount/config.conf ] || printf "MOUNT_MODE=auto\nSELINUX_MIRROR=1\nLOG_VERBOSE=1\n" > /data/adb/unimount/config.conf

echo "===SYS==="
echo "MODEL=$(getprop ro.product.model) ($(getprop ro.build.display.id))"
echo "KERNEL=$(uname -r)"
echo "SELINUX=$(getenforce 2>/dev/null || echo Enforcing)"
echo "KNOX=$(getprop ro.boot.warranty_bit 2>/dev/null || echo 0)"
echo "VBKNOX=$(getprop ro.warranty_bit 2>/dev/null || echo 0)"
echo "DISK=$(df -h /data/adb 2>/dev/null | tail -n 1 | awk '{print $3 " / " $2 " (" $5 ")"}')"
echo "METAMOD=$(readlink /data/adb/metamodule 2>/dev/null || echo 'None')"
echo "KSUD=$(/data/adb/ksud --version 2>/dev/null || echo 'Present')"
echo "BINDCOUNT=$(grep -c '/data/adb/modules' /proc/mounts 2>/dev/null || echo 0)"

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
    if grep -q "$d" /proc/mounts 2>/dev/null; then
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

    // 2. Parse Config
    const cfg = { MOUNT_MODE: "auto", SELINUX_MIRROR: "1", LOG_VERBOSE: "1" };
    for (const l of (sections.CONFIG || [])) {
      const idx = l.indexOf("=");
      if (idx > 0) cfg[l.slice(0, idx).trim()] = l.slice(idx + 1).trim();
    }
    state.config = cfg;

    // 3. Parse Whitelist & Optional User Directory Catalog
    const whitelist = new Set(
      (sections.WHITELIST || []).map((x) => x.trim()).filter(Boolean)
    );
    const userCatalog = parseJsonObject((sections.USER_CATALOG || []).join("\n"));
    state.externalCatalog = Object.assign({}, state.bundledCatalog, userCatalog);

    // 4. Parse Modules from /data/adb/modules and /data/adb/modules_update
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
          mounted: false,
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

    // 5. Parse /data/adb directories & dynamically resolve against installed modules
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
      kpiBridge.className = "kpi-val";
    }

    document.getElementById("kpi-ksud").textContent = "ksud: " + (sys.KSUD || "active");
    const knoxBit = (sys.KNOX === "0" || !sys.KNOX) ? "0x0" : sys.KNOX;
    document.getElementById("kpi-knox").textContent = knoxBit;
    document.getElementById("kpi-selinux").textContent = sys.SELINUX || "Enforcing";
    document.getElementById("kpi-mounts").textContent = sys.BINDCOUNT || "0";
    document.getElementById("kpi-metamod").textContent = "link: " + (sys.METAMOD || "None");

    document.getElementById("sys-device").textContent = sys.MODEL || "--";
    document.getElementById("sys-kernel").textContent = sys.KERNEL || "--";
    document.getElementById("sys-disk").textContent = sys.DISK || "--";
    document.getElementById("sys-symlink").textContent = sys.METAMOD || "--";
    document.getElementById("sys-zygisk").textContent = detectZygiskProvider(state.modules, state.adbDirs);

    const syncBtn = document.getElementById("btn-sync-updates");
    const banner = document.getElementById("pending-banner");
    if (state.pendingUpdates) {
      syncBtn.style.display = "inline-block";
      banner.style.display = "flex";
    } else {
      syncBtn.style.display = "none";
      banner.style.display = "none";
    }
  }

  function updateConfigUI() {
    document.getElementById("cfg-manual-mode").checked = state.config.MOUNT_MODE === "manual";
    document.getElementById("cfg-selinux-mirror").checked = state.config.SELINUX_MIRROR !== "0";
    document.getElementById("cfg-log-verbose").checked = state.config.LOG_VERBOSE !== "0";
  }

  function renderModules() {
    const listEl = document.getElementById("module-list");
    const countEl = document.getElementById("nav-mod-count");
    countEl.textContent = String(state.modules.length);

    if (!state.bridgeOnline) {
      listEl.innerHTML = `<div class="empty-state">
        <strong>KernelSU JavaScript Bridge Not Detected</strong><br/>
        Open this page directly inside KernelSU-Next Manager &rarr; Modules &rarr; UniMount &rarr; WebUI.<br/>
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
        badges.push(`<span class="badge">Zygisk / Service-Only (No /system overlay)</span>`);
      }

      if (m.mounted) {
        badges.push(`<span class="badge green">Mounted (SELinux Mirrored)</span>`);
      }
      if (m.isUpdatePending) {
        badges.push(`<span class="badge amber">Pending in modules_update</span>`);
      }
      if (m.disabled) {
        badges.push(`<span class="badge red">Disabled</span>`);
      }
      if (m.skipUnimount || m.skipMount) {
        badges.push(`<span class="badge amber">Excluded (skip_unimount)</span>`);
      }
      if (m.isOrphanCandidate) {
        badges.push(`<span class="badge red">Orphan Candidate (No Matching Module)</span>`);
      }

      const canDelete = m.sourceType === "standalone" && m.isOrphanCandidate && isSafeOrphanDirName(m.id);
      const controlsHtml = m.sourceType === "module" ? `
        <div class="mod-controls">
          <label class="toggle-item">
            <span>Manual Whitelist</span>
            <span class="switch">
              <input type="checkbox" data-action="whitelist" data-id="${escapeAttr(m.id)}" ${m.whitelisted ? "checked" : ""} />
              <span class="slider"></span>
            </span>
          </label>
          <label class="toggle-item">
            <span>skip_unimount</span>
            <span class="switch">
              <input type="checkbox" data-action="skip_unimount" data-id="${escapeAttr(m.id)}" data-path="${escapeAttr(m.path)}" ${m.skipUnimount ? "checked" : ""} />
              <span class="slider"></span>
            </span>
          </label>
          <label class="toggle-item">
            <span>skip_mount</span>
            <span class="switch">
              <input type="checkbox" data-action="skip_mount" data-id="${escapeAttr(m.id)}" data-path="${escapeAttr(m.path)}" ${m.skipMount ? "checked" : ""} />
              <span class="slider"></span>
            </span>
          </label>
        </div>
      ` : `
        <div class="mod-controls">
          <span class="subtitle">Located at <code>${escapeHtml(m.path)}</code></span>
          ${canDelete ? `<button class="btn-danger-sm" data-delete-dir="${escapeAttr(m.id)}">Remove /data/adb/${escapeHtml(m.id)}</button>` : ""}
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
        rightControl = `<span class="badge blue">System Core</span>`;
      } else if (canDelete) {
        rightControl = `<button class="btn-danger-sm" data-delete-dir="${escapeAttr(d.name)}">Remove Folder</button>`;
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
      updateDashboardUI({});
      renderModules();
      renderHygiene();
    }
  }

  async function loadLogs(procMountsOnly) {
    const logEl = document.getElementById("log-output");
    if (procMountsOnly) {
      const res = await ksuExec("grep -E 'adb|overlay|ksu|system|vendor|prism' /proc/mounts 2>/dev/null || cat /proc/mounts");
      logEl.textContent = res.stdout || "No matching mount entries found.";
    } else {
      const res = await ksuExec("cat /data/adb/unimount/mount.log 2>/dev/null || echo 'mount.log is empty. Tap [Run metamount.sh Now] on Telemetry tab to populate.'");
      logEl.textContent = res.stdout;
    }
  }

  async function saveConfig() {
    const mode = document.getElementById("cfg-manual-mode").checked ? "manual" : "auto";
    const selinux = document.getElementById("cfg-selinux-mirror").checked ? "1" : "0";
    const verbose = document.getElementById("cfg-log-verbose").checked ? "1" : "0";

    const cmd = `mkdir -p /data/adb/unimount && printf "MOUNT_MODE=${mode}\nSELINUX_MIRROR=${selinux}\nLOG_VERBOSE=${verbose}\n" > /data/adb/unimount/config.conf`;
    await ksuExec(cmd);
    showToast("Saved /data/adb/unimount/config.conf");
    await refreshAll();
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
        document.querySelectorAll(".nav-tab").forEach((b) => b.classList.remove("active"));
        document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
        btn.classList.add("active");
        const target = btn.getAttribute("data-tab");
        document.getElementById("panel-" + target).classList.add("active");
        if (target === "logs") loadLogs(false);
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

    // Search Input
    document.getElementById("module-search").addEventListener("input", (e) => {
      state.search = e.target.value.trim();
      renderModules();
    });

    // Rescan Button
    document.getElementById("btn-refresh").addEventListener("click", async () => {
      showToast("Rescanning /data/adb...");
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
      await ksuExec(cmd);
      showToast("Merged modules_update into /data/adb/modules");
      await refreshAll();
    };
    document.getElementById("btn-merge-now").addEventListener("click", mergeUpdates);
    document.getElementById("btn-sync-updates").addEventListener("click", mergeUpdates);

    // Run metamount.sh immediately
    document.getElementById("btn-run-metamount").addEventListener("click", async () => {
      showToast("Executing metamount.sh...");
      await ksuExec("sh /data/adb/modules/unimount/metamount.sh 2>&1 || sh /data/adb/metamodule/metamount.sh 2>&1");
      showToast("metamount.sh completed");
      await refreshAll();
    });

    // Config switches
    ["cfg-manual-mode", "cfg-selinux-mirror", "cfg-log-verbose"].forEach((id) => {
      document.getElementById(id).addEventListener("change", saveConfig);
    });

    // Delegated clicks for Module Toggles
    document.body.addEventListener("change", async (e) => {
      const t = e.target;
      if (!t || !t.dataset || !t.dataset.action) return;

      const action = t.dataset.action;
      const modId = t.dataset.id;
      const modPath = t.dataset.path;

      if (action === "whitelist") {
        if (t.checked) {
          await ksuExec(`grep -qx "${modId}" /data/adb/unimount/modules.txt 2>/dev/null || echo "${modId}" >> /data/adb/unimount/modules.txt`);
          showToast(`Added ${modId} to modules.txt`);
        } else {
          await ksuExec(`sed -i '/^${modId}$/d' /data/adb/unimount/modules.txt`);
          showToast(`Removed ${modId} from modules.txt`);
        }
      } else if (action === "skip_unimount") {
        if (t.checked) {
          await ksuExec(`touch "${modPath}/skip_unimount"`);
          showToast(`Created skip_unimount for ${modId}`);
        } else {
          await ksuExec(`rm -f "${modPath}/skip_unimount"`);
          showToast(`Removed skip_unimount for ${modId}`);
        }
      } else if (action === "skip_mount") {
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

    // Log buttons
    document.getElementById("btn-proc-mounts").addEventListener("click", () => loadLogs(true));
    document.getElementById("btn-clear-log").addEventListener("click", async () => {
      await ksuExec("echo '=== Log Cleared ===' > /data/adb/unimount/mount.log");
      loadLogs(false);
    });

    await refreshAll();
  });
})();
