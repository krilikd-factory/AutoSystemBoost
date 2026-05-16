#!/system/bin/sh

ASB_HINT="[VOL+] Enable | [VOL-] Skip"
ASB_TIMEOUT="! Time is up (10 seconds). Installation canceled."

ASB_HELP="VOL+ = enable  |  VOL- = skip  |  10s timeout = cancel"

ASB_MENU_AUDIO=" 1) AUDIO (HAL/Codecs/Effects/Mixers)"
ASB_MENU_BT="2) Bluetooth (A2DP/LE Audio/Codecs)"
ASB_MENU_CAMERA="3) CAMERA (Photo/Video)"
ASB_MENU_CPU="4) CPU (Scheduler/Frequencies)"
ASB_MENU_VM="5) VM (Memory/Dirty/Swappiness)"
ASB_MENU_NET="6) NET (TCP/Qdisc/Buffers/Queues)"
ASB_MENU_WIFI="7) WiFi (Scan/Sleep)"
ASB_MENU_GPS="8) GPS (GNSS)"
ASB_MENU_KERNEL="9) KERNEL (printk/perf)"
ASB_MENU_LOG="10) LOGS (Services/Noise)"
ASB_MENU_RADIO_IMS="11) RADIO/IMS (VoLTE/VoNR/IMS auth)"
ASB_MENU_DISPLAY="12) DISPLAY (CABL/DPPS/Backlight)"
ASB_MENU_FPS="13) FPS (Frame rate caps/Recorder)"
ASB_MENU_SECURITY="14) SECURITY (Perf events/Snapshots)"

ASB_DONE_TITLE="ASB"
ASB_DONE_MSG="Module installed! Reboot required."
