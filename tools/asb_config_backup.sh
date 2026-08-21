#!/system/bin/sh
# asb_config_backup.sh — named, validated ASB settings profiles.
# Profiles contain explicit user settings plus an optional, separately checksummed Smart-learning
# payload. Device bounds, topology, runtime state and thermal constants are never copied.
set -eu

MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="$MODDIR/config/governor.conf"
WRITER="$MODDIR/runtime/asb_config_safe.sh"
STATE="${ASB_CONFIG_STATE:-/data/adb/asb}"
# Tests may point learner state elsewhere; devices use the same durable ASB state directory.
SMART_STATE="${ASB_SMART_STATE:-$STATE}"
PROFILES="$STATE/config_profiles"
SNAPSHOT="$STATE/governor.conf.snapshot"
# External copies are a convenience for user backup/sharing, never an unvalidated path API.
# The WebUI can choose only these two common Android locations; the canonical restore source
# remains the checksum-protected ASB profile store above.
EXPORT_ROOT="${ASB_PROFILE_EXPORT_ROOT:-/sdcard}"

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
_smart_dir() { printf '%s/%s.smart' "$PROFILES" "$1"; }
_smart_sum() { printf '%s/%s.smart.sha256' "$PROFILES" "$1"; }
_smart_file_ok() { case "${1:-}" in buckets.bin|smart_appheat.bin|night_window.conf) return 0 ;; *) return 1 ;; esac; }
_smart_prop() { getprop "$1" 2>/dev/null | tr -d '\r\n'; }
_smart_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# The learner owns only these three durable artifacts. session history, previous profile and
# daemon state are diagnostics/runtime details, not portable learning.
smart_save() {
  _name="$1"; _dir="$(_smart_dir "$_name")"; _sum="$(_smart_sum "$_name")"
  rm -rf "$_dir"; rm -f "$_sum"
  _tmp="$_dir.tmp.$$"; mkdir -p "$_tmp" 2>/dev/null || { echo 'smart_learning=unavailable'; return 0; }
  _n=0
  {
    echo '# ASB_SMART_PROFILE_SCHEMA=1'
    echo "# created_at=$(_now)"
    echo "# board=$(_smart_prop ro.board.platform)"
    echo "# device=$(_smart_prop ro.product.device)"
    for _f in buckets.bin smart_appheat.bin night_window.conf; do
      _src="$SMART_STATE/$_f"; [ -s "$_src" ] || continue
      _bytes="$(_smart_size "$_src")"; case "$_bytes" in ''|*[!0-9]*) continue ;; esac
      [ "$_bytes" -le 1048576 ] 2>/dev/null || continue
      cp -f "$_src" "$_tmp/$_f" 2>/dev/null || continue
      _hash="$(hash_file "$_tmp/$_f")"; [ -n "$_hash" ] && [ "$_hash" != unavailable ] || { rm -f "$_tmp/$_f"; continue; }
      printf '%s|%s|%s\n' "$_f" "$_bytes" "$_hash"; _n=$((_n + 1))
    done
  } > "$_tmp/manifest"
  if [ "$_n" -eq 0 ]; then rm -rf "$_tmp"; echo 'smart_learning=empty'; return 0; fi
  hash_file "$_tmp/manifest" > "$_tmp/manifest.sha256" || { rm -rf "$_tmp"; echo 'smart_learning=unavailable'; return 0; }
  mv -f "$_tmp" "$_dir" && hash_file "$_dir/manifest" > "$_sum.tmp.$$" && mv -f "$_sum.tmp.$$" "$_sum" || { rm -rf "$_dir"; echo 'smart_learning=unavailable'; return 0; }
  echo "smart_learning=saved"
}

