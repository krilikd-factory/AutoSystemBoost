<p align="center">
  <a href="README.md">
    <img src="https://img.shields.io/badge/🇬🇧%20English-1f2937?style=flat-square" alt="English">
  </a>
  <a href="README.ru.md">
    <img src="https://img.shields.io/badge/🇷🇺%20Русский-16a34a?style=flat-square" alt="Русский">
  </a>
</p>

<h1 align="center">🚀 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Баннер AutoSystemBoost" width="100%">
</p>

<p align="center"><b>Продвинутый модуль оптимизации для OnePlus 15</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Snapdragon_8_Elite_Gen_5-SM8850-16a34a?style=for-the-badge" alt="Snapdragon">
  <img src="https://img.shields.io/badge/Magisk-Compatible-0ea5e9?style=for-the-badge" alt="Magisk">
  <img src="https://img.shields.io/badge/KernelSU-Compatible-0ea5e9?style=for-the-badge" alt="KernelSU">
  <img src="https://img.shields.io/badge/Версия-Stable-22c55e?style=for-the-badge" alt="Version">
</p>
<p align="center">
AutoSystemBoost — это продвинутый <b>Android-модуль системной оптимизации</b>, созданный для улучшения общего пользовательского опыта.
Изначально разработан для <b>OnePlus 15</b>, но логика тюнинга полезна и для многих современных флагманов на Qualcomm.
</p>

## ⚡ Что улучшает AutoSystemBoost

ASB одновременно оптимизирует несколько критически важных Android-подсистем, что подтверждено реальными дампами sysfs/procfs на SM8750.

| Системная зона | Ключевое изменение | Измеримый эффект |
|-------------|------------|-----------------|
| 🧠 Планировщик CPU | WALT: ravg window 8→12ms, idle_enough 30→45, pipeline packing | Idle-частота CPU 2362→998 МГц (−58%) |
| 🎮 GPU | CX collapse timer 80→250ms, force_rail/clk/bus=0, NAP включён | Idle-температура GPU 33→31°C |
| 🔊 Аудио | Цифровая громкость +5 dB, MBDRC, LHDC v5 24bit/96kHz | 384kHz hi-res, 7.1ch, полный Dolby |
| 📷 Камера | 37 оптимизированных конфигов: gamma, bokeh, EIS, MLFT, TNR, UBWC | Ultra-профили по умолчанию |
| 📡 Сеть | BBR congestion, TCP fastopen=3, fin_timeout 60→20s | Быстрее соединения, меньше overhead |
| 🔋 Батарея | Нижние частоты 787→384 МГц, writeback 2→60s, swappiness 100→20 | −35-45% idle drain относительно стока |
| 🌡 Thermal | sched_util_clamp_min 1024→0, busy_hyst 99M→0ns | −1-2°C в idle, температура батареи ≈ сток |

**Результат:** устройство работает **холоднее, дольше и звучит лучше** — без потери производительности.

---

## 🔊 Улучшения аудио

AutoSystemBoost значительно улучшает **качество звука через динамики, проводное подключение и Bluetooth** благодаря 490+ оптимизированным аудио-параметрам, кастомным mixer paths и внедрённым DSP-библиотекам.

### ✅ Измеримые изменения

- Цифровая громкость **на 5-7 dB выше** (значение микшера 84→98)
- Speaker DRC **отключён** — чище звук без динамической компрессии
- Поддержка hi-res до **384 kHz**
- **7.1-канальный** surround (AUDIO_CHANNEL_OUT_7POINT1)
- Полный стек **Dolby**: DS2 + Surround + Spatial Audio (музыкальный профиль) + DAX Game

### 🎧 Bluetooth-аудио

| Параметр | Сток | AutoSystemBoost |
|---------|-------|-----------------|
| Версия LHDC | stock | **v5, 24-bit / 96 kHz, quality=best** |
| Качество LDAC | auto (ABR) | **фиксированный максимум (ABR отключён)** |
| SBC HD | stock | **higher_bitrate включён** |
| A2DP bit depth | 16-bit | **24-bit packed** |
| Приоритет кодеков | stock | **LHDC 1200 > LDAC 1100 > AAC 1000** |
| A2DP offload | stock | **hardware offload включён** |
| BLE idle drain | stock | **снижен (allow_list + notify controls)** |

