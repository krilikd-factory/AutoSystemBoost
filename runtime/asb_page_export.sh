#!/system/bin/sh
# Bounded WebUI page export. The browser chooses only a known page kind and timestamp;
# the destination directory and filename are owned here, never supplied as a shell path.
# No background worker, fallback directory or arbitrary file writer is involved.

OUTDIR="${ASB_PAGE_EXPORT_OUTDIR:-/sdcard/ASB/logs}"
KIND="${2:-}"
STAMP="${3:-}"
PART="${4:-}"

case "$KIND" in
  report) PREFIX='asb_report_' ;;
  device) PREFIX='asb_device_' ;;
  zygisk) PREFIX='asb_zygisk_' ;;
  *) echo 'error=bad_kind'; exit 2 ;;
esac
case "$STAMP" in
  *[!0-9_]*|'') echo 'error=bad_stamp'; exit 2 ;;
esac
STAMP_HEAD="${STAMP%_*}"; STAMP_TAIL="${STAMP#*_}"
[ "${#STAMP_HEAD}" -eq 8 ] && [ "${#STAMP_TAIL}" -eq 6 ] || { echo 'error=bad_stamp'; exit 2; }
case "$STAMP_HEAD:$STAMP_TAIL" in *[!0-9:]*|'') echo 'error=bad_stamp'; exit 2 ;; esac
[ -d "$OUTDIR" ] || mkdir -p "$OUTDIR" 2>/dev/null || {
  echo 'error=export_outdir_failed'; exit 5;
}
[ -d "$OUTDIR" ] || { echo 'error=export_outdir_failed'; exit 5; }

BASE="${PREFIX}${STAMP}"
TMP="$OUTDIR/.${BASE}.b64"
OUT="$OUTDIR/${BASE}.txt"
DECODED="$OUTDIR/.${BASE}.decoded.$$"

case "${1:-}" in
  begin)
    rm -f "$TMP" "$DECODED" 2>/dev/null || true
    (umask 022; printf '%s' '' > "$TMP") || { echo 'error=export_write_failed'; exit 5; }
    echo 'status=started'
    ;;
  append)
    case "$PART" in *[!A-Za-z0-9+/=]*) echo 'error=bad_base64'; exit 2 ;; esac
    [ -f "$TMP" ] || { echo 'error=export_not_started'; exit 4; }
    printf '%s' "$PART" >> "$TMP" 2>/dev/null || { echo 'error=export_write_failed'; exit 5; }
    echo 'status=appending'
    ;;
  finish)
    [ -f "$TMP" ] || { echo 'error=export_not_started'; exit 4; }
    rm -f "$DECODED" 2>/dev/null || true
    if base64 -d < "$TMP" > "$DECODED" 2>/dev/null && mv -f "$DECODED" "$OUT" 2>/dev/null; then
      rm -f "$TMP" 2>/dev/null || true
      echo "status=saved"
      echo "path=$OUT"
    else
      rm -f "$TMP" "$DECODED" 2>/dev/null || true
      echo 'error=export_decode_failed'; exit 5
    fi
    ;;
  abort)
    rm -f "$TMP" "$DECODED" 2>/dev/null || true
    echo 'status=cancelled'
    ;;
  *) echo 'error=bad_action'; exit 2 ;;
esac
exit 0
