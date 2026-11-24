#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"

_meta_link=$(readlink /data/adb/metamodule 2>/dev/null || echo "")
_meta_real=$(readlink -f /data/adb/metamodule 2>/dev/null || echo "")
if [ "$_meta_link" = "/data/adb/modules/unimount" ] || [ "$_meta_real" = "/data/adb/modules/unimount" ]; then
  rm -f /data/adb/metamodule
fi

rm -f /dev/unimount_active_mounts 2>/dev/null
rm -rf /data/adb/unimount/.lock 2>/dev/null
