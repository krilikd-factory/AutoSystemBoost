#!/system/bin/sh
# Manual, bounded cleanup of diagnostic residue and files already placed in a trash state.
# No file contents are read, no background worker is started, and no arbitrary path is accepted.
# ASB_JUNK_ROOT and ASB_JUNK_STATE_DIR exist for isolated host fixtures only.

R="${ASB_JUNK_ROOT:-}"
STATE="${ASB_JUNK_STATE_DIR:-/data/adb/asb/junk_cleanup}"
MODE="${1:-status}"
LOCK="$STATE/run.lock"
_TOTAL_N=0
_TOTAL_B=0
_TOTAL_BAD=0
_CAT_N=0
_CAT_B=0
_CAT_LEFT=0
_CAT_BAD=0

# Fixed predicates are selected by a token, never evaluated as shell text. find does not
# follow symlinks; -xdev keeps a mounted or bound subtree from widening a cleanup root.
_jc_sizes() {
  _js_root="$1"
  _js_kind="$2"
  if [ ! -e "$_js_root" ]; then
    printf '0 0 0\n'
    return 0
  fi
  if [ -L "$_js_root" ] || [ ! -d "$_js_root" ]; then
    printf '0 0 2\n'
    return 0
  fi
  if [ ! -r "$_js_root" ] || [ ! -x "$_js_root" ]; then
    printf '0 0 2\n'
    return 0
  fi
  case "$_js_kind" in
    all)
      _js_sizes="$(find "$_js_root" -xdev -type f -exec stat -c '%s' {} + 2>/dev/null)" ;;
    tombstones)
      _js_sizes="$(find "$_js_root" -xdev -name 'tombstone_*' -type f -exec stat -c '%s' {} + 2>/dev/null)" ;;
    backup)
      _js_sizes="$(find "$_js_root" -xdev -maxdepth 1 -name 'journal*.tmp' -mmin +1440 -type f -exec stat -c '%s' {} + 2>/dev/null)" ;;
    screenshots)
      _js_sizes="$(find "$_js_root" -xdev -maxdepth 1 -name '.trashed-*' -type f -exec stat -c '%s' {} + 2>/dev/null)" ;;
    coloros)
      _js_sizes="$(find "$_js_root" -xdev -maxdepth 1 \( -name '*crash@*.txt' -o -name '*crash@*.txt.gz' \) -type f -exec stat -c '%s' {} + 2>/dev/null)" ;;
    *)
      printf '0 0 2\n'
      return 0 ;;
  esac
  _js_rc=$?
  [ "$_js_rc" -eq 0 ] || { printf '0 0 2\n'; return 0; }
  [ -n "$_js_sizes" ] || { printf '0 0 0\n'; return 0; }
  printf '%s\n' "$_js_sizes" | awk '{ n++; b += $1 } END { printf "%d %.0f 0\n", n, b }'
}

_jc_delete_tree() {
  _jd_root="$1"
  _jd_kind="$2"
  case "$_jd_kind" in
    all) find "$_jd_root" -xdev -type f -exec rm -f {} + 2>/dev/null ;;
    tombstones) find "$_jd_root" -xdev -name 'tombstone_*' -type f -exec rm -f {} + 2>/dev/null ;;
    backup) find "$_jd_root" -xdev -maxdepth 1 -name 'journal*.tmp' -mmin +1440 -type f -exec rm -f {} + 2>/dev/null ;;
    screenshots) find "$_jd_root" -xdev -maxdepth 1 -name '.trashed-*' -type f -exec rm -f {} + 2>/dev/null ;;
    coloros) find "$_jd_root" -xdev -maxdepth 1 \( -name '*crash@*.txt' -o -name '*crash@*.txt.gz' \) -type f -exec rm -f {} + 2>/dev/null ;;
    *) return 2 ;;
  esac
}

_jc_prune_empty_dirs() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 0
  find "$1" -xdev -depth -type d -empty ! -path "$1" -exec rmdir {} + 2>/dev/null || true
}