# Return saved, empty, invalid or incompatible. An invalid sidecar never invalidates the
# settings profile: restore may still safely apply the separately checksummed settings.
smart_status_dir() {
  _dir="$1"; [ -d "$_dir" ] || { echo empty; return 0; }
  _manifest="$_dir/manifest"; _msum="$_dir/manifest.sha256"
  [ -r "$_manifest" ] && [ -r "$_msum" ] || { echo invalid; return 0; }
  _expect="$(cat "$_msum" 2>/dev/null | tr -d ' \r\n')"; _actual="$(hash_file "$_manifest")"
  [ -n "$_expect" ] && [ "$_expect" = "$_actual" ] || { echo invalid; return 0; }
  grep -Fqx '# ASB_SMART_PROFILE_SCHEMA=1' "$_manifest" 2>/dev/null || { echo invalid; return 0; }
  _board_saved="$(grep '^# board=' "$_manifest" 2>/dev/null | head -1 | cut -d= -f2-)"; _board_now="$(_smart_prop ro.board.platform)"
  [ -z "$_board_saved" ] || [ -z "$_board_now" ] || [ "$_board_saved" = "$_board_now" ] || { echo incompatible; return 0; }
  _seen=' '
  while IFS='|' read -r _f _bytes _hash; do
    case "$_f" in ''|'#'*) continue ;; esac
    _smart_file_ok "$_f" || { echo invalid; return 0; }
    case "$_seen" in
      *" $_f "*) echo invalid; return 0 ;;
      *) _seen="$_seen$_f " ;;
    esac
    case "$_bytes:$_hash" in *[!0-9a-fA-F:]*|:*|*::*) echo invalid; return 0 ;; esac
    [ "$_bytes" -gt 0 ] 2>/dev/null && [ "$_bytes" -le 1048576 ] 2>/dev/null || { echo invalid; return 0; }
    [ -r "$_dir/$_f" ] && [ "$(_smart_size "$_dir/$_f")" = "$_bytes" ] && [ "$(hash_file "$_dir/$_f")" = "$_hash" ] || { echo invalid; return 0; }
  done < "$_manifest"
  case "$_seen" in ' ') echo empty ;; *) echo saved ;; esac
}
smart_status() {
  _name="$1"; _dir="$(_smart_dir "$_name")"; _sum="$(_smart_sum "$_name")"
  [ -d "$_dir" ] || { echo empty; return 0; }
  _expect="$(cat "$_sum" 2>/dev/null | tr -d ' \r\n')"; _actual="$(hash_file "$_dir/manifest")"
  [ -n "$_expect" ] && [ "$_expect" = "$_actual" ] || { echo invalid; return 0; }
  smart_status_dir "$_dir"
}
smart_restore() {
  _name="$1"; _src="$(_smart_dir "$_name")"; _status="$(smart_status "$_name")"
  case "$_status" in empty) echo 'smart_learning=none'; return 0 ;; incompatible) echo 'smart_learning=skipped_incompatible_device'; return 0 ;; invalid) echo 'smart_learning=skipped_invalid'; return 0 ;; esac
  _was=0
  if [ "${ASB_SMART_RESTORE_SKIP_DAEMON:-0}" != 1 ] && pgrep -f '/bin/asb$' >/dev/null 2>&1; then
    _was=1; pkill -f '/bin/asb$' 2>/dev/null || true; sleep 1
  fi
  mkdir -p "$SMART_STATE" 2>/dev/null || { echo 'smart_learning=restore_failed'; return 1; }
  while IFS='|' read -r _f _bytes _hash; do
    case "$_f" in ''|'#'*) continue ;; esac
    cp -f "$_src/$_f" "$SMART_STATE/$_f.restore.$$" 2>/dev/null && mv -f "$SMART_STATE/$_f.restore.$$" "$SMART_STATE/$_f" || { echo 'smart_learning=restore_failed'; return 1; }
  done < "$_src/manifest"
  rm -f "$SMART_STATE/buckets.bin.bak" "$SMART_STATE/smart_prev_profile" 2>/dev/null || true
  if [ "$_was" = 1 ] && [ -x "$MODDIR/bin/asb" ]; then "$MODDIR/bin/asb" >/dev/null 2>&1 & fi
  echo 'smart_learning=restored'
}

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
  _smart="$(smart_save "$_name")"
  echo "profile=$_name"
  echo "keys=$_count"
  echo "checksum=$(cat "$_sum" 2>/dev/null || true)"
  echo "$_smart"
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
    _smart="$(smart_status "$_name")"
    printf '%s|%s|%s|%s|%s\n' "$_name" "${_created:-0}" "$_count" "$_status" "$_smart"; _found=1
  done
  [ "$_found" = 1 ] || true
}

restore_profile() {
  _name="$1"; shift; [ "$#" -gt 0 ] || { echo 'restore needs allowed keys' >&2; exit 2; }
  _in="$(verify_profile "$_name")"; sh "$WRITER" import "$_in" "$SNAPSHOT" "$@"; echo "restored=$_name"; smart_restore "$_name"
}
delete_profile() {
  _name="$1"; _profile_ok "$_name" || { echo 'invalid profile name' >&2; exit 2; }
  _prepare_dir; _in="$(_profile_file "$_name")"; [ -f "$_in" ] || { echo 'profile not found' >&2; exit 1; }
  rm -f "$_in" "$(_profile_sha "$_name")" "$(_smart_sum "$_name")"; rm -rf "$(_smart_dir "$_name")"; echo "deleted=$_name"
}

