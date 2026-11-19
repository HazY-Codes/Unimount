#!/system/bin/sh
MODDIR=${0%/*}
CONF_DIR="/data/adb/unimount"
LOG_FILE="$CONF_DIR/mount.log"
MIRROR_ROOT="$CONF_DIR/mirror"
MODULES_DIR="/data/adb/modules"

mkdir -p "$CONF_DIR" "$MIRROR_ROOT"
echo "=== UniMount Run: $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"

MOUNT_MODE="auto"
SELINUX_MIRROR="1"
SKIP_ZYGISK_ONLY="1"
[ -f "$CONF_DIR/config.conf" ] && . "$CONF_DIR/config.conf"

echo "[INFO] Mode: $MOUNT_MODE | SELinux Mirror: $SELINUX_MIRROR" >> "$LOG_FILE"

mount_tree() {
  local src_base="$1"
  local dst_base="$2"
  local mod_id="$3"

  [ ! -d "$src_base" ] && return 0

  find "$src_base" -type f | while read -r src_file; do
    rel_path="${src_file#$src_base/}"
    dst_file="$dst_base/$rel_path"
    if [ -f "$dst_file" ]; then
      if [ "$SELINUX_MIRROR" = "1" ]; then
        orig_ctx=$(ls -Z "$dst_file" 2>/dev/null | awk '{print $1}')
        [ -n "$orig_ctx" ] && [ "$orig_ctx" != "?" ] && chcon "$orig_ctx" "$src_file" 2>/dev/null
      fi
      mount -o bind "$src_file" "$dst_file" 2>>"$LOG_FILE" && echo "[MOUNT] $mod_id -> $dst_file (ctx: ${orig_ctx:-default})" >> "$LOG_FILE"
    fi
  done
}

for mod in "$MODULES_DIR"/*; do
  [ ! -d "$mod" ] && continue
  mod_id=$(basename "$mod")
  [ "$mod_id" = "unimount" ] && continue

  if [ -f "$mod/disable" ] || [ -f "$mod/remove" ] || [ -f "$mod/skip_mount" ] || [ -f "$mod/skip_unimount" ]; then
    echo "[SKIP] $mod_id (disabled or skip flag present)" >> "$LOG_FILE"
    continue
  fi

  if [ "$MOUNT_MODE" = "manual" ]; then
    if ! grep -qx "$mod_id" "$CONF_DIR/modules.txt" 2>/dev/null; then
      echo "[SKIP] $mod_id (not in manual modules.txt whitelist)" >> "$LOG_FILE"
      continue
    fi
  fi

  has_overlay=0
  for part in system vendor product system_ext odm prism optics; do
    if [ -d "$mod/$part" ]; then
      has_overlay=1
      if [ "$part" = "system" ]; then
        mount_tree "$mod/system" "/system" "$mod_id"
      else
        mount_tree "$mod/$part" "/$part" "$mod_id"
      fi
    fi
  done

  if [ "$has_overlay" = "0" ]; then
    echo "[INFO] $mod_id: Zygisk / service-only module (no partition overlay)" >> "$LOG_FILE"
  fi
done

echo "=== UniMount Complete ===" >> "$LOG_FILE"
