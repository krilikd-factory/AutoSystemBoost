#!/system/bin/sh
# asb_config_backup.sh — named, validated ASB settings profiles.
# Profiles contain only explicit user keys supplied by the caller: never bounds, device
# topology, learned state or thermal constants copied from one handset to another.
set -eu

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
WRITER="$MODDIR/runtime/asb_config_safe.sh"
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"
PROFILES="$STATE/config_profiles"
SNAPSHOT="$STATE/governor.conf.snapshot"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; return; fi
  if command -v toybox >/dev/null 2>&1; then toybox sha256sum "$1" 2>/dev/null | awk '{print $1}'; return; fi
  echo unavailable
}
_now() { date +%s 2>/dev/null || echo 0; }
_profile_ok() { case "${1:-}" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; [ "${#1}" -le 32 ] 2>/dev/null; }
_key_ok() { case "${1:-}" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac; }
_profile_file() { printf '%s/%s.conf' "$PROFILES" "$1"; }
_profile_sha() { printf '%s/%s.conf.sha256' "$PROFILES" "$1"; }
_prepare_dir() { mkdir -p "$PROFILES" 2>/dev/null || { echo 'cannot create profile store' >&2; exit 1; }; }

write_profile() {
  _name="$1" _replace="$2"; shift 2
  _profile_ok "$_name" || { echo 'invalid profile name: use 1..32 letters, digits, _ or -' >&2; exit 2; }
  [ "$#" -gt 0 ] || { echo 'profile needs allowed keys' >&2; exit 2; }
  [ -r "$CONF" ] || { echo "config unavailable: $CONF" >&2; exit 1; }
  _prepare_dir
  _out="$(_profile_file "$_name")"; _sum="$(_profile_sha "$_name")"
  [ "$_replace" = 1 ] || [ ! -e "$_out" ] || { echo 'profile already exists' >&2; exit 3; }
  _tmp="$_out.tmp.$$"
  {
    echo '# ASB_PROFILE_SCHEMA=1'
    echo "# created_at=$(_now)"
    echo "# module_version=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
    echo "# device=$(getprop ro.product.model 2>/dev/null) / $(getprop ro.board.platform 2>/dev/null)"
    for _key in "$@"; do
      _key_ok "$_key" || { rm -f "$_tmp"; echo 'invalid allowed key' >&2; exit 2; }
      _val="$(awk -F= -v k="$_key" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {v=$2; sub(/#.*/,"",v); gsub(/[[:space:]]/,"",v); print v; exit}' "$CONF")"
      [ -n "$_val" ] && printf '%s=%s\n' "$_key" "$_val"
    done
  } > "$_tmp"
  _count="$(grep -c '^[A-Za-z0-9_]*=' "$_tmp" 2>/dev/null || echo 0)"
  [ "$_count" -gt 0 ] 2>/dev/null || { rm -f "$_tmp"; echo 'profile contains no current user settings' >&2; exit 1; }
  mv -f "$_tmp" "$_out"
  hash_file "$_out" > "$_sum.tmp.$$" && mv -f "$_sum.tmp.$$" "$_sum"
  echo "profile=$_name"
  echo "keys=$_count"
  echo "checksum=$(cat "$_sum" 2>/dev/null || true)"
}

verify_profile() {
  _name="$1"; _profile_ok "$_name" || { echo 'invalid profile name' >&2; exit 2; }
  _in="$(_profile_file "$_name")"; _sum="$(_profile_sha "$_name")"
  [ -r "$_in" ] || { echo 'profile not found' >&2; exit 1; }
  _expect="$(cat "$_sum" 2>/dev/null | tr -d ' \r\n')"; _actual="$(hash_file "$_in")"
  [ -n "$_expect" ] && [ "$_expect" != unavailable ] && [ "$_expect" = "$_actual" ] || {
    echo 'profile checksum mismatch or absent' >&2; exit 1;
  }
  printf '%s' "$_in"
}

preview_file() {
  _in="$1"; shift
  [ -r "$CONF" ] || { echo "config unavailable: $CONF" >&2; exit 1; }
  [ -r "$_in" ] || { echo 'profile unreadable' >&2; exit 1; }
  _tmpdir="${TMPDIR:-/data/local/tmp}"; [ -d "$_tmpdir" ] || _tmpdir="/tmp"
  _candidate="$_tmpdir/asb_profile_preview.$$.conf"; cp "$CONF" "$_candidate"
  _allowed=" $* "
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="$(printf '%s' "$_line" | tr -d '\r')"
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in *=*) ;; *) rm -f "$_candidate"; echo 'invalid profile line' >&2; exit 1 ;; esac
    _key="${_line%%=*}"; _val="${_line#*=}"
    case "$_allowed" in *" $_key "*) ;; *) continue ;; esac
    _key_ok "$_key" || { rm -f "$_candidate"; echo 'invalid profile key' >&2; exit 1; }
    awk -v k="$_key" -v v="$_val" '
      { p=index($0,"="); key=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); if (p && key==k) {print k "=" v; next} print }
    ' "$_candidate" > "$_candidate.next"
    mv -f "$_candidate.next" "$_candidate"
  done < "$_in"
  sh "$WRITER" validate "$_candidate"
  echo '--- preview diff ---'; diff -u "$CONF" "$_candidate" || true
  rm -f "$_candidate"
}

