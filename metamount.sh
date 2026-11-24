#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

VERSION="v2.5.1"
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOG_FILE="$CONF_DIR/mount.log"
MIRROR_ROOT="$CONF_DIR/mirror"
MODULES_DIR="/data/adb/modules"
ACTIVE_MOUNTS="$CONF_DIR/active_mounts.list"
DEV_LEDGER="/dev/unimount_active_mounts"
LOCK_DIR="$CONF_DIR/.lock"
ACTION_MODE="${1:-mount}"

ELIGIBLE_TREES="$CONF_DIR/.mirror_trees.tmp"
CAND_ANCS="$CONF_DIR/.mirror_cand_ancs.tmp"
FINAL_ANCS="$CONF_DIR/.mirror_final_ancs.tmp"
TOUCHED_DIRS="$CONF_DIR/.mirror_touched_dirs.tmp"
INNER_BINDS="$CONF_DIR/.mirror_inner_binds.tmp"
MIRRORED_ANCS="$CONF_DIR/.mirrored_ancs.tmp"

# Fallback to KSU/APatch/Magisk busybox awk when /system/bin lacks standalone awk
if ! command -v awk >/dev/null 2>&1; then
  for _cand_bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$_cand_bb" ]; then
      _UNIMOUNT_BB="$_cand_bb"
      awk() { "$_UNIMOUNT_BB" awk "$@"; }
      break
    fi
  done
fi

another_metamodule_active() {
  [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ] || return 1
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-unimount}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    if { [ -d "/data/adb/modules/$_meta_id" ] && [ ! -f "/data/adb/modules/$_meta_id/remove" ]; } || \
       { [ -d "$_meta_target" ] && [ ! -f "$_meta_target/remove" ]; }; then
      ACTIVE_FOREIGN_METAMOD="$_meta_id"
      return 0
    fi
  fi
  return 1
}

# Normal mount runs stand down before touching /data/adb/unimount if disabled or superseded
case "$ACTION_MODE" in
  --unmount-all|unmount|unmount-all) ;;
  *)
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      exit 0
    fi
    if another_metamodule_active; then
      mkdir -p "$CONF_DIR" 2>/dev/null
      printf '%s\n' "[ABORT] /data/adb/metamodule belongs to '$ACTIVE_FOREIGN_METAMOD'; UniMount standing down." >> "$LOG_FILE"
      exit 0
    fi
    ;;
esac

mkdir -p "$CONF_DIR" "$MIRROR_ROOT"

log_msg() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

log_verbose() {
  [ "$LOG_VERBOSE" = "1" ] && printf '%s\n' "$1" >> "$LOG_FILE"
}

# Atomic PID lock directory with race-free stale-lock reclamation
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  _old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  case "$_old_pid" in
    ''|0|*[!0-9]*)
      # Distinguish freshly created lock (pid file not written yet) from stale dir
      if [ ! -f "$LOCK_DIR/pid" ]; then
        sleep 1
        _old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
      fi
      ;;
  esac

  case "$_old_pid" in
    ''|0|*[!0-9]*) ;;
    *)
      if kill -0 "$_old_pid" 2>/dev/null; then
        return 1
      fi
      ;;
  esac

  # Atomically rename stale lock dir so only one contender can reclaim it
  _stale_dir="$CONF_DIR/.lock.stale.$$"
  if mv "$LOCK_DIR" "$_stale_dir" 2>/dev/null; then
    rm -rf "$_stale_dir" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid"
      return 0
    fi
  fi
  return 1
}

if ! acquire_lock; then
  log_msg "[SKIP] Concurrent metamount.sh execution already in progress."
  exit 0
fi

cleanup_runtime() {
  if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
  rm -f "$CONF_DIR"/.mirror_*.tmp "$CONF_DIR"/.mirrored_ancs.tmp \
    "$CONF_DIR"/.active_mounts.tmp "$CONF_DIR"/.unmount_*.tmp 2>/dev/null
}

trap 'cleanup_runtime' EXIT
trap 'cleanup_runtime; exit 130' INT
trap 'cleanup_runtime; exit 143' TERM

sync_ledgers() {
  [ -f "$ACTIVE_MOUNTS" ] || : > "$ACTIVE_MOUNTS"
  if [ -w /dev ] || [ -w "$DEV_LEDGER" ]; then
    cp -f "$ACTIVE_MOUNTS" "$DEV_LEDGER" 2>/dev/null && chmod 0600 "$DEV_LEDGER" 2>/dev/null || true
  fi
}

reset_bootloop_guard() {
  echo "0" > "$CONF_DIR/.boot_fail_count"
  echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
  rm -f "$CONF_DIR/.bypass_boot_id"
}

# Safe KEY=VALUE config parser (handles missing trailing newline; never executes shell code)
load_config() {
  MOUNT_MODE="auto"
  SELINUX_MIRROR="1"
  DIR_MIRROR_INJECT="1"
  SKIP_ZYGISK_ONLY="1"
  LOG_VERBOSE="1"
  BOOTLOOP_GUARD="1"
  PROTECT_CRITICAL_PATHS="1"

  [ -r "$CONF_DIR/config.conf" ] || return 0
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    _k=$(printf '%s' "$_k" | tr -d ' \t\r')
    _v=$(printf '%s' "$_v" | tr -d ' \t\r"')
    case "$_k" in
      MOUNT_MODE)
        [ "$_v" = "manual" ] && MOUNT_MODE="manual" || MOUNT_MODE="auto" ;;
      SELINUX_MIRROR)
        [ "$_v" = "0" ] && SELINUX_MIRROR="0" || SELINUX_MIRROR="1" ;;
      DIR_MIRROR_INJECT)
        [ "$_v" = "0" ] && DIR_MIRROR_INJECT="0" || DIR_MIRROR_INJECT="1" ;;
      SKIP_ZYGISK_ONLY)
        [ "$_v" = "0" ] && SKIP_ZYGISK_ONLY="0" || SKIP_ZYGISK_ONLY="1" ;;
      LOG_VERBOSE)
        [ "$_v" = "0" ] && LOG_VERBOSE="0" || LOG_VERBOSE="1" ;;
      BOOTLOOP_GUARD)
        [ "$_v" = "0" ] && BOOTLOOP_GUARD="0" || BOOTLOOP_GUARD="1" ;;
      PROTECT_CRITICAL_PATHS)
        [ "$_v" = "0" ] && PROTECT_CRITICAL_PATHS="0" || PROTECT_CRITICAL_PATHS="1" ;;
    esac
  done < "$CONF_DIR/config.conf"
}

