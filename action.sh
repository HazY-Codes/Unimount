#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/metamount.sh"
echo "UniMount: Reconciled module mounts. Check WebUI for status."
