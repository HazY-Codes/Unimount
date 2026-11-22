#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

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

mkdir -p "$CONF_DIR" "$MIRROR_ROOT"

# Normal mount runs stand down if UniMount is disabled or another metamodule owns /data/adb/metamodule
case "$ACTION_MODE" in
  --unmount-all|unmount|unmount-all) ;;
  *)
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      exit 0
    fi

    if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
      _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
      _meta_id=$(basename "${_meta_target:-unimount}")
      if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
        echo "[ABORT] /data/adb/metamodule belongs to '$_meta_id'; UniMount standing down." >> "$LOG_FILE"
        exit 0
      fi
    fi
    ;;
esac

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
trap 'rm -rf "$LOCK_DIR" "$CONF_DIR"/.mirror_*.tmp "$CONF_DIR"/.mirrored_ancs.tmp "$CONF_DIR"/.active_mounts.tmp "$CONF_DIR"/.unmount_*.tmp 2>/dev/null' EXIT INT TERM

sync_ledgers() {
  [ -f "$ACTIVE_MOUNTS" ] || : > "$ACTIVE_MOUNTS"
  if [ -w /dev ] || [ -w "$DEV_LEDGER" ]; then
    cp -f "$ACTIVE_MOUNTS" "$DEV_LEDGER" 2>/dev/null && chmod 0600 "$DEV_LEDGER" 2>/dev/null || true
  fi
}

is_target_mounted() {
  _tgt="$1"
  if [ -r /proc/self/mountinfo ]; then
    awk -v tgt="$_tgt" '
      {
        mp = $5
        gsub(/\\040/, " ", mp)
        if (mp == tgt) { found=1; exit }
      }
      END { exit !found }
    ' /proc/self/mountinfo 2>/dev/null
    return $?
  fi
  awk -v tgt="$_tgt" '
    {
      mp = $2
      gsub(/\\040/, " ", mp)
      if (mp == tgt) { found=1; exit }
    }
    END { exit !found }
  ' /proc/mounts 2>/dev/null
}

list_mounts_under_prefix() {
  _pfx="${1%/}"
  if [ -r /proc/self/mountinfo ]; then
    awk -v pfx="$_pfx" '
      {
        mp = $5
        gsub(/\\040/, " ", mp)
        if (mp == pfx || substr(mp, 1, length(pfx) + 1) == pfx "/") {
          print length(mp) "\t" mp
        }
      }
    ' /proc/self/mountinfo 2>/dev/null | sort -rn | cut -f2-
  else
    awk -v pfx="$_pfx" '
      {
        mp = $2
        gsub(/\\040/, " ", mp)
        if (mp == pfx || substr(mp, 1, length(pfx) + 1) == pfx "/") {
          print length(mp) "\t" mp
        }
      }
    ' /proc/mounts 2>/dev/null | sort -rn | cut -f2-
  fi
}