list_profiles() {
  _prepare_dir; _found=0
  for _f in "$PROFILES"/*.conf; do
    [ -f "$_f" ] || continue
    _name="${_f##*/}"; _name="${_name%.conf}"
    _created="$(grep '^# created_at=' "$_f" 2>/dev/null | head -1 | cut -d= -f2)"
    _count="$(grep -c '^[A-Za-z0-9_]*=' "$_f" 2>/dev/null || echo 0)"
    _expected="$(cat "$(_profile_sha "$_name")" 2>/dev/null | tr -d ' \r\n')"; _actual="$(hash_file "$_f")"
    _status=ok; [ -n "$_expected" ] && [ "$_expected" = "$_actual" ] || _status=checksum_bad
    printf '%s|%s|%s|%s\n' "$_name" "${_created:-0}" "$_count" "$_status"; _found=1
  done
  [ "$_found" = 1 ] || true
}

restore_profile() {
  _name="$1"; shift; [ "$#" -gt 0 ] || { echo 'restore needs allowed keys' >&2; exit 2; }
  _in="$(verify_profile "$_name")"; sh "$WRITER" import "$_in" "$SNAPSHOT" "$@"; echo "restored=$_name"
}
delete_profile() {
  _name="$1"; _profile_ok "$_name" || { echo 'invalid profile name' >&2; exit 2; }
  _prepare_dir; _in="$(_profile_file "$_name")"; [ -f "$_in" ] || { echo 'profile not found' >&2; exit 1; }
  rm -f "$_in" "$(_profile_sha "$_name")"; echo "deleted=$_name"
}

# Kept for existing terminal workflows: a path argument preserves the original schema-2
# whole-config backup/preview interface. New WebUI profiles never use this path.
legacy_create() {
  _out="$1"; [ -r "$CONF" ] || { echo "config unavailable: $CONF" >&2; exit 1; }
  mkdir -p "$(dirname "$_out")" 2>/dev/null || true
  _tmp="$_out.tmp.$$"
  { echo '# ASB_BACKUP_SCHEMA=2'; echo "# created_at=$(_now)"; grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$CONF"; } > "$_tmp"
  mv -f "$_tmp" "$_out"; hash_file "$_out" > "$_out.sha256"
  echo "backup=$_out"; echo "checksum=$(cat "$_out.sha256")"
}
legacy_preview() {
  _in="$1"; [ -r "$_in" ] || { echo "backup unreadable: $_in" >&2; exit 1; }
  _expect="$(cat "$_in.sha256" 2>/dev/null || true)"; _actual="$(hash_file "$_in")"
  if [ -n "$_expect" ] && [ "$_expect" != unavailable ] && [ "$_expect" != "$_actual" ]; then echo 'checksum mismatch' >&2; exit 1; fi
  _tmpdir="${TMPDIR:-/data/local/tmp}"; [ -d "$_tmpdir" ] || _tmpdir="/tmp"
  _candidate="$_tmpdir/asb_backup_preview.$$.conf"; cp "$CONF" "$_candidate"
  # Same candidate rewrite as the original helper, followed by full writer validation;
  # preview never writes the active config.
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    _k="${_line%%=*}"; _v="${_line#*=}"; _key_ok "$_k" || continue
    grep -qE "^[[:space:]]*${_k}=" "$CONF" 2>/dev/null || continue
    awk -v k="$_k" -v v="$_v" '{ p=index($0,"="); key=substr($0,1,p-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); if (p && key==k) {print k "=" v; next} print }' "$_candidate" > "$_candidate.next"
    mv -f "$_candidate.next" "$_candidate"
  done < "$_in"
  sh "$WRITER" validate "$_candidate"; echo '--- preview diff ---'; diff -u "$CONF" "$_candidate" || true; rm -f "$_candidate"
}

case "${1:-}" in
  list) [ "$#" -eq 1 ] || { echo "usage: $0 list" >&2; exit 2; }; list_profiles ;;
  create)
    case "${2:-}" in */*) [ "$#" -eq 2 ] || { echo "usage: $0 create OUT" >&2; exit 2; }; legacy_create "$2" ;;
      *) [ "$#" -ge 3 ] || { echo "usage: $0 create NAME ALLOWED_KEY..." >&2; exit 2; }; _n="$2"; shift 2; write_profile "$_n" 0 "$@" ;;
    esac ;;
  replace) [ "$#" -ge 3 ] || { echo "usage: $0 replace NAME ALLOWED_KEY..." >&2; exit 2; }; _n="$2"; shift 2; write_profile "$_n" 1 "$@" ;;
  preview)
    case "${2:-}" in */*) [ "$#" -eq 2 ] || { echo "usage: $0 preview BACKUP" >&2; exit 2; }; legacy_preview "$2" ;;
      *) [ "$#" -ge 3 ] || { echo "usage: $0 preview NAME ALLOWED_KEY..." >&2; exit 2; }; _n="$2"; shift 2; _in="$(verify_profile "$_n")"; preview_file "$_in" "$@" ;;
    esac ;;
  restore) [ "$#" -ge 3 ] || { echo "usage: $0 restore NAME ALLOWED_KEY..." >&2; exit 2; }; _n="$2"; shift 2; restore_profile "$_n" "$@" ;;
  delete) [ "$#" -eq 2 ] || { echo "usage: $0 delete NAME" >&2; exit 2; }; delete_profile "$2" ;;
  *) echo "usage: $0 {list|create|replace|preview|restore|delete} NAME [ALLOWED_KEY...]" >&2; exit 2 ;;
esac
