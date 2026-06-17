set +x
set +v
PARTOVER=true

REPLACE="
"

set_permissions() {
  :
}

SKIPUNZIP=1
unzip -qjo "$ZIPFILE" 'common/functions.sh' -d $TMPDIR >&2
. $TMPDIR/functions.sh

# ── FINAL layout normalization ──────────────────────────────────────────────
# Runs AFTER functions.sh (and the install.sh it sources) have fully finished,
# so nothing downstream can re-create a stray tree. A Magisk/KernelSU module
# must keep every mounted file under $MODPATH/system/. Two faults are repaired
# here unconditionally, on every device:
#   1) a nested system/system/... (can appear when a /system/* live path is
#      cloned with the system/ prefix re-applied) — folded into system/...
#   2) a REAL top-level vendor/ odm/ product/ system_ext/ ... directory beside
#      system/ — folded into system/<part>/ and removed. A real root vendor/
#      can bind a partial dir over the whole /vendor partition -> bootloop.
# Framework-created symlinks (the valid layout) are left untouched.
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
    for _f in $(cd "$_root" && find . -type f 2>/dev/null | sed 's|^\./||'); do
      _t="$MODPATH/system/$_part/$_f"
      if [ ! -f "$_t" ]; then
        mkdir -p "$(dirname "$_t")" 2>/dev/null
        cp -f "$_root/$_f" "$_t" 2>/dev/null || true
      fi
    done
    rm -rf "$_root" 2>/dev/null || true
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
}
asb_fix_layout
