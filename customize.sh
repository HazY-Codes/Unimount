#!/system/bin/sh
SKIPUNZIP=0

ui_print "- Installing UniMount v2.4.2 (Knox 0x0 Safe)"
mkdir -p /data/adb/unimount
mkdir -p /data/adb/unimount/mirror

if [ ! -f /data/adb/unimount/config.conf ]; then
  cat << 'EOF' > /data/adb/unimount/config.conf
MOUNT_MODE=auto
SELINUX_MIRROR=1
SKIP_ZYGISK_ONLY=1
LOG_VERBOSE=1
EOF
fi

if [ ! -f /data/adb/unimount/modules.txt ]; then
  touch /data/adb/unimount/modules.txt
fi

# Clean up orphaned Zygisk and mount-engine residue safely (/data/adb allowlist only)
cleanup_orphan_dir() {
  _data_dir="$1"
  shift
  [ -d "/data/adb/$_data_dir" ] || return 0
  for _mod_id in "$@"; do
    if [ -d "/data/adb/modules/$_mod_id" ] || [ -d "/data/adb/modules_update/$_mod_id" ]; then
      return 0
    fi
  done
  ui_print "- Purging orphaned /data/adb/$_data_dir residue..."
  rm -rf "/data/adb/$_data_dir"
}

cleanup_orphan_dir brezygisk brezygisk
cleanup_orphan_dir rezygisk rezygisk
cleanup_orphan_dir zygisksu zygisksu neo_zygisk
cleanup_orphan_dir neo_zygisk neo_zygisk zygisksu
cleanup_orphan_dir hybrid_mount hybrid_mount meta-hybrid_mount
cleanup_orphan_dir magic_mount magic_mount magic_mount_rs
cleanup_orphan_dir mountify mountify
cleanup_orphan_dir nanomount nanomount
cleanup_orphan_dir nomount nomount

# Ensure metamodule symlink points to unimount if operating as metamodule
if [ ! -e /data/adb/metamodule ]; then
  ln -sf /data/adb/modules/unimount /data/adb/metamodule
fi

chmod 0755 "$MODPATH/metamount.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" 2>/dev/null
ui_print "- WebUI installed: Open via KernelSU Manager -> UniMount"
