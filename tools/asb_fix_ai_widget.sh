#!/system/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (su -c 'sh $0')"
  exit 1
fi

echo "==================================================="
echo "  ASB V43 — Smart Features Recovery"
echo "==================================================="
echo ""

PACKAGES="
com.oplus.aimemory
com.oplus.deepthinker
com.oplus.athena
com.oplus.pantanal.ums
com.oplus.appsense
com.oplus.healthservice
com.oplus.romupdate
com.oplus.wirelesssettings
com.oplus.qualityprotect
com.oplus.appplatform
com.oplus.appbooster
com.oplus.powermonitor
com.oplus.nas
com.oplus.nhs
com.oplus.epona
com.oplus.sauhelper
com.oplus.sau
com.oplus.metis
com.oplus.statistics.rom
com.oplus.trafficmonitor
com.oplus.onetrace
com.oplus.customize.coreapp
com.oplus.customize.cust_manage
com.oplus.customize.systemui
com.oplus.customize.opmconfigs
com.oplus.gameopt
com.oplus.gamespaceui
"

ENABLED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

echo "[1/3] Re-enabling OnePlus system packages..."
for pkg in $PACKAGES; do
  [ -z "$pkg" ] && continue

  is_disabled="$(pm list packages -d 2>/dev/null | grep -c "^package:${pkg}$")"
  is_installed="$(pm list packages 2>/dev/null | grep -c "^package:${pkg}$")"

  if [ "$is_installed" -eq 0 ]; then
    printf '   - %-30s ... not installed (skip)\n' "$pkg"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  if [ "$is_disabled" -gt 0 ]; then
    pm enable "$pkg" >/dev/null 2>&1
    state_after="$(pm list packages -d 2>/dev/null | grep -c "^package:${pkg}$")"
    if [ "$state_after" -eq 0 ]; then
      printf '   - %-30s ... ✓ enabled\n' "$pkg"
      ENABLED_COUNT=$((ENABLED_COUNT + 1))
    else
      printf '   - %-30s ... ✗ FAILED\n' "$pkg"
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
  else
    printf '   - %-30s ... ok (already enabled)\n' "$pkg"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
  fi
done

echo ""
echo "[2/3] Restoring stock Doze (notification delay fix)..."
current_doze="$(settings get global device_idle_constants 2>/dev/null)"
if [ -n "$current_doze" ] && [ "$current_doze" != "null" ]; then
  settings delete global device_idle_constants >/dev/null 2>&1
  echo "   ✓ device_idle_constants cleared — Android defaults restored"
else
  echo "   - already at default"
fi

echo ""
echo "[3/3] Clearing aggressive network polling..."
current_poll="$(settings get global network_stats_poll_interval 2>/dev/null)"
if [ -n "$current_poll" ] && [ "$current_poll" != "null" ]; then
  settings delete global network_stats_poll_interval >/dev/null 2>&1
  echo "   ✓ network_stats_poll_interval cleared"
else
  echo "   - already at default"
fi

echo ""
echo "==================================================="
printf '  Summary: %d enabled, %d already-ok/skipped, %d failed\n' \
  "$ENABLED_COUNT" "$SKIPPED_COUNT" "$FAILED_COUNT"
echo "==================================================="
echo ""
echo "Next steps:"
echo "  1. Lock + unlock the screen — 3D wallpaper should return."
echo "  2. Long-press home → Widgets → re-add 'AI Suggestions'."
echo "  3. Check Settings → Health to confirm step tracking is back."
echo "  4. If notifications were delayed, reboot once to refresh AlarmManager."
echo ""
echo "  Then flash the new AutoSystemBoost-V43-release.zip (with the"
echo "  minimal-safe BG_TRIM list). Your saved config in"
echo "  /data/adb/asb_user_config will be picked up automatically."
echo "==================================================="
