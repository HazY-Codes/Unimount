#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}
sh "$MODDIR/metamount.sh"
_summary=$(grep -E '^\[SUMMARY\]' /data/adb/unimount/mount.log 2>/dev/null | tail -n 1)
if [ -n "$_summary" ]; then
  echo "UniMount v2.5.0: $_summary"
else
  echo "UniMount v2.5.0: Reconciled module mounts. Check WebUI or /data/adb/unimount/mount.log for status."
fi