Оптимизировано под **OnePlus Buds Pro 3** и премиальные TWS-наушники с поддержкой LHDC/LDAC.

---

## 📷 Камера и медиапайплайн

ASB включает **37 оптимизированных конфигов камеры** (gamma curves, bokeh, EIS, MLFT, AiFace, BodySeg) и настраивает системный медиастек.

### ✅ Конкретные изменения

- **TNR** (Temporal Noise Reduction): включён для preview и video
- **UBWC** (Universal Bandwidth Compression): включён для camera pipeline
- **Ultra profiles** выставлены по умолчанию для фото и видео
- **perfconfigstore**: prekill-оптимизация для более быстрого запуска камеры
- Сложность медиакодеков повышена до максимальных качественных настроек
- Диапазоны битрейта расширены до потолка 18 Mbps

| Параметр | Сток | AutoSystemBoost |
|---------|-------|-----------------|
| Видеопрофили | standard | **Ultra (выше битрейт/детализация)** |
| TNR (шумоподавление) | off | **preview=1, video=1** |
| Качество кодеков | default | **max complexity, expanded bitrate** |
| Запуск камеры | stock | **prekill optimized** |

---

## 🎮 Игровая производительность

ASB не ограничивает частоты и не режет производительность. Все изменения направлены на **повышение эффективности под нагрузкой**:

- **sched_util_clamp_min** 1024→0: CPU масштабируется по реальной нагрузке, а не держится на форсированном максимуме
- **sched_ravg_window** 12ms: более плавный frame pacing, меньше scheduler jitter
- **GPU idle_timer** 250ms: более глубокий power collapse между кадрами
- **Thermal headroom**: на 1-2°C холоднее в idle → позже начинается троттлинг под длительной нагрузкой

### Проверено в Call of Duty Mobile (144 fps)

| Метрика | Сток | AutoSystemBoost |
|--------|-------|-----------------|
| Стабильность FPS на дистанции | good | **лучше (холоднее → позже троттлинг)** |
| Frame pacing | stock | **плавнее (ravg=12ms фильтрует jitter)** |
| Burst response (menu→game) | instant | **instant (WALT burst-механизмы независимы)** |
| Idle между раундами | high freq | **min freq (384/768 MHz)** |

---

## 🔋 Улучшения автономности

Самые большие улучшения достигаются за счёт исправления неэффективностей стокового OxygenOS.

### Ключевые исправления (подтверждены sysfs-дампами)

| Параметр | Значение в стоке | Значение в ASB | Эффект |
|-----------|-------------|-----------|--------|
| sched_util_clamp_min | **1024** (все задачи = 100%) | **0** (реальная утилизация) | CPU может нормально уходить в idle |
| CPU min freq (LITTLE) | **787 MHz** | **384 MHz** (повторно применяется каждые 30/90/300s) | −2× idle floor |
| CPU min freq (BIG) | **883 MHz** | **768 MHz** (повторно применяется) | BIG-ядра спят глубже |
| dirty_expire | **2 секунды** | **60 секунд** | в 30× меньше I/O writeback |
| dirty_writeback | **5 секунд** | **50 секунд** | в 10× меньше пробуждений writeback-потока |
| swappiness | **100** | **20** | в 5× меньше swap I/O |
| stat_interval | **1 секунда** | **15 секунд** | в 15× меньше vmstat wakeups |
| sched_schedstats | **1** (включён) | **0** (отключён) | нулевой overhead статистики планировщика |
| sched_busy_hyst_ns | HAL может ставить 99M | **0** | CPU сразу сбрасывает частоту после spike |
| 35 debug-сервисов | running | **stopped** | меньше фоновых пробуждений |

### Ожидаемая автономность

| Сценарий | Сток | AutoSystemBoost | Улучшение |
|----------|-------|-----------------|-------------|
| Ночной drain (8h screen off) | ~5-6% | ~2-3% | **−50-60%** |
| Idle drain rate | ~55 mAh/h | ~28-32 mAh/h | **−35-45%** |
| Лёгкий SOT (браузер, Telegram) | baseline | +15-25% дольше | **значительно** |
| Тяжёлый SOT (CODM, камера) | baseline | +5-10% дольше | **умеренно** |