# Unified /proc/self/mountinfo (preferred) and /proc/mounts reader
# Emits "<source_or_root>\t<mountpoint>" with kernel octal escapes decoded
read_mount_table() {
  if [ -r /proc/self/mountinfo ]; then
    awk '
      {
        src = $4; mp = $5
        gsub(/\\040/, " ", mp); gsub(/\\011/, "\t", mp); gsub(/\\134/, "\\", mp)
        print src "\t" mp
      }
    ' /proc/self/mountinfo 2>/dev/null
  else
    awk '
      {
        src = $1; mp = $2
        gsub(/\\040/, " ", mp); gsub(/\\011/, "\t", mp); gsub(/\\134/, "\\", mp)
        print src "\t" mp
      }
    ' /proc/mounts 2>/dev/null
  fi
}

is_target_mounted() {
  _tgt="$1"
  read_mount_table | awk -F'\t' -v tgt="$_tgt" '$2 == tgt { found=1; exit } END { exit !found }'
}

list_mounts_under_prefix() {
  _pfx="${1%/}"
  read_mount_table | awk -F'\t' -v pfx="$_pfx" '
    $2 == pfx || substr($2, 1, length(pfx) + 1) == pfx "/" {
      print length($2) "\t" $2
    }
  ' | sort -rn | cut -f2-
}

list_active_mirror_targets() {
  _m_pfx="${MIRROR_ROOT%/}"
  read_mount_table | awk -F'\t' -v mpfx="$_m_pfx" '
    $1 ~ /\/unimount\/mirror\/merged/ {
      if ($2 != mpfx && substr($2, 1, length(mpfx) + 1) != mpfx "/") {
        print length($2) "\t" $2
      }
    }
  ' | sort -rn | cut -f2-
}

umount_one() {
  umount "$1" 2>/dev/null || umount -l "$1" 2>>"$LOG_FILE"
}

umount_under_prefix() {
  list_mounts_under_prefix "$1" | while IFS= read -r _mp; do
    [ -n "$_mp" ] || continue
    umount_one "$_mp"
  done
}

count_ledger_type() {
  _type="$1"
  [ -s "$ACTIVE_MOUNTS" ] || { echo 0; return; }
  awk -F'|' -v t="$_type" '$4 == t { c++ } END { print c + 0 }' "$ACTIVE_MOUNTS" 2>/dev/null
}

