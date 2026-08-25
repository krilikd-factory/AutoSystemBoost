# V64 Efficiency Audit Patch

Этот патч подготовлен по диагностике OnePlus CPH2745 / SM8850 с Android 16. Он уменьшает boot-конфликты, лишние фоновые пробуждения и риск тяжёлых service/ZRAM-операций, не меняя пользовательские значения `governor.conf` автоматически.

## Изменения

| Область | Новое поведение |
|---|---|
| Deferred core boot | Исключён широкий `asb_apply_profile_once`; применяются только узкие core-policy операции |
| ZRAM | Существующий vendor ZRAM сохраняется; сброс допускается только с `/data/adb/asb/allow_zram_rebuild` |
| BG_TRIM | `safe` не отключает пакеты/службы и не меняет Wi‑Fi discovery; disruptive aggressive требует `/data/adb/asb/allow_disruptive_bg_trim` |
| Init-services | Их остановка требует `/data/adb/asb/allow_service_stops` |
| DSP route watcher | Интервал fallback-проверки увеличен до 60 с |
| Night observer | Framework/PM/appops helpers запускаются только при screen-off и максимум раз в час |
| Native governor | Периоды screen-off idle/deep-idle установлены в 10/30 с вместо 5/10 с |

## Важное для существующих установок

Сохранённая конфигурация пользователя не переписывается. Если в ней включены `BG_TRIM_LEVEL=aggressive`, `doze_level=aggressive`, `gms_trim=strict`, `gms_freeze=safe`, `wakelock_action=1` или `gnss_trim=1`, рекомендуемый стартовый режим после обновления — `safe`/`stock`/`off` до контрольного суточного лога.

Не создавайте opt-in маркеры без измеренной причины. Они преднамеренно возвращают более рискованные действия, отключённые по умолчанию.