_jc_tree() {
  _jt_id="$1"
  _jt_root="$2"
  _jt_kind="$3"
  _jt_before="$(_jc_sizes "$_jt_root" "$_jt_kind")"
  set -- $_jt_before
  _jt_n="${1:-0}"
  _jt_b="${2:-0}"
  _jt_bad="${3:-2}"
  if [ "$MODE" = run ]; then
    _jt_removed=0
    _jt_freed=0
    _jt_left=0
    if [ "$_jt_bad" = 0 ] && [ "$_jt_n" -gt 0 ]; then
      _jc_delete_tree "$_jt_root" "$_jt_kind"
      _jt_rm=$?
      _jt_after="$(_jc_sizes "$_jt_root" "$_jt_kind")"
      set -- $_jt_after
      _jt_left="${1:-0}"
      _jt_left_b="${2:-0}"
      _jt_after_bad="${3:-2}"
      [ "$_jt_left" -le "$_jt_n" ] || _jt_left="$_jt_n"
      [ "$_jt_left_b" -le "$_jt_b" ] || _jt_left_b="$_jt_b"
      _jt_removed=$((_jt_n - _jt_left))
      _jt_freed=$((_jt_b - _jt_left_b))
      [ "$_jt_rm" -eq 0 ] && [ "$_jt_after_bad" = 0 ] || _jt_bad=2
      [ "$_jt_left" -eq 0 ] || _jt_bad=1
      _jc_prune_empty_dirs "$_jt_root"
    fi
    printf 'junk_category|%s|removed=%s|freed=%s|remaining=%s|state=%s\n' \
      "$_jt_id" "$_jt_removed" "$_jt_freed" "$_jt_left" \
      "$( [ "$_jt_bad" = 0 ] && printf cleaned || printf partial )"
  else
    printf 'junk_category|%s|count=%s|bytes=%s|state=%s\n' \
      "$_jt_id" "$_jt_n" "$_jt_b" "$( [ "$_jt_bad" = 0 ] && printf ready || printf not_readable )"
  fi
  _TOTAL_N=$((_TOTAL_N + _jt_n))
  _TOTAL_B=$((_TOTAL_B + _jt_b))
  [ "$_jt_bad" = 0 ] || _TOTAL_BAD=$((_TOTAL_BAD + 1))
}

_jc_file_size() {
  _jf_path="$1"
  if [ ! -e "$_jf_path" ]; then
    printf '0 0 0\n'
  elif [ -L "$_jf_path" ] || [ ! -f "$_jf_path" ]; then
    printf '0 0 2\n'
  else
    _jf_size="$(stat -c '%s' "$_jf_path" 2>/dev/null)"
    case "$_jf_size" in
      ''|*[!0-9]*) printf '0 0 2\n' ;;
      *) printf '1 %s 0\n' "$_jf_size" ;;
    esac
  fi
}

# A single exact file, instead of ever treating all of /data/local/tmp as disposable.
_jc_file() {
  _jf_path="$1"
  _jf_before="$(_jc_file_size "$_jf_path")"
  set -- $_jf_before
  _jf_n="${1:-0}"
  _jf_b="${2:-0}"
  _jf_bad="${3:-2}"
  if [ "$MODE" = run ]; then
    if [ "$_jf_bad" != 0 ]; then
      _CAT_BAD=$((_CAT_BAD + _jf_bad))
    elif [ "$_jf_n" = 1 ]; then
      rm -f "$_jf_path" 2>/dev/null
      _jf_rm=$?
      if [ -e "$_jf_path" ] || [ -L "$_jf_path" ] || [ "$_jf_rm" -ne 0 ]; then
        _CAT_LEFT=$((_CAT_LEFT + 1))
        _CAT_BAD=1
      else
        _CAT_N=$((_CAT_N + 1))
        _CAT_B=$((_CAT_B + _jf_b))
      fi
    fi
  else
    _CAT_N=$((_CAT_N + _jf_n))
    _CAT_B=$((_CAT_B + _jf_b))
    _CAT_BAD=$((_CAT_BAD + _jf_bad))
  fi
}

# This fixed vendor-history path has existed as both a file and a directory.
_jc_path() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    _jp_path="$1"
    _jp_before="$(_jc_sizes "$_jp_path" all)"
    set -- $_jp_before
    _jp_n="${1:-0}"
    _jp_b="${2:-0}"
    _jp_bad="${3:-2}"
    if [ "$MODE" = run ]; then
      if [ "$_jp_bad" != 0 ]; then
        _CAT_BAD=$((_CAT_BAD + _jp_bad))
      elif [ "$_jp_n" -gt 0 ]; then
        _jc_delete_tree "$_jp_path" all
        _jp_rm=$?
        _jp_after="$(_jc_sizes "$_jp_path" all)"
        set -- $_jp_after
        _jp_left="${1:-0}"
        _jp_left_b="${2:-0}"
        _jp_after_bad="${3:-2}"
        [ "$_jp_left" -le "$_jp_n" ] || _jp_left="$_jp_n"
        [ "$_jp_left_b" -le "$_jp_b" ] || _jp_left_b="$_jp_b"
        _CAT_N=$((_CAT_N + _jp_n - _jp_left))
        _CAT_B=$((_CAT_B + _jp_b - _jp_left_b))
        _CAT_LEFT=$((_CAT_LEFT + _jp_left))
        { [ "$_jp_rm" -eq 0 ] && [ "$_jp_after_bad" = 0 ] && [ "$_jp_left" -eq 0 ]; } || _CAT_BAD=1
        _jc_prune_empty_dirs "$_jp_path"
      fi
    else
      _CAT_N=$((_CAT_N + _jp_n))
      _CAT_B=$((_CAT_B + _jp_b))
      _CAT_BAD=$((_CAT_BAD + _jp_bad))
    fi
  else
    _jc_file "$1"
  fi
}

