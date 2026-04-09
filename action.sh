#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}}"
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

# Update module.prop description with real active profile
case "$PROFILE" in
  performance) _desc='description=status: performance 🔥 | active ✅' ;;
  battery)     _desc='description=status: battery 🔋 | active ✅' ;;
  *)           _desc='description=status: balanced ⚖️ | active ✅' ;;
esac
sed "s/^description=.*/$_desc/" "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null
if grep -q '^description=' "$MODDIR/module.prop.tmp" 2>/dev/null; then
  cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop"
fi
rm -f "$MODDIR/module.prop.tmp"

echo "- AutoSystemBoost V36"
echo "- Current profile: $PROFILE"
echo ""
echo "- Opening Telegram channel..."

su -c "am start -a android.intent.action.VIEW -d 'tg://resolve?domain=OnePlusMod'" >/dev/null 2>&1 || \
su -c "am start -a android.intent.action.VIEW -d 'https://t.me/OnePlusMod'" >/dev/null 2>&1
