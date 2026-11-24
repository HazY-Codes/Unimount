#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/vendor/bin:$PATH"
SKIPUNZIP=0

CONF_DIR="/data/adb/unimount"
CONF_FILE="$CONF_DIR/config.conf"

abort_install() {
  ui_print "! $1"
  if command -v abort >/dev/null 2>&1; then
    abort "$1"
  fi
  exit 1
}

ensure_config_key() {
  _key="$1"
  _val="$2"
  grep -Eq "^[[:space:]]*${_key}=" "$CONF_FILE" 2>/dev/null || printf '%s=%s\n' "$_key" "$_val" >> "$CONF_FILE"
}

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

ui_print "- Installing UniMount v2.5.1 (Knox 0x0 Safe)"

# Abort if another active metamodule owns /data/adb/metamodule
if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
  _meta_target=$(readlink -f /data/adb/metamodule 2>/dev/null || readlink /data/adb/metamodule 2>/dev/null)
  _meta_id=$(basename "${_meta_target:-/data/adb/metamodule}")
  if [ -n "$_meta_id" ] && [ "$_meta_id" != "unimount" ] && [ "$_meta_id" != "metamodule" ]; then
    if { [ -d "/data/adb/modules/$_meta_id" ] && [ ! -f "/data/adb/modules/$_meta_id/remove" ]; } || \
       { [ -d "$_meta_target" ] && [ ! -f "$_meta_target/remove" ]; }; then
      abort_install "Active metamodule '$_meta_id' detected at /data/adb/metamodule. Uninstall it before installing UniMount."
    fi
  fi
fi

# Abort if another installed or staged module declares metamodule=1
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

# Warn if standalone mount engines are active alongside UniMount
for _engine in mountify magic_mount magic_mount_rs hybrid_mount meta-hybrid_mount nanomount nomount; do
  if [ -d "/data/adb/modules/$_engine" ] && [ ! -f "/data/adb/modules/$_engine/disable" ] && [ ! -f "/data/adb/modules/$_engine/remove" ]; then
    ui_print "! Warning: Active mount engine '$_engine' detected; disable or remove it to prevent double-mounting."
  fi
done

mkdir -p "$CONF_DIR" "$CONF_DIR/mirror"
[ -f "$CONF_FILE" ] || : > "$CONF_FILE"

ensure_config_key MOUNT_MODE auto
ensure_config_key SELINUX_MIRROR 1
ensure_config_key DIR_MIRROR_INJECT 1
ensure_config_key SKIP_ZYGISK_ONLY 1
ensure_config_key LOG_VERBOSE 1
ensure_config_key BOOTLOOP_GUARD 1
ensure_config_key PROTECT_CRITICAL_PATHS 1

[ -f "$CONF_DIR/modules.txt" ] || touch "$CONF_DIR/modules.txt"

# Clear stale bootloop guard state on install or upgrade
rm -f "$CONF_DIR/.bypass_boot_id"
echo "0" > "$CONF_DIR/.boot_fail_count"

# Purge orphaned Zygisk and mount-engine data directories (allowlist only)
cleanup_orphan_dir brezygisk brezygisk
cleanup_orphan_dir rezygisk rezygisk
cleanup_orphan_dir zygisksu zygisksu neo_zygisk
cleanup_orphan_dir neo_zygisk neo_zygisk zygisksu
cleanup_orphan_dir hybrid_mount hybrid_mount meta-hybrid_mount
cleanup_orphan_dir magic_mount magic_mount magic_mount_rs
cleanup_orphan_dir mountify mountify
cleanup_orphan_dir nanomount nanomount
cleanup_orphan_dir nomount nomount

# Wire /data/adb/metamodule symlink if unassigned or broken
if [ ! -e /data/adb/metamodule ]; then
  rm -f /data/adb/metamodule 2>/dev/null
  ln -sf /data/adb/modules/unimount /data/adb/metamodule
fi

chmod 0755 "$MODPATH/metamount.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" \
  "$MODPATH/boot-completed.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" 2>/dev/null
ui_print "- WebUI installed: Open via KernelSU Manager -> UniMount"
