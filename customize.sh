set +x
set +v
PARTOVER=true

REPLACE="
"

set_permissions() {
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  [ -f "$MODPATH/system/bin/asb" ] && set_perm "$MODPATH/system/bin/asb" 0 0 0755
  [ -f "$MODPATH/bin/asb" ] && set_perm "$MODPATH/bin/asb" 0 0 0755
  for f in "$MODPATH/service.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/uninstall.sh" "$MODPATH/action.sh" "$MODPATH/apply_profile.sh"; do
    [ -f "$f" ] && set_perm "$f" 0 0 0755
  done
  for d in "$MODPATH/runtime" "$MODPATH/profiles" "$MODPATH/tools" "$MODPATH/common"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.sh; do
      [ -f "$f" ] && set_perm "$f" 0 0 0755
    done
    if [ -d "$d/logkit" ]; then
      for f in "$d/logkit"/*.sh; do
        [ -f "$f" ] && set_perm "$f" 0 0 0755
      done
    fi
  done
}

SKIPUNZIP=1
unzip -qjo "$ZIPFILE" 'common/functions.sh' -d $TMPDIR >&2
. $TMPDIR/functions.sh