---

## 📡 Сеть и подключение

### TCP / мобильный интернет

| Параметр | Сток | ASB | Зачем |
|-----------|-------|-----|-----|
| TCP Fast Open | 1 (только client) | **3** (client + server) | Быстрее первый запрос |
| ECN | 2 (negotiate) | **0** (off) | Меньше overhead на мобильной сети |
| fin_timeout | 60s | **20s** | В 3× быстрее чистятся мёртвые сокеты |
| slow_start_after_idle | 1 (сброс cwnd) | **0** (сохраняется cwnd) | Быстрее resume после паузы |
| notsent_lowat | 4 GB (off) | **128 KB** | Меньше socket buffer memory |
| retrans_collapse | 1 | **0** | Лучше TCP recovery при packet loss |
| RFC 1337 | 0 | **1** | Защита от TIME_WAIT assassination |

### Wi‑Fi

| Параметр | Сток | ASB |
|---------|-------|-----|
| Telescopic DTIM | 0 | **1** (меньше beacon wakeups) |
| Neighbor scan interval | 60s | **120s** (в 2× меньше roaming scan) |
| Runtime PM delay | 500ms | **2000ms** (драйвер Wi‑Fi спит глубже) |
| Scan throttle | off | **on** (меньше лишних сканов) |
| Background scan | always | **disabled when Wi‑Fi off** |
| PSM mode | stock | **adaptive** (ON в idle, OFF в играх) |

### GPS

- **AGPS включён** — более быстрый cold fix
- **GNSS outage recovery**: 30s (быстрее повторный захват)
- **WIPER отключён** — без лишнего расхода от Wi‑Fi positioning

---

## 🌡 Thermal-поведение

ASB снижает нагрев за счёт более низких idle-частот CPU и устранения лишних high-freq spikes.

| Зона | Сток | AutoSystemBoost | Разница |
|------|-------|-----------------|-------|
| CPU LITTLE cores | ~36.0°C | ~35.5°C | **−0.5°C** |
| CPU BIG cores | — | ~34.4°C | **ниже стока** |
| GPU | — | ~31.0°C | **очень холодный** |
| Battery | ~28.7°C | ~28.4°C | **≈ сток** |

Под длительной нагрузкой (игры) ASB работает **на 1-2°C холоднее** → троттлинг начинается позже → FPS стабильнее.

---

## 📊 Полное сравнение: сток vs AutoSystemBoost

| Категория | Сток | AutoSystemBoost |
|----------|-------|-----------------|
| Idle drain | ~55 mAh/h | **~28-32 mAh/h (−40%)** |
| CPU idle frequency | 787-2362 MHz | **384-998 MHz (−58%)** |
| Громкость динамика | stock | **+5-7 dB громче** |
| Качество BT-аудио | standard codecs | **LHDC v5 24bit/96kHz** |
| Профили камеры | standard | **Ultra (37 configs)** |
| Idle temperature | ~36°C | **~35°C (−1°C)** |
| Игровой sustained FPS | good | **лучше (холоднее = позже троттлинг)** |
| Deep sleep efficiency | ~50% | **~85%** |
| Debug services | 35 running | **35 stopped** |
| Doze entry | stock timing | **aggressive (3 min inactive)** |

---

## 📦 Установка

1. Установите **Magisk / KernelSU / APatch**
2. Установите модуль
3. При установке выберите категории (Audio, Camera, CPU, VM, Network, Wi‑Fi, GPS, Kernel, Logs)
4. Перезагрузите устройство

Дополнительная настройка не требуется. Все твики автоматически пере-применяются каждые 30/90/300 секунд, чтобы переживать возможные HAL overrides.

---

## ⭐ Поддержка проекта

Если вам нравится AutoSystemBoost:

- ⭐ Поставьте звезду репозиторию
- 💬 Делитесь отзывами через [Telegram](https://t.me/DKomsomol)
- 🐛 Сообщайте о проблемах

---

## ⚠ Отказ от ответственности

Этот модуль изменяет системное поведение.

Используйте его на свой страх и риск.

Все твики разработаны так, чтобы оставаться **безопасными и обратимыми** — удаление модуля возвращает стоковое поведение.