_export_dir() {
  case "${1:-}" in
    downloads) printf '%s/Download/ASB-Profiles' "$EXPORT_ROOT" ;;
    documents) printf '%s/Documents/ASB-Profiles' "$EXPORT_ROOT" ;;
    *) return 1 ;;
  esac
}
export_profile() {
  _name="$1" _where="$2"; _profile_ok "$_name" || { echo 'invalid profile name' >&2; exit 2; }
  _in="$(verify_profile "$_name")"; _dir="$(_export_dir "$_where")" || { echo 'invalid export location' >&2; exit 2; }
  mkdir -p "$_dir" 2>/dev/null || { echo 'cannot create export directory' >&2; exit 1; }
  cp -f "$_in" "$_dir/$_name.conf" && cp -f "$(_profile_sha "$_name")" "$_dir/$_name.conf.sha256" || {
    echo 'cannot export profile' >&2; exit 1;
  }
  _smart="$(smart_status "$_name")"
  rm -rf "$_dir/$_name.smart"
  if [ "$_smart" = saved ]; then cp -R "$(_smart_dir "$_name")" "$_dir/$_name.smart" || { echo 'cannot export Smart learning' >&2; exit 1; }; fi
  chmod 0644 "$_dir/$_name.conf" "$_dir/$_name.conf.sha256" 2>/dev/null || true
  echo "exported=$_dir/$_name.conf"
  echo "smart_learning=$_smart"
}
list_external_profiles() {
  _where="$1"; _dir="$(_export_dir "$_where")" || { echo 'invalid export location' >&2; exit 2; }
  [ -d "$_dir" ] || exit 0
  for _f in "$_dir"/*.conf; do
    [ -f "$_f" ] || continue
    _name="${_f##*/}"; _name="${_name%.conf}"; _profile_ok "$_name" || continue
    _expected="$(cat "$_f.sha256" 2>/dev/null | tr -d ' \r\n')"; _actual="$(hash_file "$_f")"
    _status=ok; [ -n "$_expected" ] && [ "$_expected" = "$_actual" ] || _status=checksum_bad
    _count="$(grep -c '^[A-Za-z0-9_]*=' "$_f" 2>/dev/null || echo 0)"
    _smart="$(smart_status_dir "$_dir/$_name.smart")"
    printf '%s|%s|%s|%s\n' "$_name" "$_count" "$_status" "$_smart"
  done
}
import_external_profile() {
  _where="$1" _name="$2"; _profile_ok "$_name" || { echo 'invalid profile name' >&2; exit 2; }
  _dir="$(_export_dir "$_where")" || { echo 'invalid import location' >&2; exit 2; }
  _in="$_dir/$_name.conf" _sum="$_dir/$_name.conf.sha256"
  [ -r "$_in" ] && [ -r "$_sum" ] || { echo 'exported profile not found' >&2; exit 1; }
  _expected="$(cat "$_sum" 2>/dev/null | tr -d ' \r\n')"; _actual="$(hash_file "$_in")"
  [ -n "$_expected" ] && [ "$_expected" = "$_actual" ] || { echo 'exported profile checksum mismatch' >&2; exit 1; }
  _prepare_dir
  cp -f "$_in" "$(_profile_file "$_name")" && cp -f "$_sum" "$(_profile_sha "$_name")" || {
    echo 'cannot import exported profile' >&2; exit 1;
  }
  rm -rf "$(_smart_dir "$_name")"; rm -f "$(_smart_sum "$_name")"
  _smart="$(smart_status_dir "$_dir/$_name.smart")"
  if [ "$_smart" = saved ]; then cp -R "$_dir/$_name.smart" "$(_smart_dir "$_name")" && hash_file "$(_smart_dir "$_name")/manifest" > "$(_smart_sum "$_name")" || { echo 'cannot import Smart learning' >&2; exit 1; }; fi
  echo "imported=$_name"
  echo "smart_learning=$_smart"
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
      *) [ "$#" -ge 3 ] || { echo "usage: $0 preview NAME ALLOWED_KEY..." >&2; exit 2; }; _n="$2"; shift 2; _in="$(verify_profile "$_n")"; preview_file "$_in" "$@"; echo '--- Smart learning ---'; echo "status=$(smart_status "$_n")" ;;
    esac ;;
  restore) [ "$#" -ge 3 ] || { echo "usage: $0 restore NAME ALLOWED_KEY..." >&2; exit 2; }; _n="$2"; shift 2; restore_profile "$_n" "$@" ;;
  delete) [ "$#" -eq 2 ] || { echo "usage: $0 delete NAME" >&2; exit 2; }; delete_profile "$2" ;;
  export) [ "$#" -eq 3 ] || { echo "usage: $0 export NAME {downloads|documents}" >&2; exit 2; }; export_profile "$2" "$3" ;;
  list-external) [ "$#" -eq 2 ] || { echo "usage: $0 list-external {downloads|documents}" >&2; exit 2; }; list_external_profiles "$2" ;;
  import-external) [ "$#" -eq 3 ] || { echo "usage: $0 import-external {downloads|documents} NAME" >&2; exit 2; }; import_external_profile "$2" "$3" ;;
  *) echo "usage: $0 {list|create|replace|preview|restore|delete|export|list-external|import-external} ..." >&2; exit 2 ;;
esac
