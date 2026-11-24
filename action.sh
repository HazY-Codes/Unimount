#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
MODDIR=${0%/*}

if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  echo "UniMount v2.5.1: Module is disabled or scheduled for removal."
  exit 0
fi

if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-unimount}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    if { [ -d "/data/adb/modules/$_meta_id" ] && [ ! -f "/data/adb/modules/$_meta_id/remove" ]; } || \
       { [ -d "$_meta_target" ] && [ ! -f "$_meta_target/remove" ]; }; then
      echo "UniMount v2.5.1: Standing down because '$_meta_id' owns /data/adb/metamodule."
      exit 0
    fi
  fi
fi

if [ ! -f "$MODDIR/metamount.sh" ]; then
  echo "UniMount v2.5.1: metamount.sh not found in $MODDIR."
  exit 1
fi

sh "$MODDIR/metamount.sh"
_status=$(grep -E '^\[(SUMMARY|SAFE_BYPASS|SAFE_MODE|SKIP|ABORT)\]' /data/adb/unimount/mount.log 2>/dev/null | tail -n 1)
if [ -n "$_status" ]; then
  echo "UniMount v2.5.1: $_status"
else
  echo "UniMount v2.5.1: Check WebUI or /data/adb/unimount/mount.log for status."
fi
