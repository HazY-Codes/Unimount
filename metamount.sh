#!/system/bin/sh
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOG_FILE="$CONF_DIR/mount.log"
MIRROR_ROOT="$CONF_DIR/mirror"
MODULES_DIR="/data/adb/modules"
ACTIVE_MOUNTS="$CONF_DIR/active_mounts.list"
LOCK_DIR="$CONF_DIR/.lock"

mkdir -p "$CONF_DIR" "$MIRROR_ROOT"

# Abort silently if UniMount itself is disabled or pending removal
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  exit 0
fi

# Abort if /data/adb/metamodule is actively owned by another metamodule
if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-unimount}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    echo "[ABORT] /data/adb/metamodule belongs to '$_meta_id'; UniMount standing down." >> "$LOG_FILE"
    exit 0
  fi
fi

# Atomic lock guard to prevent concurrent metamount.sh / service.sh / action.sh races
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  _old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  return 1
}

if ! acquire_lock; then
  echo "[SKIP] Concurrent metamount.sh execution already in progress." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# Load configuration defaults
MOUNT_MODE="auto"
SELINUX_MIRROR="1"
SKIP_ZYGISK_ONLY="1"
LOG_VERBOSE="1"
BOOTLOOP_GUARD="1"
PROTECT_CRITICAL_PATHS="1"
[ -f "$CONF_DIR/config.conf" ] && . "$CONF_DIR/config.conf"

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
PREV_MOUNT_BOOT_ID=$(cat "$CONF_DIR/.last_mount_boot_id" 2>/dev/null || echo "")
BOOT_COMPLETED=$(getprop sys.boot_completed 2>/dev/null || echo "0")
SELINUX_STATE=$(getenforce 2>/dev/null || echo "Enforcing")

echo "=== UniMount v2.4.3 Run: $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
echo "[INFO] Mode: $MOUNT_MODE | SELinux: $SELINUX_STATE (Mirror: $SELINUX_MIRROR) | Guard: $BOOTLOOP_GUARD | CriticalProtect: $PROTECT_CRITICAL_PATHS" >> "$LOG_FILE"

# Safe Mode bypass (Android Safe Mode or KernelSU safe-mode marker)
SAFE_PERSIST=$(getprop persist.sys.safemode 2>/dev/null || echo "0")
SAFE_RO=$(getprop ro.sys.safemode 2>/dev/null || echo "0")
if [ "$SAFE_PERSIST" = "1" ] || [ "$SAFE_RO" = "1" ] || [ -f /data/adb/ksu/.safemode ]; then
  echo "[SAFE_MODE] Safe Mode detected; skipping all overlays." >> "$LOG_FILE"
  exit 0
fi

# Clear active mount ledger only on a new cold boot (preserved across soft reboots)
if [ "$BOOT_ID" != "$PREV_MOUNT_BOOT_ID" ]; then
  : > "$ACTIVE_MOUNTS"
fi
[ -f "$ACTIVE_MOUNTS" ] || : > "$ACTIVE_MOUNTS"

# Bootloop circuit breaker (early boot only, max 1 increment per boot_id)
if [ "$BOOT_COMPLETED" = "1" ]; then
  echo "0" > "$CONF_DIR/.boot_fail_count"
  echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
  rm -f "$CONF_DIR/.bypass_boot_id"
elif [ "$BOOTLOOP_GUARD" = "1" ]; then
  BYPASS_BOOT=$(cat "$CONF_DIR/.bypass_boot_id" 2>/dev/null || echo "")
  if [ "$BYPASS_BOOT" = "$BOOT_ID" ]; then
    echo "[SAFE_BYPASS] Bootloop guard active for this boot; skipping all overlays." >> "$LOG_FILE"
    exit 0
  fi

  FAIL_COUNT=$(cat "$CONF_DIR/.boot_fail_count" 2>/dev/null || echo "0")
  case "$FAIL_COUNT" in
    ''|*[!0-9]*) FAIL_COUNT=0 ;;
  esac
  LAST_ATTEMPT_BOOT=$(cat "$CONF_DIR/.last_attempt_boot_id" 2>/dev/null || echo "")

  if [ "$BOOT_ID" != "$LAST_ATTEMPT_BOOT" ]; then
    if [ "$FAIL_COUNT" -ge 2 ]; then
      echo "$BOOT_ID" > "$CONF_DIR/.bypass_boot_id"
      echo "[SAFE_BYPASS] Bootloop guard triggered ($FAIL_COUNT consecutive incomplete boots); skipping all mounts. Reset via WebUI or normal boot completion." >> "$LOG_FILE"
      exit 0
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$CONF_DIR/.boot_fail_count"
    echo "$BOOT_ID" > "$CONF_DIR/.last_attempt_boot_id"
  fi