_jc_file_group_begin() {
  _CAT_N=0
  _CAT_B=0
  _CAT_LEFT=0
  _CAT_BAD=0
}

_jc_file_group_end() {
  _fg_id="$1"
  if [ "$MODE" = run ]; then
    printf 'junk_category|%s|removed=%s|freed=%s|remaining=%s|state=%s\n' \
      "$_fg_id" "$_CAT_N" "$_CAT_B" "$_CAT_LEFT" "$( [ "$_CAT_BAD" = 0 ] && printf cleaned || printf partial )"
  else
    printf 'junk_category|%s|count=%s|bytes=%s|state=%s\n' \
      "$_fg_id" "$_CAT_N" "$_CAT_B" "$( [ "$_CAT_BAD" = 0 ] && printf ready || printf not_readable )"
  fi
  _TOTAL_N=$((_TOTAL_N + _CAT_N))
  _TOTAL_B=$((_TOTAL_B + _CAT_B))
  [ "$_CAT_BAD" = 0 ] || _TOTAL_BAD=$((_TOTAL_BAD + 1))
}

_jc_run_all() {
  # Android's DropBox contains event records; the directory itself stays in place.
  _jc_tree dropbox "$R/data/system/dropbox" all
  _jc_tree tombstones "$R/data/tombstones" tombstones
  _jc_tree anr "$R/data/anr" all
  _jc_tree environment "$R/cache/environment" all
  _jc_tree installer "$R/data/system/package_cache" all

  _jc_file_group_begin logs
  _jc_path "$R/data/log/gaia/gaialog_history"
  _jc_file "$R/cache/magisk.log"
  _jc_file_group_end logs

  # A recent backup journal may belong to an active operation. +0 means more than 24 hours.
  _jc_tree backup "$R/data/backup/pending" backup

  # Deliberately exact: module flags, controller scripts, settings and unknown files survive.
  _jc_file_group_begin local
  for _jc_name in asb_diag_report.txt asb_full_day.out uninstall.log soterfix.log webui_info.txt google_shelf_ui.html; do
    _jc_file "$R/data/local/tmp/$_jc_name"
  done
  _jc_file "$R/data/local/tmp/google_shelf_controller/controller.log"
  _jc_file_group_end local

  _jc_tree trash "$R/storage/emulated/0/.trash-storage" all
  _jc_tree screenshots "$R/storage/emulated/0/Pictures/Screenshots" screenshots
  _jc_tree coloros "$R/storage/emulated/0/ColorOS" coloros
}

case "$MODE" in
  status|run) ;;
  *) printf 'junk_cleanup|error|state=unknown_command\n'; exit 2 ;;
esac

if [ "$MODE" = run ]; then
  mkdir -p "$STATE" 2>/dev/null || { printf 'junk_cleanup|result|state=lock_error\n'; exit 0; }
  if ! mkdir "$LOCK" 2>/dev/null; then
    printf 'junk_cleanup|result|state=busy\n'
    exit 0
  fi
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
fi

_jc_run_all
if [ "$MODE" = run ]; then
  _jc_state=cleaned
  [ "$_TOTAL_N" -gt 0 ] || _jc_state=empty
  [ "$_TOTAL_BAD" -eq 0 ] || _jc_state=partial
  printf 'junk_cleanup|result|state=%s|removed_count=%s|freed_bytes=%s|failed_categories=%s\n' \
    "$_jc_state" "$_TOTAL_N" "$_TOTAL_B" "$_TOTAL_BAD"
else
  printf 'junk_cleanup|status|total_count=%s|total_bytes=%s|failed_categories=%s\n' \
    "$_TOTAL_N" "$_TOTAL_B" "$_TOTAL_BAD"
fi
