#!/system/bin/sh
# asb_gfx_probe.sh <package> - frame statistics of one app, for Smart's smoothness check (fix185).
#
# Writes /dev/.asb/gfx.txt: one line "package frames janky" - the app's rendered and janky
# frame totals as Android's GraphicsStatsService counts them - or an empty file when the
# app has none. The governor asks at most every three minutes of screen-on time, for the
# app in front only, and takes the difference between two answers as one window.
#
# Why graphicsstats: system_server reads the counters from a buffer each HWUI app shares
# with it, so the app is never called (dumpsys gfxinfo would run inside the app). The dump
# lists the live buffer and the files of the last few days per package and version; their
# sum only grows while the app runs, and a day dropping off the end shows up as a smaller
# total, which the governor discards.
#
# Light by construction: one dumpsys, one awk, at low priority; a probe still running
# (a busy system_server) makes the next one skip instead of piling up.

PKG="$*"
OUT="${ASB_GFX_OUT:-/dev/.asb/gfx.txt}"
LOCK="${ASB_GFX_LOCK:-/dev/.asb/gfx.lock}"

[ "$#" -ge 1 ] && [ "$#" -le 4 ] || exit 0
for _gp in "$@"; do
  case "$_gp" in
    ''|*[!A-Za-z0-9._]*) exit 0 ;;
  esac
done
mkdir -p "${OUT%/*}" 2>/dev/null

if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than a minute belongs to a probe that died: take it over.
  _now="$(date +%s 2>/dev/null)"
  _lt="$(stat -c %Y "$LOCK" 2>/dev/null)"
  case "$_now$_lt" in *[!0-9]*|'') exit 0 ;; esac
  [ $((_now - _lt)) -ge 60 ] || exit 0
  rmdir "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

_to=""
command -v timeout >/dev/null 2>&1 && _to="timeout 15"

# Text form (Android 10+):
#   Package: com.foo
#   Total frames rendered: 1234
#   Janky frames: 56 (4.54%)
#   Janky frames (legacy): ...     <- not this one
$_to nice -n 10 dumpsys graphicsstats 2>/dev/null | nice -n 10 awk -v want="$PKG" '
  BEGIN { n = split(want, order, " "); for (i = 1; i <= n; i++) w[order[i]] = 1 }
  /^[[:space:]]*Package: / { p = $2; next }
  !(p in w) { next }
  /^[[:space:]]*Total frames rendered: / { t[p] += $4; seen[p] = 1; next }
  /^[[:space:]]*Janky frames: / { j[p] += $3; next }
  END { for (i = 1; i <= n; i++) { q = order[i]; if (q in seen) printf "%s %.0f %.0f\n", q, t[q], j[q] } }
' > "$OUT.tmp" 2>/dev/null
mv -f "$OUT.tmp" "$OUT" 2>/dev/null
exit 0