list_active_mirror_targets() {
  _m_pfx="${MIRROR_ROOT%/}"
  if [ -r /proc/self/mountinfo ]; then
    awk -v mpfx="$_m_pfx" '
      $4 ~ /\/unimount\/mirror\/merged/ {
        mp = $5
        gsub(/\\040/, " ", mp)
        if (mp != mpfx && substr(mp, 1, length(mpfx) + 1) != mpfx "/") {
          print length(mp) "\t" mp
        }
      }
    ' /proc/self/mountinfo 2>/dev/null | sort -rn | cut -f2-
  else
    awk -v mpfx="$_m_pfx" '
      $1 ~ /\/unimount\/mirror\/merged/ {
        mp = $2
        gsub(/\\040/, " ", mp)
        if (mp != mpfx && substr(mp, 1, length(mpfx) + 1) != mpfx "/") {
          print length(mp) "\t" mp
        }
      }
    ' /proc/mounts 2>/dev/null | sort -rn | cut -f2-
  fi
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
        list_mounts_under_prefix "$_u_dst" | while IFS= read -r _sub_mp; do
          [ -n "$_sub_mp" ] || continue
          umount "$_sub_mp" 2>/dev/null || umount -l "$_sub_mp" 2>>"$LOG_FILE"
        done
        if is_target_mounted "$_u_dst"; then
          if umount "$_u_dst" 2>/dev/null || umount -l "$_u_dst" 2>>"$LOG_FILE"; then
            _detached_mirrors=$((_detached_mirrors + 1))
            echo "[EMERGENCY_UNMOUNT] ${_u_mod:-unknown} -> $_u_dst (DIR_MIRROR)" >> "$LOG_FILE"
          else
            _failed=$((_failed + 1))
            echo "[WARN_UNMOUNT] Failed to detach mirror $_u_dst" >> "$LOG_FILE"
          fi
        elif [ "$_was_mounted" = "1" ]; then
          _detached_mirrors=$((_detached_mirrors + 1))
          echo "[EMERGENCY_UNMOUNT] ${_u_mod:-unknown} -> $_u_dst (DIR_MIRROR)" >> "$LOG_FILE"
        fi
      else
        if is_target_mounted "$_u_dst"; then
          if umount "$_u_dst" 2>/dev/null || umount -l "$_u_dst" 2>>"$LOG_FILE"; then
            _detached_binds=$((_detached_binds + 1))
            echo "[EMERGENCY_UNMOUNT] ${_u_mod:-unknown} -> $_u_dst (FILE_BIND)" >> "$LOG_FILE"
          else
            _failed=$((_failed + 1))
            echo "[WARN_UNMOUNT] Failed to detach bind $_u_dst" >> "$LOG_FILE"
          fi
        fi
      fi
    done < "$_ordered"
  fi

  # Tear down any remaining active mirror targets and inner mirror bind-mounts in reverse order
  list_active_mirror_targets | while IFS= read -r _m_tgt; do
    [ -n "$_m_tgt" ] || continue
    list_mounts_under_prefix "$_m_tgt" | while IFS= read -r _sub_mp; do
      [ -n "$_sub_mp" ] || continue
      umount "$_sub_mp" 2>/dev/null || umount -l "$_sub_mp" 2>/dev/null
    done
    umount "$_m_tgt" 2>/dev/null || umount -l "$_m_tgt" 2>/dev/null
  done

  list_mounts_under_prefix "$MIRROR_ROOT" | while IFS= read -r _inner_mp; do
    [ -n "$_inner_mp" ] || continue
    umount "$_inner_mp" 2>/dev/null || umount -l "$_inner_mp" 2>/dev/null
  done

  _rem_mounts=$(list_mounts_under_prefix "$MIRROR_ROOT")
  if [ -z "$_rem_mounts" ]; then
    rm -rf "$MIRROR_ROOT/merged" 2>/dev/null
    mkdir -p "$MIRROR_ROOT/merged"
  else
    echo "[WARN_MIRROR] Active mounts remain under $MIRROR_ROOT after emergency unmount; skipped rm -rf." >> "$LOG_FILE"
  fi

  rm -f "$_combined" "$_ordered" 2>/dev/null
  : > "$ACTIVE_MOUNTS"
  sync_ledgers

  echo "[EMERGENCY_UNMOUNT] $(date '+%Y-%m-%d %H:%M:%S') Detached $_detached_binds FILE_BIND and $_detached_mirrors DIR_MIRROR mount(s) (failed: $_failed)" >> "$LOG_FILE"
  echo "UniMount v2.5.0: Detached $_detached_binds file bind(s) and $_detached_mirrors directory mirror(s) (failed: $_failed)."
  exit 0
}

case "$ACTION_MODE" in
  --unmount-all|unmount|unmount-all)
    unmount_all_mounts
    ;;
esac