fi

is_critical_path() {
  case "$1" in
    /system/bin/init|/system/bin/linker|/system/bin/linker64|/system/bin/linker_asan|/system/bin/linker_asan64|/system/bin/vold|/system/bin/servicemanager|/system/bin/hwservicemanager|/system/bin/vndservicemanager|/system/etc/selinux/*|/vendor/etc/selinux/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

is_target_mounted() {
  _tgt="$1"
  if [ -r /proc/self/mountinfo ]; then
    awk -v tgt="$_tgt" '$5 == tgt { found=1; exit } END { exit !found }' /proc/self/mountinfo 2>/dev/null
    return $?
  fi
  awk -v tgt="$_tgt" '$2 == tgt { found=1; exit } END { exit !found }' /proc/mounts 2>/dev/null
}

module_is_eligible() {
  _mid="$1"
  _mdir="$MODULES_DIR/$_mid"
  [ -d "$_mdir" ] || return 1
  [ "$_mid" = "unimount" ] && return 1
  if [ -f "$_mdir/disable" ] || [ -f "$_mdir/remove" ] || [ -f "$_mdir/skip_mount" ] || [ -f "$_mdir/skip_unimount" ]; then
    return 1
  fi
  if [ "$MOUNT_MODE" = "manual" ]; then
    grep -Fxq "$_mid" "$CONF_DIR/modules.txt" 2>/dev/null || return 1
  fi
  return 0
}

# Reconcile & lazily unmount stale binds for modules disabled/removed/skipped across soft reboots
reconcile_stale_mounts() {
  [ -s "$ACTIVE_MOUNTS" ] || return 0
  _tmp_list="$CONF_DIR/.active_mounts.tmp"
  : > "$_tmp_list"

  while IFS='|' read -r _rec_mod _rec_dst _rec_src; do
    [ -n "$_rec_mod" ] && [ -n "$_rec_dst" ] || continue
    _src_ok=1
    if [ -n "$_rec_src" ] && [ ! -f "$_rec_src" ]; then
      _src_ok=0
    fi
    if [ "$_src_ok" = "1" ] && module_is_eligible "$_rec_mod"; then
      if is_target_mounted "$_rec_dst"; then
        echo "$_rec_mod|$_rec_dst|$_rec_src" >> "$_tmp_list"
      fi
    else
      if is_target_mounted "$_rec_dst"; then
        umount -l "$_rec_dst" 2>>"$LOG_FILE" && echo "[UNMOUNT] $_rec_mod -> $_rec_dst (stale/disabled module)" >> "$LOG_FILE"
      fi
    fi
  done < "$ACTIVE_MOUNTS"

  mv "$_tmp_list" "$ACTIVE_MOUNTS"
}

reconcile_stale_mounts

mount_tree() {
  _src_base="$1"
  _dst_base="$2"
  _mod_id="$3"

  [ ! -d "$_src_base" ] && return 0

  find "$_src_base" -type f | while IFS= read -r src_file; do
    [ -L "$src_file" ] && continue
    rel_path="${src_file#$_src_base/}"
    dst_file="$_dst_base/$rel_path"

    # Require existing regular non-symlink target file
    [ -f "$dst_file" ] && [ ! -L "$dst_file" ] || continue

    if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$dst_file"; then
      echo "[BLOCKED] $_mod_id -> $dst_file (critical system path protected)" >> "$LOG_FILE"
      continue
    fi

    if is_target_mounted "$dst_file"; then
      [ "$LOG_VERBOSE" = "1" ] && echo "[SKIP_DUP] $_mod_id -> $dst_file (already mounted)" >> "$LOG_FILE"
      continue
    fi

    # Mirror POSIX permissions and ownership from target file
    _stat_info=$(stat -c '%a %u %g' "$dst_file" 2>/dev/null)
    if [ -n "$_stat_info" ]; then
      set -- $_stat_info
      [ -n "$1" ] && chmod "$1" "$src_file" 2>/dev/null
      [ -n "$2" ] && [ -n "$3" ] && chown "$2:$3" "$src_file" 2>/dev/null
    fi

    # Strict SELinux fail-closed context mirroring under Enforcing
    orig_ctx=""
    if [ "$SELINUX_MIRROR" = "1" ]; then
      orig_ctx=$(ls -Z "$dst_file" 2>/dev/null | awk '{print $1}')
      case "$orig_ctx" in
        u:object_r:*)
          _chcon_ok=0
          if chcon "$orig_ctx" "$src_file" 2>/dev/null; then
            new_ctx=$(ls -Z "$src_file" 2>/dev/null | awk '{print $1}')
            [ "$new_ctx" = "$orig_ctx" ] && _chcon_ok=1
          fi
          if [ "$_chcon_ok" != "1" ]; then
            if [ "$SELINUX_STATE" = "Enforcing" ]; then
              echo "[SKIP_SELINUX] $_mod_id -> $dst_file (chcon failed under Enforcing: want $orig_ctx)" >> "$LOG_FILE"
              continue
            else
              echo "[WARN_SELINUX] $_mod_id -> $dst_file (chcon failed under $SELINUX_STATE)" >> "$LOG_FILE"
            fi
          fi
          ;;
        *)
          if [ "$SELINUX_STATE" = "Enforcing" ]; then
            echo "[SKIP_SELINUX] $_mod_id -> $dst_file (unreadable SELinux context under Enforcing)" >> "$LOG_FILE"
            continue
          fi
          ;;
      esac
    fi

    if mount -o bind "$src_file" "$dst_file" 2>>"$LOG_FILE"; then
      mount -o remount,ro,bind "$dst_file" 2>/dev/null || true
      echo "$_mod_id|$dst_file|$src_file" >> "$ACTIVE_MOUNTS"
      [ "$LOG_VERBOSE" = "1" ] && echo "[MOUNT] $_mod_id -> $dst_file (ctx: ${orig_ctx:-default})" >> "$LOG_FILE"
    fi
  done
}

for mod in "$MODULES_DIR"/*; do
  [ ! -d "$mod" ] && continue
  mod_id=$(basename "$mod")
  [ "$mod_id" = "unimount" ] && continue

  if [ -f "$mod/disable" ] || [ -f "$mod/remove" ] || [ -f "$mod/skip_mount" ] || [ -f "$mod/skip_unimount" ]; then
    echo "[SKIP] $mod_id (disabled or skip flag present)" >> "$LOG_FILE"
    continue
  fi

  if [ "$MOUNT_MODE" = "manual" ]; then
    if ! grep -Fxq "$mod_id" "$CONF_DIR/modules.txt" 2>/dev/null; then
      echo "[SKIP] $mod_id (not in manual modules.txt whitelist)" >> "$LOG_FILE"
      continue
    fi
  fi

  has_overlay=0
  for part in system vendor product system_ext odm prism optics; do
    if [ -d "$mod/$part" ]; then
      has_overlay=1
      if [ "$part" = "system" ]; then
        mount_tree "$mod/system" "/system" "$mod_id"
      else
        mount_tree "$mod/$part" "/$part" "$mod_id"
      fi
    fi
  done

  if [ "$has_overlay" = "0" ] && [ "$SKIP_ZYGISK_ONLY" = "1" ]; then
    echo "[INFO] $mod_id: Zygisk / service-only module (no partition overlay)" >> "$LOG_FILE"
  fi
done

echo "$BOOT_ID" > "$CONF_DIR/.last_mount_boot_id"
echo "=== UniMount Complete ===" >> "$LOG_FILE"
