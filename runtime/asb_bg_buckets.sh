#!/system/bin/sh
# asb_bg_buckets.sh restore - hand back the standby buckets background trimming forced.
#
# Background trimming runs from service.sh at boot. Turning it off in the WebUI changed
# the config and nothing else until the next reboot - the toast said "applied" while
# Instagram & co. stayed in "rare". This is the live half of "off": the same per-package
# record service.sh writes (pkg|bucket before ASB) and uninstall.sh reads.
REC="${ASB_BG_BUCKETS_ORIG:-/data/adb/asb/bg_buckets_orig}"
case "${1:-restore}" in
  restore)
    command -v am >/dev/null 2>&1 || exit 0
    [ -f "$REC" ] || { echo "bg buckets: nothing recorded"; exit 0; }
    _n=0
    while IFS='|' read -r _p _b; do
      [ -n "$_p" ] || continue
      # 5 (exempted) and 50+ cannot be set from the shell - left as Android has them.
      case "$_b" in 10|20|30|40|45) am set-standby-bucket "$_p" "$_b" >/dev/null 2>&1 && _n=$((_n + 1)) ;; esac
    done < "$REC"
    rm -f "$REC" 2>/dev/null
    echo "bg buckets: $_n app(s) back in the bucket they had before ASB"
    ;;
esac
exit 0