unmount_all_mounts() {
  _combined="$CONF_DIR/.unmount_all.tmp"
  _ordered="$CONF_DIR/.unmount_rev.tmp"
  : > "$_combined"

  [ -s "$DEV_LEDGER" ] && cat "$DEV_LEDGER" >> "$_combined" 2>/dev/null
  [ -s "$ACTIVE_MOUNTS" ] && cat "$ACTIVE_MOUNTS" >> "$_combined" 2>/dev/null

  if command -v awk >/dev/null 2>&1; then
    awk -F'|' 'NF >= 2 && !seen[$2]++ { lines[++n] = $0 } END { for (i = n; i >= 1; i--) print lines[i] }' "$_combined" > "$_ordered" 2>/dev/null
  else
    cp -f "$_combined" "$_ordered" 2>/dev/null
  fi

  _detached_binds=0
  _detached_mirrors=0
  _failed=0

  if [ -s "$_ordered" ]; then
    while IFS='|' read -r _u_mod _u_dst _u_src _u_type; do
      [ -n "$_u_dst" ] || continue
      if [ -z "$_u_type" ]; then
        case "$_u_src" in
          "$MIRROR_ROOT"/*) _u_type="DIR_MIRROR" ;;
          *) _u_type="FILE_BIND" ;;
        esac
      fi

      if [ "$_u_type" = "DIR_MIRROR" ]; then
        _was_mounted=0
        is_target_mounted "$_u_dst" && _was_mounted=1
        umount_under_prefix "$_u_dst"
        if is_target_mounted "$_u_dst"; then
          if umount_one "$_u_dst"; then
            _detached_mirrors=$((_detached_mirrors + 1))
            log_msg "[EMERGENCY_UNMOUNT] ${_u_mod:-unknown} -> $_u_dst (DIR_MIRROR)"
          else
            _failed=$((_failed + 1))
            log_msg "[WARN_UNMOUNT] Failed to detach mirror $_u_dst"
          fi
        elif [ "$_was_mounted" = "1" ]; then
          _detached_mirrors=$((_detached_mirrors + 1))
          log_msg "[EMERGENCY_UNMOUNT] ${_u_mod:-unknown} -> $_u_dst (DIR_MIRROR)"
        fi
      elif is_target_mounted "$_u_dst"; then
        if umount_one "$_u_dst"; then
          _detached_binds=$((_detached_binds + 1))
          log_msg "[EMERGENCY_UNMOUNT] ${_u_mod:-unknown} -> $_u_dst (FILE_BIND)"
        else
          _failed=$((_failed + 1))
          log_msg "[WARN_UNMOUNT] Failed to detach bind $_u_dst"
        fi
      fi
    done < "$_ordered"
  fi

  list_active_mirror_targets | while IFS= read -r _m_tgt; do
    [ -n "$_m_tgt" ] || continue
    umount_under_prefix "$_m_tgt"
    umount_one "$_m_tgt"
  done

  umount_under_prefix "$MIRROR_ROOT"

  if [ -z "$(list_mounts_under_prefix "$MIRROR_ROOT")" ]; then
    rm -rf "$MIRROR_ROOT/merged" 2>/dev/null
    mkdir -p "$MIRROR_ROOT/merged"
  else
    log_msg "[WARN_MIRROR] Active mounts remain under $MIRROR_ROOT after unmount; skipped rm -rf."
  fi

  : > "$ACTIVE_MOUNTS"
  sync_ledgers

  log_msg "[EMERGENCY_UNMOUNT] $(date '+%Y-%m-%d %H:%M:%S') Detached $_detached_binds FILE_BIND and $_detached_mirrors DIR_MIRROR mount(s) (failed: $_failed)"
  echo "UniMount $VERSION: Detached $_detached_binds file bind(s) and $_detached_mirrors directory mirror(s) (failed: $_failed)."
  exit 0
}

case "$ACTION_MODE" in
  --unmount-all|unmount|unmount-all)
    unmount_all_mounts
    ;;
esac

load_config

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
PREV_MOUNT_BOOT_ID=$(cat "$CONF_DIR/.last_mount_boot_id" 2>/dev/null || echo "")
BOOT_COMPLETED=$(getprop sys.boot_completed 2>/dev/null || echo "0")
SELINUX_STATE=$(getenforce 2>/dev/null || echo "Enforcing")

printf '=== UniMount %s Run: %s ===\n' "$VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
log_msg "[INFO] Mode: $MOUNT_MODE | SELinux: $SELINUX_STATE (Mirror: $SELINUX_MIRROR) | DirMirror: $DIR_MIRROR_INJECT | Guard: $BOOTLOOP_GUARD | CriticalProtect: $PROTECT_CRITICAL_PATHS"

# Safe Mode bypass (Android Safe Mode or KernelSU safe-mode marker)
SAFE_PERSIST=$(getprop persist.sys.safemode 2>/dev/null || echo "0")
SAFE_RO=$(getprop ro.sys.safemode 2>/dev/null || echo "0")
if [ "$SAFE_PERSIST" = "1" ] || [ "$SAFE_RO" = "1" ] || [ -f /data/adb/ksu/.safemode ]; then
  echo "$BOOT_ID" > "$CONF_DIR/.last_mount_boot_id"
  log_msg "[SAFE_MODE] Safe Mode detected; skipping all overlays."
  exit 0
fi

# Clear ledgers only on a fresh cold boot (retained across soft reboots)
if [ "$BOOT_ID" != "$PREV_MOUNT_BOOT_ID" ]; then
  : > "$ACTIVE_MOUNTS"
  sync_ledgers
else
  if [ ! -s "$ACTIVE_MOUNTS" ] && [ -s "$DEV_LEDGER" ]; then
    cp -f "$DEV_LEDGER" "$ACTIVE_MOUNTS" 2>/dev/null || true
  fi
  [ -f "$ACTIVE_MOUNTS" ] || : > "$ACTIVE_MOUNTS"
  sync_ledgers
fi

# Bootloop circuit breaker (supports early-boot KSU and late-load ephemeral root)
if [ "$BOOTLOOP_GUARD" = "1" ]; then
  BYPASS_BOOT=$(cat "$CONF_DIR/.bypass_boot_id" 2>/dev/null || echo "")
  if [ "$BYPASS_BOOT" = "$BOOT_ID" ]; then
    echo "$BOOT_ID" > "$CONF_DIR/.last_mount_boot_id"
    log_msg "[SAFE_BYPASS] Bootloop guard active for this boot; skipping all overlays."
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
      echo "$BOOT_ID" > "$CONF_DIR/.last_mount_boot_id"
      log_msg "[SAFE_BYPASS] Bootloop guard triggered ($FAIL_COUNT consecutive incomplete boots); skipping all mounts. Reset via WebUI or normal boot completion."
      exit 0
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$CONF_DIR/.boot_fail_count"
    echo "$BOOT_ID" > "$CONF_DIR/.last_attempt_boot_id"
  fi
elif [ "$BOOT_COMPLETED" = "1" ]; then
  reset_bootloop_guard
fi

is_critical_path() {
  case "$1" in
    /system/bin/init|/system/bin/linker|/system/bin/linker64|/system/bin/linker_asan|/system/bin/linker_asan64|/system/bin/vold|/system/bin/servicemanager|/system/bin/hwservicemanager|/system/bin/vndservicemanager|/system/etc/selinux|/system/etc/selinux/*|/vendor/etc/selinux|/vendor/etc/selinux/*|/system/vendor/etc/selinux|/system/vendor/etc/selinux/*|/system_ext/etc/selinux|/system_ext/etc/selinux/*|/product/etc/selinux|/product/etc/selinux/*|/odm/etc/selinux|/odm/etc/selinux/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

is_protected_container() {
  case "$1" in
    ""|/|/system|/vendor|/product|/system_ext|/odm|/prism|/optics|/apex|/apex/*|/system/apex|/system/apex/*|/system/vendor|/system/product|/system/system_ext|/system/odm|/system/bin/abb)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

is_routed_sar_subpath() {
  [ "$1" = "/system" ] || return 1
  case "$2" in
    vendor|vendor/*)
      [ -L "/system/vendor" ] && [ -d "/vendor" ] && return 0 ;;
    product|product/*)
      [ -L "/system/product" ] && [ -d "/product" ] && return 0 ;;
    system_ext|system_ext/*)
      [ -L "/system/system_ext" ] && [ -d "/system_ext" ] && return 0 ;;
    odm|odm/*)
      [ -L "/system/odm" ] && [ -d "/odm" ] && return 0 ;;
  esac
  return 1
}

is_unimount_active_target() {
  _chk_tgt="$1"
  [ -s "$ACTIVE_MOUNTS" ] || return 1
  awk -F'|' -v tgt="$_chk_tgt" '$2 == tgt { found=1; exit } END { exit !found }' "$ACTIVE_MOUNTS" 2>/dev/null
}

has_child_submounts() {
  _anc_dir="${1%/}"
  _sub_mps=$(read_mount_table | awk -F'\t' -v pfx="$_anc_dir" '
    substr($2, 1, length(pfx) + 1) == pfx "/" {
      if ($1 !~ /\/adb\/modules\// && $1 !~ /\/unimount\/mirror\//) {
        print $2
      }
    }
  ')
  [ -z "$_sub_mps" ] && return 1

  _found_non_uni=0
  while IFS= read -r _smp; do
    [ -n "$_smp" ] || continue
    if ! is_unimount_active_target "$_smp"; then
      _found_non_uni=1
      break
    fi
  done <<EOF
$_sub_mps
EOF
  [ "$_found_non_uni" = "1" ]
}

find_deepest_ancestor() {
  _cur=$(dirname "$1")
  while [ -n "$_cur" ] && [ "$_cur" != "/" ] && [ "$_cur" != "." ]; do
    if [ -d "$_cur" ] && [ ! -L "$_cur" ]; then
      echo "$_cur"
      return 0
    fi
    _cur=$(dirname "$_cur")
  done
  echo "/"
}

# Pure POSIX SELinux context extraction (does not depend on awk)
get_selinux_ctx() {
  _ls_line=$(ls -Zd "$1" 2>/dev/null)
  [ -n "$_ls_line" ] || return 0
  IFS=' ' read -r _ctx _rest <<EOF
$_ls_line
EOF
  printf '%s\n' "$_ctx"
}

clone_posix_attrs() {
  _src_p="$1"
  _dst_p="$2"
  [ -L "$_dst_p" ] && return 0
  _stat_info=$(stat -c '%a %u %g' "$_src_p" 2>/dev/null)
  [ -n "$_stat_info" ] || return 0
  IFS=' ' read -r _mode _uid _gid <<EOF
$_stat_info
EOF
  [ -n "$_mode" ] && chmod "$_mode" "$_dst_p" 2>/dev/null
  [ -n "$_uid" ] && [ -n "$_gid" ] && chown "$_uid:$_gid" "$_dst_p" 2>/dev/null
}

apply_selinux_ctx() {
  _target="$1"
  _want_ctx="$2"
  [ "$SELINUX_MIRROR" = "1" ] || return 0

  case "$_want_ctx" in
    u:object_r:*)
      _chcon_ok=0
      if [ -L "$_target" ]; then
        if chcon -h "$_want_ctx" "$_target" 2>/dev/null && [ "$(get_selinux_ctx "$_target")" = "$_want_ctx" ]; then
          _chcon_ok=1
        fi
      elif chcon "$_want_ctx" "$_target" 2>/dev/null && [ "$(get_selinux_ctx "$_target")" = "$_want_ctx" ]; then
        _chcon_ok=1
      fi
      if [ "$_chcon_ok" != "1" ]; then
        if [ "$SELINUX_STATE" = "Enforcing" ]; then
          log_msg "[SKIP_SELINUX] $_target (chcon failed under Enforcing: want $_want_ctx)"
          return 1
        fi
        log_msg "[WARN_SELINUX] $_target (chcon failed under $SELINUX_STATE: want $_want_ctx)"
      fi
      return 0
      ;;
    *)
      if [ "$SELINUX_STATE" = "Enforcing" ]; then
        log_msg "[SKIP_SELINUX] $_target (unreadable SELinux context '$_want_ctx' under Enforcing)"
        return 1
      fi
      return 0
      ;;
  esac
}

resolve_target_selinux_ctx() {
  _dst_item="$1"
  _src_item="$2"
  _fallback_ctx="$3"

  if [ -e "$_dst_item" ] || [ -L "$_dst_item" ]; then
    _ctx=$(get_selinux_ctx "$_dst_item")
    case "$_ctx" in
      u:object_r:*) echo "$_ctx"; return 0 ;;
    esac
  fi

  if [ -n "$_src_item" ] && { [ -e "$_src_item" ] || [ -L "$_src_item" ]; }; then
    _sctx=$(get_selinux_ctx "$_src_item")
    case "$_sctx" in
      u:object_r:*adb_data_file*|u:object_r:*system_data_file*|u:object_r:*magisk_file*|u:object_r:*ksu_file*|u:object_r:*unlabeled*) ;;
      u:object_r:*) echo "$_sctx"; return 0 ;;
    esac
  fi

  _near_anc=$(find_deepest_ancestor "$_dst_item")
  if [ -n "$_near_anc" ] && [ -d "$_near_anc" ]; then
    _actx=$(get_selinux_ctx "$_near_anc")
    case "$_actx" in
      u:object_r:*) echo "$_actx"; return 0 ;;
    esac
  fi

  echo "$_fallback_ctx"
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
    grep -Fxq -- "$_mid" "$CONF_DIR/modules.txt" 2>/dev/null || return 1
  fi
  return 0
}

# Tear down previous mirrors and prune stale binds before rebuilding
MIRROR_TEARDOWN_OK=1
teardown_and_reconcile_mounts() {
  _tmp_list="$CONF_DIR/.active_mounts.tmp"
  : > "$_tmp_list"

  if [ -s "$ACTIVE_MOUNTS" ]; then
    while IFS='|' read -r _rec_mod _rec_dst _rec_src _rec_type; do
      [ -n "$_rec_mod" ] && [ -n "$_rec_dst" ] || continue
      if [ -z "$_rec_type" ]; then
        case "$_rec_src" in
          "$MIRROR_ROOT"/*) _rec_type="DIR_MIRROR" ;;
          *) _rec_type="FILE_BIND" ;;
        esac
      fi

      if [ "$_rec_type" = "DIR_MIRROR" ]; then
        umount_under_prefix "$_rec_dst"
        is_target_mounted "$_rec_dst" && umount_one "$_rec_dst"
        log_verbose "[UNMOUNT_MIRROR] $_rec_mod -> $_rec_dst (tearing down previous mirror)"
      else
        _src_ok=1
        [ -n "$_rec_src" ] && [ ! -f "$_rec_src" ] && _src_ok=0
        if [ "$_src_ok" = "1" ] && module_is_eligible "$_rec_mod"; then
          is_target_mounted "$_rec_dst" && echo "$_rec_mod|$_rec_dst|$_rec_src|FILE_BIND" >> "$_tmp_list"
        elif is_target_mounted "$_rec_dst"; then
          umount_one "$_rec_dst"
          log_msg "[UNMOUNT] $_rec_mod -> $_rec_dst (stale/disabled module)"
        fi
      fi
    done < "$ACTIVE_MOUNTS"
    mv "$_tmp_list" "$ACTIVE_MOUNTS"
    sync_ledgers
  fi

  list_active_mirror_targets | while IFS= read -r _m_tgt; do
    [ -n "$_m_tgt" ] || continue
    umount_under_prefix "$_m_tgt"
    umount_one "$_m_tgt"
  done

  umount_under_prefix "$MIRROR_ROOT"

  if [ -n "$(list_mounts_under_prefix "$MIRROR_ROOT")" ]; then
    log_msg "[WARN_MIRROR] Active mounts still remain under $MIRROR_ROOT; skipping rm -rf."
    MIRROR_TEARDOWN_OK=0
  else
    rm -rf "$MIRROR_ROOT/merged" 2>/dev/null
    mkdir -p "$MIRROR_ROOT/merged"
    MIRROR_TEARDOWN_OK=1
  fi
}

unmount_file_binds_under_anc() {
  _anc_pfx="${1%/}"
  [ -s "$ACTIVE_MOUNTS" ] || return 0
  _tmp_list="$CONF_DIR/.active_mounts.tmp"
  : > "$_tmp_list"

  while IFS='|' read -r _rec_mod _rec_dst _rec_src _rec_type; do
    [ -n "$_rec_mod" ] && [ -n "$_rec_dst" ] || continue
    case "$_rec_dst" in
      "$_anc_pfx"|"$_anc_pfx"/*)
        if is_target_mounted "$_rec_dst"; then
          umount_one "$_rec_dst"
          log_verbose "[UNMOUNT] $_rec_mod -> $_rec_dst (absorbed into $_anc_pfx mirror)"
        fi
        ;;
      *)
        echo "$_rec_mod|$_rec_dst|$_rec_src|${_rec_type:-FILE_BIND}" >> "$_tmp_list"
        ;;
    esac
  done < "$ACTIVE_MOUNTS"

  mv "$_tmp_list" "$ACTIVE_MOUNTS"
  sync_ledgers
}

rollback_mirror_anc() {
  _rb_mirror="$MIRROR_ROOT/merged$1"
  umount_under_prefix "$_rb_mirror"
  if [ -z "$(list_mounts_under_prefix "$_rb_mirror")" ]; then
    rm -rf "$_rb_mirror" 2>/dev/null
  fi
}

module_replaces_dir_with_nondir() {
  _chk_dir="$1"
  [ -s "$ELIGIBLE_TREES" ] || return 1
  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -n "$_t_src" ] && [ -n "$_t_dst" ] || continue
    case "$_chk_dir" in
      "$_t_dst"/*)
        _m_p="$_t_src/${_chk_dir#$_t_dst/}"
        if [ -L "$_m_p" ] || [ -f "$_m_p" ]; then
          return 0
        fi
        ;;
    esac
  done < "$ELIGIBLE_TREES"
  return 1
}

is_under_mirrored_dir() {
  _chk_path="$1"
  [ -s "$MIRRORED_ANCS" ] || return 1
  while IFS= read -r _m_anc; do
    [ -n "$_m_anc" ] || continue
    case "$_chk_path" in
      "$_m_anc"|"$_m_anc"/*) return 0 ;;
    esac
  done < "$MIRRORED_ANCS"
  return 1
}

teardown_and_reconcile_mounts

: > "$ELIGIBLE_TREES"
: > "$CAND_ANCS"
: > "$FINAL_ANCS"
: > "$MIRRORED_ANCS"

# Collect eligible modules and partition trees (with SAR cross-partition symlink routing)
for mod in "$MODULES_DIR"/*; do
  [ -d "$mod" ] || continue
  mod_id=$(basename "$mod")
  [ "$mod_id" = "unimount" ] && continue

  if [ -f "$mod/disable" ] || [ -f "$mod/remove" ] || [ -f "$mod/skip_mount" ] || [ -f "$mod/skip_unimount" ]; then
    log_verbose "[SKIP] $mod_id (disabled or skip flag present)"
    continue
  fi

  if [ "$MOUNT_MODE" = "manual" ] && ! grep -Fxq -- "$mod_id" "$CONF_DIR/modules.txt" 2>/dev/null; then
    log_verbose "[SKIP] $mod_id (not in manual modules.txt whitelist)"
    continue
  fi

  has_overlay=0
  for part in system vendor product system_ext odm prism optics; do
    if [ -d "$mod/$part" ] && [ ! -L "$mod/$part" ]; then
      has_overlay=1
      echo "$mod_id|$mod/$part|/$part" >> "$ELIGIBLE_TREES"
      if [ "$part" = "system" ]; then
        for subpart in vendor product system_ext odm; do
          if [ -d "$mod/system/$subpart" ] && [ ! -L "$mod/system/$subpart" ] && [ -L "/system/$subpart" ] && [ -d "/$subpart" ]; then
            echo "$mod_id|$mod/system/$subpart|/$subpart" >> "$ELIGIBLE_TREES"
          fi
        done
      fi
    fi
  done

  if [ "$has_overlay" = "0" ] && [ "$SKIP_ZYGISK_ONLY" = "1" ]; then
    log_verbose "[INFO] $mod_id: Zygisk / service-only module (no partition overlay)"
  fi
done

# Pass 1: Minimal-ancestor directory mirror discovery and multi-module composition
discover_mirror_candidates() {
  [ -s "$ELIGIBLE_TREES" ] || return 0
  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -d "$_t_src" ] || continue
    find "$_t_src" \( -type f -o -type l -o -type d \) 2>/dev/null | while IFS= read -r _entry; do
      [ "$_entry" = "$_t_src" ] && continue
      _rel="${_entry#$_t_src/}"
      is_routed_sar_subpath "$_t_dst" "$_rel" && continue
      _dst_path="$_t_dst/$_rel"

      if [ -d "$_entry" ] && [ ! -L "$_entry" ]; then
        [ -d "$_dst_path" ] && [ ! -L "$_dst_path" ] && continue
        _has_child=$(find "$_entry" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)
        [ -n "$_has_child" ] && continue
      elif [ -f "$_entry" ] && [ ! -L "$_entry" ]; then
        # Existing regular file targets are handled by Pass 2 unless an ancestor is mirrored
        [ -f "$_dst_path" ] && [ ! -L "$_dst_path" ] && continue
      fi

      if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_dst_path"; then
        log_msg "[BLOCKED] $_t_mod -> $_dst_path (critical system path protected)"
        continue
      fi

      if [ "$DIR_MIRROR_INJECT" != "1" ]; then
        log_msg "[SKIP_NEW] $_t_mod -> $_dst_path (DIR_MIRROR_INJECT=0)"
        continue
      fi

      _anc=$(find_deepest_ancestor "$_dst_path")
      if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_anc"; then
        log_msg "[BLOCKED] $_t_mod -> $_anc (critical system path protected)"
        continue
      fi

      if is_protected_container "$_anc" || has_child_submounts "$_anc"; then
        log_msg "[BLOCKED_MIRROR] $_t_mod -> $_anc (active child sub-mount or protected container)"
        continue
      fi

      echo "$_anc" >> "$CAND_ANCS"
    done
  done < "$ELIGIBLE_TREES"
}

prune_nested_ancestors() {
  : > "$FINAL_ANCS"
  [ -s "$CAND_ANCS" ] || return 0
  awk '{ print length($0) "\t" $0 }' "$CAND_ANCS" | sort -n | cut -f2- | awk '!seen[$0]++' | while IFS= read -r _cand; do
    [ -n "$_cand" ] || continue
    _nested=0
    if [ -s "$FINAL_ANCS" ]; then
      while IFS= read -r _accepted; do
        [ -n "$_accepted" ] || continue
        case "$_cand" in
          "$_accepted"|"$_accepted"/*)
            _nested=1
            break
            ;;
        esac
      done < "$FINAL_ANCS"
    fi
    [ "$_nested" = "0" ] && echo "$_cand" >> "$FINAL_ANCS"
  done
}

build_and_mount_mirror_anc() {
  _anc="$1"
  _mirror_anc="$MIRROR_ROOT/merged$_anc"

  unmount_file_binds_under_anc "$_anc"

  # 1. Identify existing subdirectories under $_anc touched by any eligible module
  : > "$TOUCHED_DIRS.raw"
  echo "$_anc" >> "$TOUCHED_DIRS.raw"

  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -n "$_t_src" ] && [ -n "$_t_dst" ] || continue
    case "$_anc" in
      "$_t_dst"/*)
        _mod_anc_src="$_t_src/${_anc#$_t_dst/}"
        if [ -d "$_mod_anc_src" ] && [ ! -L "$_mod_anc_src" ]; then
          find "$_mod_anc_src" -type d 2>/dev/null | while IFS= read -r _md; do
            [ "$_md" = "$_mod_anc_src" ] && continue
            _cand_orig_dir="$_anc/${_md#$_mod_anc_src/}"
            if [ -d "$_cand_orig_dir" ] && [ ! -L "$_cand_orig_dir" ]; then
              echo "$_cand_orig_dir" >> "$TOUCHED_DIRS.raw"
            fi
          done
        fi
        ;;
    esac
  done < "$ELIGIBLE_TREES"

  awk '{ print length($0) "\t" $0 }' "$TOUCHED_DIRS.raw" | sort -n | cut -f2- | awk '!seen[$0]++' > "$TOUCHED_DIRS"
  rm -f "$TOUCHED_DIRS.raw" 2>/dev/null

  # 2. Populate composite mirror from stock $_anc (bind-mounting untouched sibling dirs read-only)
  : > "$INNER_BINDS"
  _stage_ok=1
  _anc_ctx=$(get_selinux_ctx "$_anc")

  while IFS= read -r _orig_dir; do
    [ -n "$_orig_dir" ] || continue
    _m_dir="$MIRROR_ROOT/merged$_orig_dir"
    mkdir -p "$_m_dir"
    clone_posix_attrs "$_orig_dir" "$_m_dir"
    if ! apply_selinux_ctx "$_m_dir" "$(get_selinux_ctx "$_orig_dir")"; then
      _stage_ok=0
      break
    fi

    for _item in "$_orig_dir"/* "$_orig_dir"/.[!.]* "$_orig_dir"/..?*; do
      [ -e "$_item" ] || [ -L "$_item" ] || continue
      _m_item="$_m_dir/$(basename "$_item")"

      if [ -L "$_item" ]; then
        rm -rf "$_m_item" 2>/dev/null
        cp -P "$_item" "$_m_item" 2>/dev/null || ln -s "$(readlink "$_item")" "$_m_item" 2>/dev/null
        if ! apply_selinux_ctx "$_m_item" "$(get_selinux_ctx "$_item")"; then
          _stage_ok=0
          break
        fi
      elif [ -d "$_item" ]; then
        if grep -Fxq -- "$_item" "$TOUCHED_DIRS" 2>/dev/null; then
          mkdir -p "$_m_item"
        elif module_replaces_dir_with_nondir "$_item"; then
          :
        else
          mkdir -p "$_m_item"
          clone_posix_attrs "$_item" "$_m_item"
          if ! apply_selinux_ctx "$_m_item" "$(get_selinux_ctx "$_item")"; then
            _stage_ok=0
            break
          fi
          if mount -o bind "$_item" "$_m_item" 2>>"$LOG_FILE"; then
            mount -o remount,ro,bind "$_m_item" 2>/dev/null || true
            echo "$_m_item" >> "$INNER_BINDS"
          else
            _stage_ok=0
            break
          fi
        fi
      elif [ -f "$_item" ]; then
        if ! cp -pf "$_item" "$_m_item" 2>/dev/null && ! cp -f "$_item" "$_m_item" 2>/dev/null; then
          _stage_ok=0
          break
        fi
        clone_posix_attrs "$_item" "$_m_item"
        if ! apply_selinux_ctx "$_m_item" "$(get_selinux_ctx "$_item")"; then
          _stage_ok=0
          break
        fi
      fi
    done

    [ "$_stage_ok" = "1" ] || break
  done < "$TOUCHED_DIRS"

  if [ "$_stage_ok" != "1" ]; then
    rollback_mirror_anc "$_anc"
    return 1
  fi

  # 3. Overlay all eligible modules targeting $_anc/* into the composite mirror
  _mods_for_anc=""
  _mod_dirs_tmp="$CONF_DIR/.mirror_mod_dirs.tmp"
  _mod_files_tmp="$CONF_DIR/.mirror_mod_files.tmp"

  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -n "$_t_src" ] && [ -n "$_t_dst" ] || continue
    case "$_anc" in
      "$_t_dst"/*)
        _mod_anc_src="$_t_src/${_anc#$_t_dst/}"
        [ -d "$_mod_anc_src" ] && [ ! -L "$_mod_anc_src" ] || continue
        _mod_contributed=0

        find "$_mod_anc_src" -type d 2>/dev/null | awk '{ print length($0) "\t" $0 }' | sort -n | cut -f2- > "$_mod_dirs_tmp"
        while IFS= read -r _src_d; do
          [ -n "$_src_d" ] && [ "$_src_d" != "$_mod_anc_src" ] || continue
          _dst_d="$_anc/${_src_d#$_mod_anc_src/}"
          _m_d="$MIRROR_ROOT/merged$_dst_d"

          if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_dst_d"; then
            log_msg "[BLOCKED] $_t_mod -> $_dst_d (critical system path protected)"
            continue
          fi

          if [ -L "$_m_d" ] || [ -f "$_m_d" ]; then
            rm -f "$_m_d" 2>/dev/null
          fi
          mkdir -p "$_m_d"

          if [ -d "$_dst_d" ] && [ ! -L "$_dst_d" ]; then
            clone_posix_attrs "$_dst_d" "$_m_d"
          else
            chmod 0755 "$_m_d" 2>/dev/null
            chown 0:0 "$_m_d" 2>/dev/null
          fi

          _want_ctx=$(resolve_target_selinux_ctx "$_dst_d" "$_src_d" "$_anc_ctx")
          if ! apply_selinux_ctx "$_m_d" "$_want_ctx"; then
            _stage_ok=0
            break
          fi
          _mod_contributed=1
        done < "$_mod_dirs_tmp"

        [ "$_stage_ok" = "1" ] || break

        find "$_mod_anc_src" \( -type f -o -type l \) 2>/dev/null > "$_mod_files_tmp"
        while IFS= read -r _src_f; do
          [ -n "$_src_f" ] || continue
          _dst_f="$_anc/${_src_f#$_mod_anc_src/}"
          _m_f="$MIRROR_ROOT/merged$_dst_f"

          if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_dst_f"; then
            log_msg "[BLOCKED] $_t_mod -> $_dst_f (critical system path protected)"
            continue
          fi

          mkdir -p "$(dirname "$_m_f")"
          rm -rf "$_m_f" 2>/dev/null

          if [ -L "$_src_f" ]; then
            if ! cp -P "$_src_f" "$_m_f" 2>/dev/null && ! ln -s "$(readlink "$_src_f")" "$_m_f" 2>/dev/null; then
              _stage_ok=0
              break
            fi
            chown -h 0:0 "$_m_f" 2>/dev/null || true
          else
            if ! cp -f "$_src_f" "$_m_f" 2>/dev/null; then
              _stage_ok=0
              break
            fi
            if [ -f "$_dst_f" ] && [ ! -L "$_dst_f" ]; then
              clone_posix_attrs "$_dst_f" "$_m_f"
            else
              case "$_dst_f" in
                */bin/*|*/xbin/*)
                  chmod 0755 "$_m_f" 2>/dev/null
                  chown 0:2000 "$_m_f" 2>/dev/null
                  ;;
                *)
                  if [ -x "$_src_f" ]; then
                    chmod 0755 "$_m_f" 2>/dev/null
                  else
                    chmod 0644 "$_m_f" 2>/dev/null
                  fi
                  chown 0:0 "$_m_f" 2>/dev/null
                  ;;
              esac
            fi
          fi

          _want_ctx=$(resolve_target_selinux_ctx "$_dst_f" "$_src_f" "$_anc_ctx")
          if ! apply_selinux_ctx "$_m_f" "$_want_ctx"; then
            _stage_ok=0
            break
          fi

          _mod_contributed=1
          log_verbose "[MIRROR_STAGE] $_t_mod -> $_dst_f (ctx: ${_want_ctx:-default})"
        done < "$_mod_files_tmp"

        [ "$_stage_ok" = "1" ] || break

        if [ "$_mod_contributed" = "1" ]; then
          case ",$_mods_for_anc," in
            *,"$_t_mod",*) ;;
            *) _mods_for_anc="${_mods_for_anc:+$_mods_for_anc,}$_t_mod" ;;
          esac
        fi
        ;;
    esac
  done < "$ELIGIBLE_TREES"

  rm -f "$_mod_dirs_tmp" "$_mod_files_tmp" 2>/dev/null

  if [ "$_stage_ok" != "1" ] || [ -z "$_mods_for_anc" ]; then
    rollback_mirror_anc "$_anc"
    return 1
  fi

  # 4. Bind-mount the completed composite mirror onto $_anc
  if mount -o bind "$_mirror_anc" "$_anc" 2>>"$LOG_FILE"; then
    mount -o remount,ro,bind "$_anc" 2>/dev/null || true
    echo "$_mods_for_anc|$_anc|$_mirror_anc|DIR_MIRROR" >> "$ACTIVE_MOUNTS"
    echo "$_anc" >> "$MIRRORED_ANCS"
    log_msg "[MIRROR_MOUNT] $_mods_for_anc -> $_anc (ctx: ${_anc_ctx:-default})"
    return 0
  fi

  rollback_mirror_anc "$_anc"
  return 1
}

if [ "$MIRROR_TEARDOWN_OK" = "1" ]; then
  discover_mirror_candidates
  if [ "$DIR_MIRROR_INJECT" = "1" ] && [ -s "$CAND_ANCS" ]; then
    prune_nested_ancestors
    while IFS= read -r _plan_anc; do
      [ -n "$_plan_anc" ] || continue
      build_and_mount_mirror_anc "$_plan_anc"
    done < "$FINAL_ANCS"
  fi
fi

# Pass 2: Direct existing-file bind mounts
mount_tree() {
  _src_base="$1"
  _dst_base="$2"
  _mod_id="$3"

  [ -d "$_src_base" ] || return 0

  find "$_src_base" -type f 2>/dev/null | while IFS= read -r src_file; do
    [ -L "$src_file" ] && continue
    rel_path="${src_file#$_src_base/}"
    is_routed_sar_subpath "$_dst_base" "$rel_path" && continue
    dst_file="$_dst_base/$rel_path"

    is_under_mirrored_dir "$dst_file" && continue
    [ -f "$dst_file" ] && [ ! -L "$dst_file" ] || continue

    if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$dst_file"; then
      log_msg "[BLOCKED] $_mod_id -> $dst_file (critical system path protected)"
      continue
    fi

    if is_target_mounted "$dst_file"; then
      log_verbose "[SKIP_DUP] $_mod_id -> $dst_file (already mounted)"
      continue
    fi

    orig_ctx=$(get_selinux_ctx "$dst_file")
    if [ "$SELINUX_MIRROR" = "1" ]; then
      apply_selinux_ctx "$src_file" "$orig_ctx" || continue
    fi
    clone_posix_attrs "$dst_file" "$src_file"

    if mount -o bind "$src_file" "$dst_file" 2>>"$LOG_FILE"; then
      mount -o remount,ro,bind "$dst_file" 2>/dev/null || true
      echo "$_mod_id|$dst_file|$src_file|FILE_BIND" >> "$ACTIVE_MOUNTS"
      log_verbose "[MOUNT] $_mod_id -> $dst_file (ctx: ${orig_ctx:-default})"
    fi
  done
}

if [ -s "$ELIGIBLE_TREES" ]; then
  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -n "$_t_mod" ] && [ -d "$_t_src" ] || continue
    mount_tree "$_t_src" "$_t_dst" "$_t_mod"
  done < "$ELIGIBLE_TREES"
fi

sync_ledgers
_tot_active=$(wc -l < "$ACTIVE_MOUNTS" 2>/dev/null | tr -d ' ')
_tot_mirrors=$(count_ledger_type DIR_MIRROR)
_tot_binds=$(count_ledger_type FILE_BIND)
echo "$BOOT_ID" > "$CONF_DIR/.last_mount_boot_id"
log_msg "[SUMMARY] Active: ${_tot_active:-0} (DIR_MIRROR: ${_tot_mirrors:-0}, FILE_BIND: ${_tot_binds:-0}) | Ledger: $DEV_LEDGER"
log_msg "=== UniMount Complete ==="

# Detached post-mount health check for late-load ephemeral root environments
if [ "$BOOT_COMPLETED" = "1" ] && [ "$BOOTLOOP_GUARD" = "1" ]; then
  _orig_ss_pid=$(pidof system_server 2>/dev/null || echo "")
  (
    trap - EXIT INT TERM
    sleep 25
    _now_ss_pid=$(pidof system_server 2>/dev/null || echo "")
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && [ -n "$_orig_ss_pid" ] && [ "$_now_ss_pid" = "$_orig_ss_pid" ]; then
      reset_bootloop_guard
    fi
  ) </dev/null >/dev/null 2>&1 &
fi
