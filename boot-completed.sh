#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOG_FILE="$CONF_DIR/mount.log"

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

mkdir -p "$CONF_DIR"

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
echo "0" > "$CONF_DIR/.boot_fail_count"
echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
rm -f "$CONF_DIR/.bypass_boot_id"

if [ -f "$LOG_FILE" ]; then
  echo "[BOOT_OK] $(date '+%Y-%m-%d %H:%M:%S') Boot completed cleanly; bootloop guard reset (boot_id: $BOOT_ID)" >> "$LOG_FILE"
fi