# Load configuration defaults
MOUNT_MODE="auto"
SELINUX_MIRROR="1"
DIR_MIRROR_INJECT="1"
SKIP_ZYGISK_ONLY="1"
LOG_VERBOSE="1"
BOOTLOOP_GUARD="1"
PROTECT_CRITICAL_PATHS="1"
[ -f "$CONF_DIR/config.conf" ] && . "$CONF_DIR/config.conf"

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
PREV_MOUNT_BOOT_ID=$(cat "$CONF_DIR/.last_mount_boot_id" 2>/dev/null || echo "")
BOOT_COMPLETED=$(getprop sys.boot_completed 2>/dev/null || echo "0")
SELINUX_STATE=$(getenforce 2>/dev/null || echo "Enforcing")

echo "=== UniMount v2.5.0 Run: $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
echo "[INFO] Mode: $MOUNT_MODE | SELinux: $SELINUX_STATE (Mirror: $SELINUX_MIRROR) | DirMirror: $DIR_MIRROR_INJECT | Guard: $BOOTLOOP_GUARD | CriticalProtect: $PROTECT_CRITICAL_PATHS" >> "$LOG_FILE"

# Safe Mode bypass (Android Safe Mode or KernelSU safe-mode marker)
SAFE_PERSIST=$(getprop persist.sys.safemode 2>/dev/null || echo "0")
SAFE_RO=$(getprop ro.sys.safemode 2>/dev/null || echo "0")
if [ "$SAFE_PERSIST" = "1" ] || [ "$SAFE_RO" = "1" ] || [ -f /data/adb/ksu/.safemode ]; then
  echo "[SAFE_MODE] Safe Mode detected; skipping all overlays." >> "$LOG_FILE"
  exit 0
fi

# Clear active mount ledgers only on a new cold boot (preserved across soft reboots)
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

# Bootloop circuit breaker (supports both early-boot KSU and late-load ephemeral root: UniRoot, DFRoot, GhostLock)
if [ "$BOOTLOOP_GUARD" = "1" ]; then
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
      echo "[SAFE_BYPASS] Bootloop guard triggered ($FAIL_COUNT consecutive incomplete boots/mounts); skipping all mounts. Reset via WebUI or normal boot completion." >> "$LOG_FILE"
      exit 0
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "$FAIL_COUNT" > "$CONF_DIR/.boot_fail_count"
    echo "$BOOT_ID" > "$CONF_DIR/.last_attempt_boot_id"
  elif [ "$BOOT_COMPLETED" = "1" ]; then
    echo "0" > "$CONF_DIR/.boot_fail_count"
    echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
    rm -f "$CONF_DIR/.bypass_boot_id"
  fi
