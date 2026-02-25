#!/system/bin/sh

TG_LINK="tg://resolve?domain=OnePlusMod"
WEB_LINK="https://t.me/OnePlusMod"

ui_print "- Opening Telegram channel..."
ui_print "  $WEB_LINK"

su -c "am start -a android.intent.action.VIEW -d '$TG_LINK'" >/dev/null 2>&1

if [ $? -ne 0 ]; then
  su -c "am start -a android.intent.action.VIEW -d '$WEB_LINK'" >/dev/null 2>&1
fi
