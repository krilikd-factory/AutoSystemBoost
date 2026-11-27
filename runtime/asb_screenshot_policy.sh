#!/system/bin/sh
# Transactional per-user selection for ASB's experimental screenshot fix.
# This script does not install hooks or modify any app. Missing policy = off.
MODDIR="${MODDIR:-/data/adb/modules/AutoSystemBoost}"
CONF="${ASB_SCREENSHOT_CONF:-$MODDIR/config/governor.conf}"
STATE_DIR="${ASB_SCREENSHOT_STATE_DIR:-/data/adb/asb/screenshot_fix}"
ZDIR="${ASB_SCREENSHOT_ZYGISK_DIR:-$MODDIR/zygisk}"
if [ -z "${ASB_SCREENSHOT_ZYGISK_DIR:-}" ] && [ ! -d "$ZDIR" ] && [ -d "$MODDIR/zygisk.off" ]; then
  ZDIR="$MODDIR/zygisk.off"
fi
STATE="$STATE_DIR/selection.policy"
LIVE="$ZDIR/screenshot.policy"
ASB_LTPO_LOCK_DIR="$STATE_DIR/selection.lock"
[ -r "$MODDIR/runtime/asb_ltpo_lock.sh" ] || { echo 'error=lock_helper_missing'; exit 1; }
. "$MODDIR/runtime/asb_ltpo_lock.sh"

valid_user() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "${#1}" -le 3 ] && [ "$1" -le 999 ] 2>/dev/null; }
valid_package() {
  [ "${#1}" -le 127 ] || return 1
  printf '%s\n' "$1" | awk 'BEGIN{ok=0} /^[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)+$/ {ok=1} END{exit !ok}'
}
protected_package() {
  case "$1" in
    system_server|com.android.systemui|com.android.packageinstaller|com.android.permissioncontroller|com.android.settings|com.android.phone|com.android.providers.media|com.android.providers.downloads|me.weishu.kernelsu|com.rifsxd.ksunext|com.topjohnwu.magisk|io.github.vvb2060.magisk|org.lsposed.manager|com.tsng.hidemyapplist|android.*|com.android.shell*|com.qualcomm.*|com.qti.*|vendor.*|com.oplus.safecenter*|com.coloros.safecenter*|com.heytap.safecenter*) return 0 ;;
    *) return 1 ;;
  esac
}
valid_policy() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(wc -c < "$1" 2>/dev/null)" -le 8192 ] 2>/dev/null || return 1
  # END and an exact count detect partial writes. Reject unknown lines.
  awk '
    NR==1 { if ($0 != "ASB_SCREENSHOT_V1") exit 1; next }
    /^END=/ { if (done || $0 !~ /^END=[0-9]+$/ || (length(substr($0,5)) > 1 && substr($0,5,1) == "0") || substr($0,5)+0 != n || n > 64) exit 1; done=1; next }
    { if (done || split($0,a,"|") != 2 || a[1] !~ /^[0-9]+$/ || length(a[1]) > 3 || (length(a[1]) > 1 && substr(a[1],1,1) == "0") || a[1]+0 > 999 ||
          length(a[2]) > 127 || a[2] !~ /^[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)+$/ || seen[$0]++) exit 1; n++ }
    END { if (!done) exit 1 }
  ' "$1" || return 1
  # Every line, including END, needs its terminating newline.
  [ "$(tail -c 1 "$1" 2>/dev/null | od -An -tu1 | tr -d ' \n')" = 10 ]
}
enabled() {
  [ ! -e "${ASB_SCREENSHOT_SAFE_MODE:-/dev/.asb/safe_mode}" ] &&
  [ ! -e "${ASB_SCREENSHOT_ZYGISK_DISABLE:-/data/adb/asb/zygisk_observer/disable}" ] &&
  grep -Eq '^[[:space:]]*zygisk_enabled[[:space:]]*=[[:space:]]*1([[:space:]]|$)' "$CONF" 2>/dev/null
}
cleanup() {
  [ -z "${_tmp:-}" ] || rm -f -- "$_tmp" 2>/dev/null
  [ -z "${_new:-}" ] || rm -f -- "$_new" 2>/dev/null
  [ -z "${_filtered:-}" ] || rm -f -- "$_filtered" 2>/dev/null
  [ -z "${_live_tmp:-}" ] || rm -f -- "$_live_tmp" 2>/dev/null
  asb_ltpo_unlock
}
lock() {
  mkdir -p "$STATE_DIR" "$ZDIR" 2>/dev/null || return 1
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] && [ -d "$ZDIR" ] && [ ! -L "$ZDIR" ] || return 1
  asb_ltpo_lock || return 1
  trap 'cleanup' EXIT
  trap 'exit 1' HUP INT TERM
}
publish() {
  valid_policy "$STATE" || { rm -f -- "$LIVE" 2>/dev/null; echo 'error=invalid_saved_policy'; return 1; }
  if ! enabled; then
    rm -f -- "$LIVE" 2>/dev/null || { echo 'error=publish_failed'; return 1; }
    return 0
  fi
  # An empty selection needs no live policy and no per-process parsing.
  if [ "$(tail -n 1 "$STATE" 2>/dev/null)" = 'END=0' ]; then
    rm -f -- "$LIVE" 2>/dev/null || { echo 'error=publish_failed'; return 1; }
    return 0
  fi
  if [ -f "$LIVE" ] && [ ! -L "$LIVE" ] && cmp -s "$STATE" "$LIVE"; then
    [ "$(stat -c %a "$LIVE" 2>/dev/null)" = 600 ] && return 0
    chmod 0600 "$LIVE" 2>/dev/null && return 0
    rm -f -- "$LIVE" 2>/dev/null; echo 'error=publish_failed'; return 1
  fi
  _live_tmp="$(mktemp "$ZDIR/.screenshot-policy.XXXXXX")" || {
    rm -f -- "$LIVE" 2>/dev/null
    echo 'error=publish_failed'; return 1
  }
  if ! cat "$STATE" > "$_live_tmp" || ! cmp -s "$STATE" "$_live_tmp" || ! chmod 0600 "$_live_tmp" || ! mv -f "$_live_tmp" "$LIVE"; then
    rm -f -- "$LIVE" 2>/dev/null
    echo 'error=publish_failed'; return 1
  fi
  _live_tmp=''
}

