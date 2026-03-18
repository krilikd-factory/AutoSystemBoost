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
    if [ "$REPLY" = "ok" ] || [ "$REPLY" = "ok:nochange" ]; then
        echo "ui_print [ASB] Governor notified: $NEXT ($REPLY)"
    else
        echo "$CURRENT" > "$MODDIR/current_profile"
        NEXT="$CURRENT"
        echo "ui_print [ASB] Governor sync failed, kept: $CURRENT"
    fi
else
    [ -x "$MODDIR/apply_profile.sh" ] && sh "$MODDIR/apply_profile.sh"
    echo "ui_print [ASB] Profile set (sh fallback): $NEXT"
fi

case "$NEXT" in
  performance) _DESC="description=status: performance 🔥 | active ✅" ;;
  battery)     _DESC="description=status: battery 🔋 | active ✅" ;;
  *)           _DESC="description=status: balanced ⚖️ | active ✅" ;;
esac
awk -v d="$_DESC" 'BEGIN{f=0}/^description=/{print d;f=1;next}{print}END{if(!f)print d}' \
  "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null
[ -s "$MODDIR/module.prop.tmp" ] && mv "$MODDIR/module.prop.tmp" "$MODDIR/module.prop"
rm -f "$MODDIR/module.prop.tmp" 2>/dev/null || true

echo "ui_print [ASB] → $NEXT"
