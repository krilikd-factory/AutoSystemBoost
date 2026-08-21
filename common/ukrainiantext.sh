#!/system/bin/sh

# Ukrainian installer strings.
#
# Partial by design: install.sh sources englishtext.sh first and then this file, so
# anything not translated here stays readable English rather than blank. The strings
# chosen are the ones a user actually reads during an install - prompts, section
# headings and the closing note. Per-tweak detail lines remain English until someone
# who speaks the language writes them; a machine-translated technical claim that reads
# fluently and says the wrong thing is worse than English.

ASB_HINT="[VOL+] Увімкнути | [VOL-] Пропустити"
ASB_TIMEOUT="! Час вийшов (10 секунд). Встановлення скасовано."
ASB_HELP="VOL+ = увімкнути  |  VOL- = пропустити  |  таймаут 10с = скасування"
ASB_SEC_DEVICE="ПРИСТРІЙ"
ASB_SEC_CONFIG="КОНФІГУРАЦІЯ"
ASB_SEC_GOVERNOR="ГУБЕРНАТОР"
ASB_SEC_AUDIO="АУДІО"
ASB_SEC_CAMERA="КАМЕРА"
ASB_SEC_MEDIA="МЕДІА"
ASB_SEC_PERF="ПРОДУКТИВНІСТЬ"
ASB_SEC_LOCATION="ГЕОЛОКАЦІЯ"
ASB_SEC_WIFI="WI-FI"
ASB_SEC_SYSTEM="СИСТЕМА"
ASB_SEC_CATEGORIES="ПІДГОТОВЛЕНІ КОМПОНЕНТИ"
ASB_L_MIRROR_AUDIO_TOTAL="скопійовано аудіоналаштувань: %s із %s device-native шляхів — ASB змінює копії, а не систему"
ASB_SEC_INSTALLING="встановлення для"
ASB_SEC_BUILDING="створюємо накладку з рідних файлів саме цього телефона"
ASB_SEC_NOTICE="ЩО ВИ ПОМІТИТЕ"
ASB_SEC_DSP="DSP-ДВИГУН"
ASB_SEC_DISPLAY="ЕКРАН"
ASB_SEC_HAPTICS="ВІБРАЦІЯ"
ASB_SEC_BATTERY="БАТАРЕЯ"
ASB_SEC_MEMORY="ПАМʼЯТЬ"
ASB_L_NOTICE_FOOT1="Усе перелічене налаштовується у WebUI, а перезавантаження"
ASB_L_NOTICE_FOOT2="застосовує те, що його потребує."
