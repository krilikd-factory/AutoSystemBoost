set +x
set +v
PARTOVER=true

REPLACE="
"

set_permissions() {
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  for _f in "$MODPATH"/*.sh "$MODPATH"/bin/* "$MODPATH"/tools/*.sh "$MODPATH"/tools/*.py \
            "$MODPATH"/tools/logkit/*.sh "$MODPATH"/runtime/*.sh "$MODPATH"/profiles/*.sh; do
    [ -e "$_f" ] && set_perm "$_f" 0 0 0755
  done
  [ -d "$MODPATH/system/vendor" ] && \
    set_perm_recursive "$MODPATH/system/vendor" 0 0 0755 0644 u:object_r:vendor_file:s0
}

SKIPUNZIP=1
unzip -qjo "$ZIPFILE" 'common/functions.sh' -d $TMPDIR >&2
. $TMPDIR/functions.sh
