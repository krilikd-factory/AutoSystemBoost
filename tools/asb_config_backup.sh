#!/system/bin/sh
# asb_config_backup.sh — versioned backup, checksum and import preview.
set -eu

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
WRITER="$MODDIR/runtime/asb_config_safe.sh"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; return; fi
  if command -v toybox >/dev/null 2>&1; then toybox sha256sum "$1" 2>/dev/null | awk '{print $1}'; return; fi
  echo unavailable
}

create() {
  _out="$1"
  [ -r "$CONF" ] || { echo "config unavailable: $CONF" >&2; exit 1; }
  _tmp="$_out.tmp.$$"
  {
    echo '# ASB_BACKUP_SCHEMA=2'
    echo "# created_at=$(date +%s 2>/dev/null || echo 0)"
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$CONF"
  } > "$_tmp"
  mv -f "$_tmp" "$_out"
  hash_file "$_out" > "$_out.sha256"
  echo "backup=$_out"
  echo "checksum=$(cat "$_out.sha256")"
}

preview() {
  _in="$1"
  [ -r "$_in" ] || { echo "backup unreadable: $_in" >&2; exit 1; }
  _expect="$(cat "$_in.sha256" 2>/dev/null || true)"
  _actual="$(hash_file "$_in")"
  if [ -n "$_expect" ] && [ "$_expect" != unavailable ] && [ "$_expect" != "$_actual" ]; then
    echo "checksum mismatch: expected=$_expect actual=$_actual" >&2
    exit 1
  fi
  _tmpdir="${TMPDIR:-/data/local/tmp}"
  [ -d "$_tmpdir" ] || _tmpdir="/tmp"
  _candidate="$_tmpdir/asb_backup_preview.$$.conf"
  cp "$CONF" "$_candidate"
  # Preview accepts only keys already present in the active schema and never
  # writes active config. A malformed candidate is rejected by the same full
  # shell/native bounds contract used by import.
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    _k="${_line%%=*}"; _v="${_line#*=}"
    case "$_k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    grep -qE "^[[:space:]]*${_k}=" "$CONF" 2>/dev/null || continue
    awk -v k="$_k" -v v="$_v" '
      { p=index($0,"="); key=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); if (p && key==k) {print k "=" v; next} print }
    ' "$_candidate" > "$_candidate.next"
    mv -f "$_candidate.next" "$_candidate"
  done < "$_in"
  sh "$WRITER" validate "$_candidate"
  echo '--- preview diff ---'
  diff -u "$CONF" "$_candidate" || true
  rm -f "$_candidate"
}

case "${1:-}" in
  create) [ "$#" -eq 2 ] || { echo "usage: $0 create OUT" >&2; exit 2; }; create "$2" ;;
  preview) [ "$#" -eq 2 ] || { echo "usage: $0 preview BACKUP" >&2; exit 2; }; preview "$2" ;;
  *) echo "usage: $0 {create OUT|preview BACKUP}" >&2; exit 2 ;;
esac