case "${1:-}" in
  status)
    if valid_policy "$STATE"; then n="$(sed -n 's/^END=//p' "$STATE")"; s=ok
    elif [ -e "$STATE" ] || [ -L "$STATE" ]; then n=unknown; s=invalid
    else n=0; s=empty; fi
    active=0; enabled && active=1
    published=0
    if [ "$active" = 1 ] && valid_policy "$STATE" && valid_policy "$LIVE" && cmp -s "$STATE" "$LIVE"; then published=1; fi
    printf 'backend=experimental selected=%s policy=%s zygisk_enabled=%s policy_published=%s\n' "$n" "$s" "$active" "$published" ;;
  list)
    [ -e "$STATE" ] || exit 0
    valid_policy "$STATE" || { echo 'error=invalid_saved_policy'; exit 1; }
    sed '1d;$d;s/^/entry|/' "$STATE" ;;
  add|remove|clear|publish)
    action="$1"; user="${2:-}"; pkg="${3:-}"
    if [ "$action" = add ] || [ "$action" = remove ]; then
      valid_user "$user" && valid_package "$pkg" || { echo 'error=invalid_selection'; exit 2; }
      # Canonical decimal form prevents multiple textual names for one Android user.
      user="$(printf '%s' "$user" | sed 's/^0*//')"; [ -n "$user" ] || user=0
    fi
    if [ "$action" = add ]; then
      protected_package "$pkg" && { echo 'error=protected_package'; exit 1; }
      result="$(cmd package path --user "$user" "$pkg" 2>/dev/null)" || { echo 'error=package_unavailable'; exit 1; }
      printf '%s\n' "$result" | grep -q '^package:/' || { echo 'error=package_unavailable'; exit 1; }
    fi
    umask 077
    lock || { echo 'error=lock_unavailable'; exit 1; }
    if [ "$action" = publish ]; then publish || exit 1; echo 'status=published backend=experimental'; exit 0; fi
    if [ "$action" != clear ] && { [ -e "$STATE" ] || [ -L "$STATE" ]; } && ! valid_policy "$STATE"; then
      rm -f -- "$LIVE" 2>/dev/null
      echo 'error=invalid_saved_policy'; exit 1
    fi
    _entries="$(mktemp "$STATE_DIR/.entries.XXXXXX")" || exit 1
    _tmp="$_entries"
    if [ "$action" != clear ] && [ -f "$STATE" ]; then sed '1d;$d' "$STATE" > "$_entries" || exit 1; fi
    if [ "$action" = add ]; then
      grep -Fxq "$user|$pkg" "$_entries" || printf '%s|%s\n' "$user" "$pkg" >> "$_entries" || exit 1
    elif [ "$action" = remove ]; then
      _filtered="$_entries.filtered"
      grep -Fxv "$user|$pkg" "$_entries" > "$_filtered" || [ "$?" = 1 ] || exit 1
      mv -f "$_filtered" "$_entries" || exit 1
    fi
    count="$(wc -l < "$_entries" | tr -d ' ')"
    [ "$count" -le 64 ] || { echo 'error=selection_limit'; exit 1; }
    _new="$(mktemp "$STATE_DIR/.policy.XXXXXX")" || exit 1
    { printf 'ASB_SCREENSHOT_V1\n'; cat "$_entries"; printf 'END=%s\n' "$count"; } > "$_new" || exit 1
    valid_policy "$_new" || { rm -f -- "$_new"; echo 'error=policy_validation'; exit 1; }
    mv -f "$_new" "$STATE" || exit 1
    _new=''
    publish || exit 1
    printf 'status=saved backend=experimental selected=%s\n' "$count" ;;
  *) echo 'usage: asb_screenshot_policy.sh status|list|add USER PACKAGE|remove USER PACKAGE|clear|publish'; exit 2 ;;
esac
