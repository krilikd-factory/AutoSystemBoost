#!/bin/sh
# Contract: the WebUI does not poll the governor while it is not visible.
# The manager keeps the WebView alive in the background; its timers kept spawning root
# shells every 3 s (Live page) or 30 s (home) while the user was in another app.
set -u
H="$(cd "$(dirname "$0")/.." && pwd)/webroot/index.html"
fail=0
sed -n '/^async function pollLive(visible) {/,/^  try {/p' "$H" | grep -q 'if (document.hidden) return;' \
  || { echo "FAIL webui: pollLive runs while hidden" >&2; fail=1; }
grep -q "if (!document.hidden) pollLive(_liveOpen);" "$H" \
  || { echo "FAIL webui: no catch-up poll when the page is shown again" >&2; fail=1; }
[ "$fail" = 0 ] && echo "PASS webui hidden poll"
exit "$fail"
