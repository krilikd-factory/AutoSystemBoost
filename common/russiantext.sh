#!/system/bin/sh

ASB_HINT="[VOL+] Включить | [VOL-] Пропустить"
ASB_TIMEOUT="! Время вышло (10 секунд). Установка отменена."

ASB_HELP="VOL+ = включить  |  VOL- = пропустить  |  таймаут 10с = отмена"

ASB_CFG_FOUND_TITLE="Найдена сохранённая конфигурация"
ASB_CFG_FOUND_HINT="VOL+ = использовать сохранённую  |  VOL- = выбрать заново"
ASB_CFG_USING_SAVED="Использую сохранённую конфигурацию от:"
ASB_CFG_RESELECT="Выбираю категории заново..."
ASB_CFG_SAVED_TO="Конфигурация сохранена:"

ASB_MENU_AUDIO=" 1) АУДИО (HAL/Кодеки/Эффекты/Микшеры)"
ASB_MENU_BT="2) Bluetooth (A2DP/LE Audio/Кодеки)"
ASB_MENU_CAMERA="3) КАМЕРА (Фото/Видео)"
ASB_MENU_CPU="4) CPU (Планировщик/Частоты)"
ASB_MENU_VM="5) VM (Память/Dirty/Swappiness)"
ASB_MENU_NET="6) NET (TCP/QDISC/Буферы/Очереди)"
ASB_MENU_WIFI="7) WiFi (Скан/Сон)"
ASB_MENU_GPS="8) GPS (GNSS)"
ASB_MENU_KERNEL="9) ЯДРО (Printk/Perf)"
ASB_MENU_LOG="10) ЛОГИ (Сервисы/Шум)"
ASB_MENU_RADIO_IMS="11) РАДИО/IMS (VoLTE/VoNR/IMS авторизация)"
ASB_MENU_DISPLAY="12) ДИСПЛЕЙ (CABL/DPPS/Подсветка)"
ASB_MENU_FPS="13) FPS (Частота кадров/Запись)"
ASB_MENU_SECURITY="14) БЕЗОПАСНОСТЬ (Perf события/Снапшоты)"
ASB_MENU_BG_TRIM="15) BG_TRIM (Телеметрия + Wakeup'ы + Doze)"

ASB_DONE_TITLE="ASB"
ASB_DONE_MSG="Модуль установлен! Перезагрузка обязательна."
