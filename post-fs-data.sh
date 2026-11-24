#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOCK_DIR="$CONF_DIR/.lock"

# Stand down if UniMount is disabled/removed or another active metamodule owns /data/adb/metamodule
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  exit 0
fi

if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-unimount}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    if { [ -d "/data/adb/modules/$_meta_id" ] && [ ! -f "/data/adb/modules/$_meta_id/remove" ]; } || \
       { [ -d "$_meta_target" ] && [ ! -f "$_meta_target/remove" ]; }; then
      exit 0
    fi
  fi
fi

mkdir -p "$CONF_DIR" "$CONF_DIR/mirror"

# Clear any stale lock left over from an unexpected crash or hard reboot
if [ -d "$LOCK_DIR" ]; then
  _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  case "$_lock_pid" in
    ''|0|*[!0-9]*)
      rm -rf "$LOCK_DIR" 2>/dev/null
      ;;
    *)
      kill -0 "$_lock_pid" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null
      ;;
  esac
fi

if [ ! -f "$CONF_DIR/config.conf" ]; then
  cat << 'EOF' > "$CONF_DIR/config.conf"
MOUNT_MODE=auto
SELINUX_MIRROR=1
DIR_MIRROR_INJECT=1
SKIP_ZYGISK_ONLY=1
LOG_VERBOSE=1
BOOTLOOP_GUARD=1
PROTECT_CRITICAL_PATHS=1
EOF
fi

[ -f "$CONF_DIR/modules.txt" ] || touch "$CONF_DIR/modules.txt"