elif [ "$BOOT_COMPLETED" = "1" ]; then
  echo "0" > "$CONF_DIR/.boot_fail_count"
  echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
  rm -f "$CONF_DIR/.bypass_boot_id"
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
  if [ -r /proc/self/mountinfo ]; then
    _sub_mps=$(awk -v pfx="$_anc_dir" '
      {
        mp = $5
        gsub(/\\040/, " ", mp)
        if (substr(mp, 1, length(pfx) + 1) == pfx "/") {
          if ($4 !~ /\/adb\/modules\// && $4 !~ /\/unimount\/mirror\//) {
            print mp
          }
        }
      }
    ' /proc/self/mountinfo 2>/dev/null)
  else
    _sub_mps=$(awk -v pfx="$_anc_dir" '
      {
        mp = $2
        gsub(/\\040/, " ", mp)
        if (substr(mp, 1, length(pfx) + 1) == pfx "/") {
          if ($1 !~ /\/adb\/modules\// && $1 !~ /\/unimount\/mirror\//) {
            print mp
          }
        }
      }
    ' /proc/mounts 2>/dev/null)
  fi
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
  [ "$_found_non_uni" = "1" ] && return 0
  return 1
}

find_deepest_ancestor() {
  _p="$1"
  _cur=$(dirname "$_p")
  while [ -n "$_cur" ] && [ "$_cur" != "/" ] && [ "$_cur" != "." ]; do
    if [ -d "$_cur" ] && [ ! -L "$_cur" ]; then
      echo "$_cur"
      return 0
    fi
    _cur=$(dirname "$_cur")
  done
  echo "/"
  return 0
}

get_selinux_ctx() {
  ls -Zd "$1" 2>/dev/null | awk '{print $1}'
}

clone_posix_attrs() {
  _src_p="$1"
  _dst_p="$2"
  [ -L "$_dst_p" ] && return 0
  _stat_info=$(stat -c '%a %u %g' "$_src_p" 2>/dev/null)
  if [ -n "$_stat_info" ]; then
    set -- $_stat_info
    [ -n "$1" ] && chmod "$1" "$_dst_p" 2>/dev/null
    [ -n "$2" ] && [ -n "$3" ] && chown "$2:$3" "$_dst_p" 2>/dev/null
  fi
}

apply_selinux_ctx() {
  _target="$1"
  _want_ctx="$2"
  [ "$SELINUX_MIRROR" = "1" ] || return 0

  case "$_want_ctx" in
    u:object_r:*)
      _chcon_ok=0
      if [ -L "$_target" ]; then
        if chcon -h "$_want_ctx" "$_target" 2>/dev/null; then
          _new_ctx=$(get_selinux_ctx "$_target")
          [ "$_new_ctx" = "$_want_ctx" ] && _chcon_ok=1
        fi
      else
        if chcon "$_want_ctx" "$_target" 2>/dev/null; then
          _new_ctx=$(get_selinux_ctx "$_target")
          [ "$_new_ctx" = "$_want_ctx" ] && _chcon_ok=1
        fi
      fi
      if [ "$_chcon_ok" != "1" ]; then
        if [ "$SELINUX_STATE" = "Enforcing" ]; then
          echo "[SKIP_SELINUX] $_target (chcon failed under Enforcing: want $_want_ctx)" >> "$LOG_FILE"
          return 1
        else
          echo "[WARN_SELINUX] $_target (chcon failed under $SELINUX_STATE: want $_want_ctx)" >> "$LOG_FILE"
          return 0
        fi
      fi
      return 0
      ;;
    *)
      if [ "$SELINUX_STATE" = "Enforcing" ]; then
        echo "[SKIP_SELINUX] $_target (unreadable SELinux context '$_want_ctx' under Enforcing)" >> "$LOG_FILE"
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
      u:object_r:*)
        echo "$_ctx"
        return 0
        ;;
    esac
  fi

  if [ -n "$_src_item" ] && { [ -e "$_src_item" ] || [ -L "$_src_item" ]; }; then
    _sctx=$(get_selinux_ctx "$_src_item")
    case "$_sctx" in
      u:object_r:*adb_data_file*|u:object_r:*system_data_file*|u:object_r:*magisk_file*|u:object_r:*ksu_file*|u:object_r:*unlabeled*)
        ;;
      u:object_r:*)
        echo "$_sctx"
        return 0
        ;;
    esac
  fi

  _near_anc=$(find_deepest_ancestor "$_dst_item")
  if [ -n "$_near_anc" ] && [ -d "$_near_anc" ]; then
    _actx=$(get_selinux_ctx "$_near_anc")
    case "$_actx" in
      u:object_r:*)
        echo "$_actx"
        return 0
        ;;
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
    grep -Fxq "$_mid" "$CONF_DIR/modules.txt" 2>/dev/null || return 1
  fi
  return 0
}

