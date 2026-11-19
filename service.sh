#!/system/bin/sh
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/mount.log" ]; then
  sh "$MODDIR/metamount.sh"
fi
