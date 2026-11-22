#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOG_FILE="$CONF_DIR/mount.log"

mkdir -p "$CONF_DIR"

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
echo "0" > "$CONF_DIR/.boot_fail_count"
echo "$BOOT_ID" > "$CONF_DIR/.last_good_boot_id"
rm -f "$CONF_DIR/.bypass_boot_id"

if [ -f "$LOG_FILE" ]; then
  echo "[BOOT_OK] $(date '+%Y-%m-%d %H:%M:%S') Boot completed cleanly; bootloop guard counter reset (boot_id: $BOOT_ID)" >> "$LOG_FILE"
fi
