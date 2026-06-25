set +x
set +v
PARTOVER=true

REPLACE="
"

set_permissions() {
  # The template's set_perm_recursive makes every file 0644 (non-exec), then
  if [ -f "$MODPATH/system/bin/asbdiag" ]; then
    set_perm "$MODPATH/system/bin/asbdiag" 0 0 0755 u:object_r:system_file:s0 2>/dev/null \
      || set_perm "$MODPATH/system/bin/asbdiag" 0 0 0755 2>/dev/null || true
  fi
  if [ -f "$MODPATH/system/bin/asb" ]; then
    set_perm "$MODPATH/system/bin/asb" 0 0 0755 u:object_r:system_file:s0 2>/dev/null \
      || set_perm "$MODPATH/system/bin/asb" 0 0 0755 2>/dev/null || true
  fi
  [ -f "$MODPATH/tools/asb_diag.sh" ] && set_perm "$MODPATH/tools/asb_diag.sh" 0 0 0755 2>/dev/null || true
  [ -f "$MODPATH/tools/asb_verify_device.sh" ] && set_perm "$MODPATH/tools/asb_verify_device.sh" 0 0 0755 2>/dev/null || true
}

SKIPUNZIP=1
unzip -qjo "$ZIPFILE" 'common/functions.sh' -d $TMPDIR >&2
. $TMPDIR/functions.sh

# ── FINAL layout normalization ──────────────────────────────────────────────
asb_fix_layout() {
  [ -n "$MODPATH" ] && [ -d "$MODPATH" ] || return 0

  # (1) collapse system/system/<...> into system/<...>
  if [ -d "$MODPATH/system/system" ] && [ ! -L "$MODPATH/system/system" ]; then
    ui_print "- Layout fix: folding system/system into system"
    for _f in $(cd "$MODPATH/system/system" && find . -type f 2>/dev/null | sed 's|^\./||'); do
      _t="$MODPATH/system/$_f"
      if [ ! -f "$_t" ]; then
        mkdir -p "$(dirname "$_t")" 2>/dev/null
        cp -f "$MODPATH/system/system/$_f" "$_t" 2>/dev/null || true
      fi
    done
    rm -rf "$MODPATH/system/system" 2>/dev/null || true
  fi

  # (2) fold any real top-level partition dir into system/<part>/
  for _part in vendor odm product system_ext my_product mi_ext; do
    _root="$MODPATH/$_part"
    [ -e "$_root" ] || continue
    [ -L "$_root" ] && continue        # valid framework symlink — leave it
    [ -d "$_root" ] || continue
    ui_print "- Layout fix: folding /$_part into system/$_part"
    while grep -q " $_root " /proc/mounts 2>/dev/null; do
      umount "$_root" 2>/dev/null || umount -l "$_root" 2>/dev/null || break
    done
    for _f in $(cd "$_root" && find . -type f 2>/dev/null | sed 's|^\./||'); do
      _t="$MODPATH/system/$_part/$_f"
      if [ ! -f "$_t" ]; then
        mkdir -p "$(dirname "$_t")" 2>/dev/null
        cp -f "$_root/$_f" "$_t" 2>/dev/null || true
      fi
    done
    rm -rf "$_root" 2>/dev/null || true
    # If a KSU kernel re-materialises it, fall back to the OP15-style symlink.
    if [ -d "$_root" ] && [ ! -L "$_root" ] && [ -d "$MODPATH/system/$_part" ]; then
      rm -rf "$_root" 2>/dev/null
      [ -e "$_root" ] || ln -s "./system/$_part" "$_root" 2>/dev/null || true
    fi
  done

  # prune stray-path entries from the restore manifest so reinstall stays clean
  if [ -n "$INFO" ] && [ -f "$INFO" ]; then
    sed -i "\|^$MODPATH/system/system/|d" "$INFO" 2>/dev/null || true
    for _part in vendor odm product system_ext my_product mi_ext; do
      sed -i "\|^$MODPATH/$_part/|d" "$INFO" 2>/dev/null || true
    done
  fi

  # ensure SELinux context on the (now sole) system/vendor tree is correct
  if [ -d "$MODPATH/system/vendor/etc" ]; then
    set_perm_recursive "$MODPATH/system/vendor/etc" 0 2000 0755 0644 u:object_r:vendor_configs_file:s0 2>/dev/null || true
  fi

  # FINAL cleanup — this is the very last thing the installer does. The Magisk
  for _mroot in /data/adb/modules /data/adb/modules_update \
                /data/adb/ksu/modules /data/adb/ksu/modules_update \
                /data/adb/ap/modules /data/adb/ap/modules_update; do
    rm -f  "$_mroot/.$MODID-files" 2>/dev/null || true
    rm -f  "$_mroot/.AutoSystemBoost-files" 2>/dev/null || true
    rm -rf "$_mroot/AutoSystemBoost/CLEAR" 2>/dev/null || true
  done
  [ -n "$INFO" ] && rm -f "$INFO" 2>/dev/null || true
}
asb_fix_layout
