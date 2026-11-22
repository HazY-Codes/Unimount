#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
mkdir -p "$CONF_DIR"

# Stand down if UniMount is disabled/removed or another metamodule owns /data/adb/metamodule
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  exit 0
fi

if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-unimount}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    exit 0
  fi
fi

# Track execution per kernel boot_id instead of persistent mount.log presence
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
LAST_BOOT_ID=$(cat "$CONF_DIR/.last_mount_boot_id" 2>/dev/null || echo "")

if [ "$BOOT_ID" != "$LAST_BOOT_ID" ]; then
  sh "$MODDIR/metamount.sh"
fi
