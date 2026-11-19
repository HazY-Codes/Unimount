#!/system/bin/sh
MODDIR=${0%/*}
mkdir -p /data/adb/unimount
mkdir -p /data/adb/unimount/mirror
[ -f /data/adb/unimount/config.conf ] || echo "MOUNT_MODE=auto
SELINUX_MIRROR=1
SKIP_ZYGISK_ONLY=1
LOG_VERBOSE=1" > /data/adb/unimount/config.conf
[ -f /data/adb/unimount/modules.txt ] || touch /data/adb/unimount/modules.txt
