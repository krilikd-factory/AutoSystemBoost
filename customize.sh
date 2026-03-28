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
