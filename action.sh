#!/system/bin/sh

MODID="AutoSystemBoost"
MODDIR="/data/adb/modules/$MODID"
ASB_GOV="$MODDIR/bin/asb"

CURRENT="$(cat "$MODDIR/current_profile" 2>/dev/null || echo "balanced")"

case "$CURRENT" in
  battery)     NEXT="balanced"     ;;
  balanced)    NEXT="performance"  ;;
  performance) NEXT="battery"      ;;
  *)           NEXT="balanced"     ;;
esac

echo "$NEXT" > "$MODDIR/current_profile"

GOV_PID="$(cat /dev/.asb/governor.pid 2>/dev/null)"
if [ -n "$GOV_PID" ] && kill -0 "$GOV_PID" 2>/dev/null && [ -x "$ASB_GOV" ]; then
    REPLY="$("$ASB_GOV" "profile:$NEXT" 2>/dev/null)"
    STATUS="$("$ASB_GOV" "status"       2>/dev/null)"
    echo "ui_print [ASB] Governor notified: $NEXT"
    echo "ui_print [ASB] Status: $STATUS"
else
    [ -x "$MODDIR/apply_profile.sh" ] && sh "$MODDIR/apply_profile.sh"
    echo "ui_print [ASB] Profile set (sh fallback): $NEXT"
fi

case "$NEXT" in
  performance) DESC="status: performance 🔥 | active ✅" ;;
  battery)     DESC="status: battery 🔋 | active ✅" ;;
  *)           DESC="status: balanced ⚖️ | active ✅" ;;
esac
sed -i "s/^description=.*/description=$DESC/" "$MODDIR/module.prop" 2>/dev/null || true

echo "ui_print [ASB] → $NEXT"
