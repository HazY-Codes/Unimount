#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
if [ "$(readlink /data/adb/metamodule 2>/dev/null)" = "/data/adb/modules/unimount" ]; then
  rm -f /data/adb/metamodule
fi
rm -f /dev/unimount_active_mounts 2>/dev/null
rm -rf /data/adb/unimount/.lock 2>/dev/null