# Safe Mirror Teardown & Stale Mount Reconciliation
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
        list_mounts_under_prefix "$_rec_dst" | while IFS= read -r _sub_mp; do
          [ -n "$_sub_mp" ] || continue
          umount "$_sub_mp" 2>/dev/null || umount -l "$_sub_mp" 2>>"$LOG_FILE"
        done
        if is_target_mounted "$_rec_dst"; then
          umount "$_rec_dst" 2>/dev/null || umount -l "$_rec_dst" 2>>"$LOG_FILE"
        fi
        [ "$LOG_VERBOSE" = "1" ] && echo "[UNMOUNT_MIRROR] $_rec_mod -> $_rec_dst (tearing down previous mirror)" >> "$LOG_FILE"
      else
        _src_ok=1
        if [ -n "$_rec_src" ] && [ ! -f "$_rec_src" ]; then
          _src_ok=0
        fi
        if [ "$_src_ok" = "1" ] && module_is_eligible "$_rec_mod"; then
          if is_target_mounted "$_rec_dst"; then
            echo "$_rec_mod|$_rec_dst|$_rec_src|FILE_BIND" >> "$_tmp_list"
          fi
        else
          if is_target_mounted "$_rec_dst"; then
            umount "$_rec_dst" 2>/dev/null || umount -l "$_rec_dst" 2>>"$LOG_FILE"
            echo "[UNMOUNT] $_rec_mod -> $_rec_dst (stale/disabled module)" >> "$LOG_FILE"
          fi
        fi
      fi
    done < "$ACTIVE_MOUNTS"
    mv "$_tmp_list" "$ACTIVE_MOUNTS"
    sync_ledgers
  fi

  # Unmount any leftover mirror target mounts detected via mountinfo
  list_active_mirror_targets | while IFS= read -r _m_tgt; do
    [ -n "$_m_tgt" ] || continue
    list_mounts_under_prefix "$_m_tgt" | while IFS= read -r _sub_mp; do
      [ -n "$_sub_mp" ] || continue
      umount "$_sub_mp" 2>/dev/null || umount -l "$_sub_mp" 2>/dev/null
    done
    umount "$_m_tgt" 2>/dev/null || umount -l "$_m_tgt" 2>/dev/null
  done

  # Unmount any inner child bind-mounts inside $MIRROR_ROOT in reverse depth/length order
  list_mounts_under_prefix "$MIRROR_ROOT" | while IFS= read -r _inner_mp; do
    [ -n "$_inner_mp" ] || continue
    umount "$_inner_mp" 2>/dev/null || umount -l "$_inner_mp" 2>/dev/null
  done

  # Strict safety check before rm -rf: verify ZERO active mount points remain under $MIRROR_ROOT
  _rem_mounts=$(list_mounts_under_prefix "$MIRROR_ROOT")
  if [ -n "$_rem_mounts" ]; then
    echo "[WARN_MIRROR] Active mount points still remain under $MIRROR_ROOT; skipping rm -rf to protect mounted subtrees." >> "$LOG_FILE"
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
          umount "$_rec_dst" 2>/dev/null || umount -l "$_rec_dst" 2>/dev/null
          [ "$LOG_VERBOSE" = "1" ] && echo "[UNMOUNT] $_rec_mod -> $_rec_dst (absorbed into $_anc_pfx directory mirror)" >> "$LOG_FILE"
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
  _rb_anc="$1"
  _rb_mirror="$MIRROR_ROOT/merged$_rb_anc"
  list_mounts_under_prefix "$_rb_mirror" | while IFS= read -r _rb_mp; do
    [ -n "$_rb_mp" ] || continue
    umount "$_rb_mp" 2>/dev/null || umount -l "$_rb_mp" 2>/dev/null
  done
  _rb_rem=$(list_mounts_under_prefix "$_rb_mirror")
  if [ -z "$_rb_rem" ]; then
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
        _rel_p="${_chk_dir#$_t_dst/}"
        _m_p="$_t_src/$_rel_p"
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
      "$_m_anc"|"$_m_anc"/*)
        return 0
        ;;
    esac
  done < "$MIRRORED_ANCS"
  return 1
}

teardown_and_reconcile_mounts

: > "$ELIGIBLE_TREES"
: > "$CAND_ANCS"
: > "$FINAL_ANCS"
: > "$MIRRORED_ANCS"

# Collect eligible modules and partition trees (with cross-partition SAR symlink routing)
for mod in "$MODULES_DIR"/*; do
  [ ! -d "$mod" ] && continue
  mod_id=$(basename "$mod")
  [ "$mod_id" = "unimount" ] && continue

  if [ -f "$mod/disable" ] || [ -f "$mod/remove" ] || [ -f "$mod/skip_mount" ] || [ -f "$mod/skip_unimount" ]; then
    [ "$LOG_VERBOSE" = "1" ] && echo "[SKIP] $mod_id (disabled or skip flag present)" >> "$LOG_FILE"
    continue
  fi

  if [ "$MOUNT_MODE" = "manual" ]; then
    if ! grep -Fxq "$mod_id" "$CONF_DIR/modules.txt" 2>/dev/null; then
      [ "$LOG_VERBOSE" = "1" ] && echo "[SKIP] $mod_id (not in manual modules.txt whitelist)" >> "$LOG_FILE"
      continue
    fi
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
    [ "$LOG_VERBOSE" = "1" ] && echo "[INFO] $mod_id: Zygisk / service-only module (no partition overlay)" >> "$LOG_FILE"
  fi
done

# ============================================================================
# PASS 1: Deepest-Existing-Ancestor Mirror Discovery & Multi-Module Staging
# ============================================================================
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
        if [ -d "$_dst_path" ] && [ ! -L "$_dst_path" ]; then
          continue
        fi
        # Only evaluate non-existent directory directly if it is empty; non-empty dirs are discovered via their files/symlinks
        _has_child=$(find "$_entry" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)
        [ -n "$_has_child" ] && continue
      elif [ -f "$_entry" ] && [ ! -L "$_entry" ]; then
        # Existing regular non-symlink target file is handled by Pass 2 FILE_BIND unless parent is mirrored
        if [ -f "$_dst_path" ] && [ ! -L "$_dst_path" ]; then
          continue
        fi
      fi

      if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_dst_path"; then
        echo "[BLOCKED] $_t_mod -> $_dst_path (critical system path protected)" >> "$LOG_FILE"
        continue
      fi

      if [ "$DIR_MIRROR_INJECT" != "1" ]; then
        echo "[SKIP_NEW] $_t_mod -> $_dst_path (DIR_MIRROR_INJECT=0)" >> "$LOG_FILE"
        continue
      fi

      _anc=$(find_deepest_ancestor "$_dst_path")
      if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_anc"; then
        echo "[BLOCKED] $_t_mod -> $_anc (critical system path protected)" >> "$LOG_FILE"
        continue
      fi

      if is_protected_container "$_anc" || has_child_submounts "$_anc"; then
        echo "[BLOCKED_MIRROR] $_t_mod -> $_anc (contains active child sub-mount or protected container)" >> "$LOG_FILE"
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
    if [ "$_nested" = "0" ]; then
      echo "$_cand" >> "$FINAL_ANCS"
    fi
  done
}

build_and_mount_mirror_anc() {
  _anc="$1"
  _mirror_anc="$MIRROR_ROOT/merged$_anc"

  unmount_file_binds_under_anc "$_anc"

  # 1. Identify all existing directories under $_anc touched by any eligible module
  : > "$TOUCHED_DIRS.raw"
  echo "$_anc" >> "$TOUCHED_DIRS.raw"

  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -n "$_t_src" ] && [ -n "$_t_dst" ] || continue
    case "$_anc" in
      "$_t_dst"/*)
        _rel_anc="${_anc#$_t_dst/}"
        _mod_anc_src="$_t_src/$_rel_anc"
        if [ -d "$_mod_anc_src" ] && [ ! -L "$_mod_anc_src" ]; then
          find "$_mod_anc_src" -type d 2>/dev/null | while IFS= read -r _md; do
            [ "$_md" = "$_mod_anc_src" ] && continue
            _sub_rel="${_md#$_mod_anc_src/}"
            _cand_orig_dir="$_anc/$_sub_rel"
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

  # 2. Populate $MIRROR_ROOT/merged$_anc from stock $_anc (recursing touched dirs, bind-mounting untouched subdirs)
  : > "$INNER_BINDS"
  _stage_ok=1
  _anc_ctx=$(get_selinux_ctx "$_anc")

  while IFS= read -r _orig_dir; do
    [ -n "$_orig_dir" ] || continue
    _m_dir="$MIRROR_ROOT/merged$_orig_dir"
    mkdir -p "$_m_dir"
    clone_posix_attrs "$_orig_dir" "$_m_dir"
    _d_ctx=$(get_selinux_ctx "$_orig_dir")
    if ! apply_selinux_ctx "$_m_dir" "$_d_ctx"; then
      _stage_ok=0
      break
    fi

    for _item in "$_orig_dir"/* "$_orig_dir"/.[!.]* "$_orig_dir"/..?*; do
      [ -e "$_item" ] || [ -L "$_item" ] || continue
      _bname=$(basename "$_item")
      _m_item="$_m_dir/$_bname"

      if [ -L "$_item" ]; then
        rm -rf "$_m_item" 2>/dev/null
        cp -P "$_item" "$_m_item" 2>/dev/null || ln -s "$(readlink "$_item")" "$_m_item" 2>/dev/null
        _i_ctx=$(get_selinux_ctx "$_item")
        if ! apply_selinux_ctx "$_m_item" "$_i_ctx"; then
          _stage_ok=0
          break
        fi
      elif [ -d "$_item" ]; then
        if grep -Fxq "$_item" "$TOUCHED_DIRS" 2>/dev/null; then
          mkdir -p "$_m_item"
        elif module_replaces_dir_with_nondir "$_item"; then
          :
        else
          mkdir -p "$_m_item"
          clone_posix_attrs "$_item" "$_m_item"
          _i_ctx=$(get_selinux_ctx "$_item")
          if ! apply_selinux_ctx "$_m_item" "$_i_ctx"; then
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
        _i_ctx=$(get_selinux_ctx "$_item")
        if ! apply_selinux_ctx "$_m_item" "$_i_ctx"; then
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

  # 3. Overlay all eligible modules' entries targeting $_anc/* into $MIRROR_ROOT/merged$_anc
  _mods_for_anc=""
  _mod_dirs_tmp="$CONF_DIR/.mirror_mod_dirs.tmp"
  _mod_files_tmp="$CONF_DIR/.mirror_mod_files.tmp"

  while IFS='|' read -r _t_mod _t_src _t_dst; do
    [ -n "$_t_src" ] && [ -n "$_t_dst" ] || continue
    case "$_anc" in
      "$_t_dst"/*)
        _rel_anc="${_anc#$_t_dst/}"
        _mod_anc_src="$_t_src/$_rel_anc"
        [ -d "$_mod_anc_src" ] && [ ! -L "$_mod_anc_src" ] || continue

        _mod_contributed=0

        # Stage directories in topological length order
        find "$_mod_anc_src" -type d 2>/dev/null | awk '{ print length($0) "\t" $0 }' | sort -n | cut -f2- > "$_mod_dirs_tmp"
        while IFS= read -r _src_d; do
          [ -n "$_src_d" ] && [ "$_src_d" != "$_mod_anc_src" ] || continue
          _sub_rel="${_src_d#$_mod_anc_src/}"
          _dst_d="$_anc/$_sub_rel"
          _m_d="$MIRROR_ROOT/merged$_dst_d"

          if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_dst_d"; then
            echo "[BLOCKED] $_t_mod -> $_dst_d (critical system path protected)" >> "$LOG_FILE"
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

        # Stage files and symlinks
        find "$_mod_anc_src" \( -type f -o -type l \) 2>/dev/null > "$_mod_files_tmp"
        while IFS= read -r _src_f; do
          [ -n "$_src_f" ] || continue
          _sub_rel="${_src_f#$_mod_anc_src/}"
          _dst_f="$_anc/$_sub_rel"
          _m_f="$MIRROR_ROOT/merged$_dst_f"

          if [ "$PROTECT_CRITICAL_PATHS" = "1" ] && is_critical_path "$_dst_f"; then
            echo "[BLOCKED] $_t_mod -> $_dst_f (critical system path protected)" >> "$LOG_FILE"
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
          [ "$LOG_VERBOSE" = "1" ] && echo "[MIRROR_STAGE] $_t_mod -> $_dst_f (ctx: ${_want_ctx:-default})" >> "$LOG_FILE"
        done < "$_mod_files_tmp"

        [ "$_stage_ok" = "1" ] || break

        if [ "$_mod_contributed" = "1" ]; then
          case ",$_mods_for_anc," in
            *,"$_t_mod",*) ;;
            *)
              if [ -z "$_mods_for_anc" ]; then
                _mods_for_anc="$_t_mod"
              else
                _mods_for_anc="$_mods_for_anc,$_t_mod"
              fi
              ;;
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

  # 4. Atomically bind-mount the completed mirror directory onto $_anc
  if mount -o bind "$_mirror_anc" "$_anc" 2>>"$LOG_FILE"; then
    mount -o remount,ro,bind "$_anc" 2>/dev/null || true
    echo "$_mods_for_anc|$_anc|$_mirror_anc|DIR_MIRROR" >> "$ACTIVE_MOUNTS"
    echo "$_anc" >> "$MIRRORED_ANCS"
    echo "[MIRROR_MOUNT] $_mods_for_anc -> $_anc (ctx: ${_anc_ctx:-default})" >> "$LOG_FILE"
    return 0
  else
    rollback_mirror_anc "$_anc"
    return 1
  fi
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

# ============================================================================
# PASS 2: Direct Existing-File Bind Mounts
# ============================================================================
mount_tree() {
  _src_base="$1"
  _dst_base="$2"
  _mod_id="$3"

  [ ! -d "$_src_base" ] && return 0

  find "$_src_base" -type f 2>/dev/null | while IFS= read -r src_file; do
    [ -L "$src_file" ] && continue
    rel_path="${src_file#$_src_base/}"
    is_routed_sar_subpath "$_dst_base" "$rel_path" && continue
    dst_file="$_dst_base/$rel_path"

    # Skip files already handled inside a Pass 1 mirrored ancestor directory
    is_under_mirrored_dir "$dst_file" && continue

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
    clone_posix_attrs "$dst_file" "$src_file"

    # Strict SELinux fail-closed context mirroring under Enforcing
    orig_ctx=$(get_selinux_ctx "$dst_file")
    if [ "$SELINUX_MIRROR" = "1" ]; then
      if ! apply_selinux_ctx "$src_file" "$orig_ctx"; then
        continue
      fi
    fi

    if mount -o bind "$src_file" "$dst_file" 2>>"$LOG_FILE"; then
      mount -o remount,ro,bind "$dst_file" 2>/dev/null || true
      echo "$_mod_id|$dst_file|$src_file|FILE_BIND" >> "$ACTIVE_MOUNTS"
      [ "$LOG_VERBOSE" = "1" ] && echo "[MOUNT] $_mod_id -> $dst_file (ctx: ${orig_ctx:-default})" >> "$LOG_FILE"
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
_tot_mirrors=$(grep -c '|DIR_MIRROR$' "$ACTIVE_MOUNTS" 2>/dev/null || echo 0)
_tot_binds=$(grep -c '|FILE_BIND$' "$ACTIVE_MOUNTS" 2>/dev/null || echo 0)
echo "$BOOT_ID" > "$CONF_DIR/.last_mount_boot_id"
echo "[SUMMARY] Active: ${_tot_active:-0} (DIR_MIRROR: ${_tot_mirrors:-0}, FILE_BIND: ${_tot_binds:-0}) | Ledger: $DEV_LEDGER" >> "$LOG_FILE"
echo "=== UniMount Complete ===" >> "$LOG_FILE"

# Ephemeral-root (UniRoot / DFRoot / GhostLock) post-mount health verification
if [ "$BOOT_COMPLETED" = "1" ] && [ "$BOOTLOOP_GUARD" = "1" ]; then
  (
    sleep 25
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && [ -n "$(pidof system_server 2>/dev/null)" ]; then
      echo "0" > "$CONF_DIR/.boot_fail_count"
      echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
      rm -f "$CONF_DIR/.bypass_boot_id"
    fi
  ) >/dev/null 2>&1 &
fi
