#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOCK_DIR="$CONF_DIR/.lock"

mkdir -p "$CONF_DIR" "$CONF_DIR/mirror"

# Clear any stale lock left over from an unexpected crash or hard reboot
if [ -d "$LOCK_DIR" ]; then
  _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -z "$_lock_pid" ] || ! kill -0 "$_lock_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
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
