#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/metamount.sh"
echo "UniMount v2.4.3: Reconciled module mounts. Check WebUI or /data/adb/unimount/mount.log for status."
