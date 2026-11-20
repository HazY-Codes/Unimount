#!/system/bin/sh
SKIPUNZIP=0

abort_install() {
  ui_print "! $1"
  if command -v abort >/dev/null 2>&1; then
    abort "$1"
  else
    exit 1
  fi
}

ui_print "- Installing UniMount v2.4.4 (Knox 0x0 Safe)"

# 1. Defensive single-metamodule conflict guard (covers custom/older ksud & UniRoot)
if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-/data/adb/metamodule}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    if [ -d "/data/adb/modules/$_meta_id" ] && [ ! -f "/data/adb/modules/$_meta_id/remove" ]; then
      abort_install "Active metamodule '$_meta_id' detected at /data/adb/metamodule. Uninstall it before installing UniMount."
    elif [ -d "$_meta_target" ] && [ ! -f "$_meta_target/remove" ]; then
      abort_install "Active metamodule '$_meta_id' detected at /data/adb/metamodule. Uninstall it before installing UniMount."
    fi
  fi
fi

for _base in /data/adb/modules /data/adb/modules_update; do
  [ -d "$_base" ] || continue
  for _mod_dir in "$_base"/*; do
    [ -d "$_mod_dir" ] || continue
    _mod_id=$(basename "$_mod_dir")
    [ "$_mod_id" = "unimount" ] && continue
    [ -f "$_mod_dir/remove" ] && continue
    if [ -f "$_mod_dir/module.prop" ] && grep -Eq '^[[:space:]]*metamodule[[:space:]]*=[[:space:]]*(1|true)[[:space:]]*$' "$_mod_dir/module.prop" 2>/dev/null; then
      abort_install "Conflicting metamodule '$_mod_id' detected in $_base. Uninstall '$_mod_id' before installing UniMount."
    fi
  done
done

# Non-fatal warning if standalone non-metamodule mount engines are enabled
for _engine in mountify magic_mount magic_mount_rs hybrid_mount meta-hybrid_mount nanomount nomount; do
  if [ -d "/data/adb/modules/$_engine" ] && [ ! -f "/data/adb/modules/$_engine/disable" ] && [ ! -f "/data/adb/modules/$_engine/remove" ]; then
    ui_print "! Warning: Active mount engine '$_engine' detected; disable or remove it to prevent double-mounting."
  fi
done

mkdir -p /data/adb/unimount
mkdir -p /data/adb/unimount/mirror

if [ ! -f /data/adb/unimount/config.conf ]; then
  cat << 'EOF' > /data/adb/unimount/config.conf
MOUNT_MODE=auto
SELINUX_MIRROR=1
SKIP_ZYGISK_ONLY=1
LOG_VERBOSE=1
BOOTLOOP_GUARD=1
PROTECT_CRITICAL_PATHS=1
EOF
else
  # Preserve user settings while appending newly introduced v2.4.4 defaults
  grep -Eq '^[[:space:]]*SKIP_ZYGISK_ONLY=' /data/adb/unimount/config.conf 2>/dev/null || echo "SKIP_ZYGISK_ONLY=1" >> /data/adb/unimount/config.conf
  grep -Eq '^[[:space:]]*BOOTLOOP_GUARD=' /data/adb/unimount/config.conf 2>/dev/null || echo "BOOTLOOP_GUARD=1" >> /data/adb/unimount/config.conf
  grep -Eq '^[[:space:]]*PROTECT_CRITICAL_PATHS=' /data/adb/unimount/config.conf 2>/dev/null || echo "PROTECT_CRITICAL_PATHS=1" >> /data/adb/unimount/config.conf
fi

if [ ! -f /data/adb/unimount/modules.txt ]; then
  touch /data/adb/unimount/modules.txt
fi

# Reset any stale bootloop bypass state on fresh install / upgrade
rm -f /data/adb/unimount/.bypass_boot_id
echo "0" > /data/adb/unimount/.boot_fail_count

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

# Ensure metamodule symlink points to unimount if no active metamodule exists
if [ ! -e /data/adb/metamodule ]; then
  rm -f /data/adb/metamodule 2>/dev/null
  ln -sf /data/adb/modules/unimount /data/adb/metamodule
fi

chmod 0755 "$MODPATH/metamount.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/boot-completed.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" 2>/dev/null
ui_print "- WebUI installed: Open via KernelSU Manager -> UniMount"
