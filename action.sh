#!/system/bin/sh
MODDIR="${0%/*}"
MODID="AutoSystemBoost"

# WebUI redirect for Magisk users
# KSU/MMRL show WebUI button natively via webroot/
if [ -z "$MMRL" ] && [ ! -z "$MAGISKTMP" ]; then
  pm path io.github.a13e300.ksuwebui > /dev/null 2>&1 && {
    am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "$MODID"
    exit 0
  }
  pm path com.dergoogler.mmrl.wx > /dev/null 2>&1 && {
    am start -n "com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity" -e MOD_ID "$MODID"
    exit 0
  }
fi

PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"
echo "- AutoSystemBoost V19.1"
echo "- Current profile: $PROFILE"
echo ""
echo "- Install KSUWebUIStandalone or WebUI X"
echo "  to access the profile switcher UI."
echo ""
echo "- Opening Telegram channel..."

su -c "am start -a android.intent.action.VIEW -d 'tg://resolve?domain=OnePlusMod'" >/dev/null 2>&1 || \
su -c "am start -a android.intent.action.VIEW -d 'https://t.me/OnePlusMod'" >/dev/null 2>&1
