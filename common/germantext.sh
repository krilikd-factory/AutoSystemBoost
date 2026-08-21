#!/system/bin/sh

# German installer strings.
#
# Partial by design: install.sh sources englishtext.sh first and then this file, so
# anything not translated here stays readable English rather than blank. The strings
# chosen are the ones a user actually reads during an install - prompts, section
# headings and the closing note. Per-tweak detail lines remain English until someone
# who speaks the language writes them; a machine-translated technical claim that reads
# fluently and says the wrong thing is worse than English.

ASB_HINT="[VOL+] Aktivieren | [VOL-] Überspringen"
ASB_TIMEOUT="! Zeit abgelaufen (10 Sekunden). Installation abgebrochen."
ASB_HELP="VOL+ = aktivieren  |  VOL- = überspringen  |  10s Timeout = Abbruch"
ASB_SEC_DEVICE="GERÄT"
ASB_SEC_CONFIG="KONFIGURATION"
ASB_SEC_GOVERNOR="GOVERNOR"
ASB_SEC_AUDIO="AUDIO"
ASB_SEC_CAMERA="KAMERA"
ASB_SEC_MEDIA="MEDIEN"
ASB_SEC_PERF="LEISTUNG"
ASB_SEC_LOCATION="STANDORT"
ASB_SEC_WIFI="WLAN"
ASB_SEC_SYSTEM="SYSTEM"
ASB_SEC_CATEGORIES="VORBEREITETE KOMPONENTEN"
ASB_L_MIRROR_AUDIO_TOTAL="%s Audio-Einstellungsdatei(en) aus %s Gerätepfad(en) gespiegelt, damit ASB sie sicher bearbeiten kann"
ASB_SEC_INSTALLING="Installation für"
ASB_SEC_BUILDING="Overlay wird aus den Originaldateien dieses Geräts erstellt"
ASB_SEC_NOTICE="WAS SIE BEMERKEN WERDEN"
ASB_SEC_DSP="DSP-ENGINE"
ASB_SEC_DISPLAY="ANZEIGE"
ASB_SEC_HAPTICS="VIBRATION"
ASB_SEC_BATTERY="AKKU"
ASB_SEC_MEMORY="SPEICHER"
ASB_L_NOTICE_FOOT1="Alles davon ist in der WebUI einstellbar; ein Neustart"
ASB_L_NOTICE_FOOT2="aktiviert die Teile, die einen brauchen."
