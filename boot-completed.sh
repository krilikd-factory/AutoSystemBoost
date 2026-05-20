#!/system/bin/sh
MODDIR=${0%/*}

(
  sleep 5
  _start=$(date +%s)
  _end=$((_start + 300))
  while [ "$(date +%s)" -lt "$_end" ]; do
    /system/bin/stop vendor.soter
    sleep 1
    /system/bin/pm clear com.tencent.soter.soterserver
    /system/bin/start vendor.soter
    sleep 1
    sleep 3
  done
) &

exit 0
