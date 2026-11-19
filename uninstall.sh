#!/system/bin/sh
if [ "$(readlink /data/adb/metamodule 2>/dev/null)" = "/data/adb/modules/unimount" ]; then
  rm -f /data/adb/metamodule
fi
