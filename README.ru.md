<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-1f2937?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-16a34a?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">🚀 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Banner" width="80%">
</p>

<p align="center"><b>Адаптивный runtime-движок для OnePlus 15 • Snapdragon 8 Elite</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Snapdragon_8_Elite-Gen_5-dc2626?style=for-the-badge" alt="SM8850">
  <img src="https://img.shields.io/badge/Root-KSU_%7C_KSUN_%7C_APATCH_%7C_RESUKISU_%7C_MAGISK-16a34a?style=for-the-badge" alt="Root">
  <br>
  <img src="https://img.shields.io/badge/Governor-Native_C-0ea5e9?style=for-the-badge" alt="C">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
</p>

<p align="center">
  <img src="https://img.shields.io/github/downloads/krilikd/AutoSystemBoost/total?style=for-the-badge&color=0969da&label=%D0%A1%D0%BA%D0%B0%D1%87%D0%B8%D0%B2%D0%B0%D0%BD%D0%B8%D0%B9&logo=github" alt="Downloads">
  <img src="https://img.shields.io/github/v/release/krilikd/AutoSystemBoost?style=for-the-badge&color=16a34a&label=%D0%92%D0%B5%D1%80%D1%81%D0%B8%D1%8F" alt="Release">
  <img src="https://img.shields.io/github/stars/krilikd/AutoSystemBoost?style=for-the-badge&color=f59e0b&label=Stars&logo=github" alt="Stars">
</p>

---

## ✨ Не набор твиков — а полноценная runtime-система

AutoSystemBoost — это **нативный C-демон** + shell-оркестратор + WebUI, который каждые **2 секунды** в реальном времени принимает решения о поведении CPU, GPU, планировщика и термалов.

```
┌──────────────────────────────────────────────────┐
│  WebUI — переключение профилей, статус           │
├──────────────────────────────────────────────────┤
│  action.sh → Unix-сокет → команды governor       │
├──────────────────────────────────────────────────┤
│  service.sh — загрузочный оркестратор (1150 стр) │
│  runtime/ — reconcile, watchdog, utils           │
├──────────────────────────────────────────────────┤
│  bin/asb — НАТИВНЫЙ C-ДЕМОН (2744 строки)        │
│    ├── FSM: 6 состояний × 3 профиля              │
│    ├── Session Plan: 12 полей политики           │
│    ├── Anti-Clamp: борьба с вендорным зажимом    │
│    ├── Storm Shield: ультралёгкий battery        │
│    ├── Clamp Hold: спокойствие после futility    │
│    ├── Персистентная память: EMA между ребутами  │
│    └── epoll: 0% CPU в DEEP_IDLE                 │
├──────────────────────────────────────────────────┤
│  sysfs / procfs / cpufreq / WALT / KGSL          │
└──────────────────────────────────────────────────┘
```

---

## 🧠 FSM — Конечный автомат из 6 состояний

| Состояние | Условие входа | CPU Caps (Balanced) | GPU | Опрос |
|:----------|:--------------|:-------------------:|:---:|:-----:|
| 🌙 `DEEP_IDLE` | Экран выключен | минимум | 0% | 10с |
| 💤 `LIGHT_IDLE` | Экран включён, мало активности | 1.19 / 1.88 ГГц | 15% | 2с |
| 📱 `MODERATE` | load ≥ 1.5 | динамически | 40% | 2с |
| ⚡ `HEAVY` | GPU ≥ 35% или load ≥ 2.0 | 2.4 / 3.3 ГГц | 65% | 2с |
| 🎮 `GAMING` | GPU ≥ 65% | 3.3 / 4.0 ГГц | 100% | 2с |
| 🛡️ `SUSTAINED` | temp ≥ 65°C или caps недостижимы | 80% диапазона | 80% | 2с |

**Переходы:** ⬆️ Вверх: 2 тика (4с) · ⬇️ Вниз: 5 тиков (10с) · 📴 Экран OFF → `DEEP_IDLE`: мгновенно

**`DEEP_IDLE`:** epoll блокирует = **0% CPU**, ~50КБ RAM.

---

## 🎯 Сравнение профилей — реальные цифры

| Параметр | 🔥 Performance | ⚖️ Balanced | 🔋 Battery |
|:---------|:--------------:|:-----------:|:----------:|
| CPU мин LITTLE | **2112 МГц** | 787 МГц | **384 МГц** |
| CPU мин BIG | **2438 МГц** | 883 МГц | **768 МГц** |
| CPU макс LITTLE | **3628 МГц** | 3302 МГц | **1325 МГц** |
| CPU макс BIG | **4608 МГц** | 3974 МГц | **1133 МГц** |
| GPU лимит | **100%** (1200 МГц) | 85% (1020 МГц) | **22%** (264 МГц) |
| RAVG окно | **2** (8мс) | 3 (12мс) | **8** (32мс) |
| Top-app вес | **170** | 110 | **65** |
| ED boost | **64** | 10 | **0** |
| uclamp FG | **60–100%** | 15–70% | **0–12%** |
| Бюджет Anti-Clamp | **6 окон** | 3 окна | **0 (выключен)** |
| Бюджет сенсоров | **120 чтений** | 60 чтений | **0** |
| Swappiness | **60** | 20 | **180** |
| Dirty writeback | **0.8с** | 4с | **180с** |
| WiFi PSM | **ВЫКЛ** | авто | **ВКЛ** |
| GAMING состояние | ✅ разрешено | ✅ разрешено | **🚫 заблокировано** |
| Быстрый deep idle | — | — | **15 секунд** |

---

## 🏗️ Session Plan — предвычисленная политика

Каждое событие (включение экрана, смена профиля, переход нагрузки) строит **компактный план из 12 полей**. Горячий путь просто читает готовое решение.

| Поле | Назначение |
|:-----|:-----------|
| `sensor_tier` | FULL / REDUCED / SPARSE опрос |
| `thermal_div` | Частота чтения температуры |
| `ac_eligible` | Anti-clamp вкл/выкл |
| `ac_budget` | Макс. окон anti-clamp за сессию |
| `deep_sleep` | Увеличенный интервал тиков |
| `plan_class` | Тип сессии (7 классов) |

**7 классов:** `IDLE_CLEAN` · `IDLE_NOISY` · `DAILY_ACTIVE` · `PERF_ACTIVE` · `PERF_CLAMPED` · `BENCHMARK` · `QUARANTINE`

---

## ⚔️ Система Anti-Clamp

На Snapdragon 8 Elite вендорный thermal stack часто зажимает частоты ниже запрошенных. ASB борется — но с бюджетом.

| Этап | Поведение | Длительность |
|:-----|:----------|:-------------|
| 🔍 Обнаружение | Dual-cluster мониторинг gap | Непрерывно |
| 💥 BURST | 3 агрессивные записи @ 2с | ~6с |
| ⏸️ HOLD | Проверка, застряли ли записи | 4с |
| 🔙 BACKOFF | Ожидание, наблюдение | 30с |
| 🛑 FUTILITY | 2+ backoff → прекратить борьбу | До конца сессии |

### Clamp-Stable Hold

После futility: `clamp_hold = 1` → gap-triggered SUSTAINED **заблокирован** → FSM перестаёт дёргаться.

| Метрика | До | После |
|:--------|:--:|:-----:|
| FSM переходов/мин | ~20 | **~0** |
| Бесполезные sysfs записи | сотни/сессию | **≈ 0** |
| Термальная безопасность | ✅ | ✅ (thermal entry сохранён) |

### Recovery Probe

- **Dual-cluster**: читает policy0 И policy6
- **Debounced**: нужны 2 подтверждения подряд
- **Economy**: после 10мин hold — probe каждые ~10мин вместо ~5мин
- **Защита от отрицательного gap**: транзиентный выброс → обнуляется

---

## 🌪️ Storm Shield — ультралёгкий battery

Когда battery screen-off сессия шумная (wake_cycles ≥ 5):

| Обычный | Storm Shield |
|:-------:|:------------:|
| Thermal каждый тик | Каждый 5-й (~50с) |
| Headroom ВКЛ | **ВЫКЛ** |
| Anti-clamp по профилю | **ВЫКЛ** |
| Самообучение активно | **ПРОПУСК** |
| Тики 5с | **10с** (глубокий сон) |

**Smart exit:** если шум утихает на ~10мин → shield снимается автоматически.
**Re-arm hysteresis:** повторное включение только при 3+ новых wake + 2мин cooldown.

---

## 📊 Сток vs ASB — реальные измерения

> Данные из реальных sysfs/procfs дампов OnePlus 15

### ⚡ Планировщик и CPU

| Метрика | Стоковый OxygenOS | ASB Balanced | Изменение |
|:--------|:-----------------:|:------------:|:---------:|
| `sched_util_clamp_min` | **1024** (всё на макс) | **0** (реальная утилизация) | −100% |
| CPU idle частота | **2362 МГц** | **998 МГц** | **−58%** |
| `dirty_expire` | 2с | 4с | **2× меньше I/O** |
| `swappiness` | 100 | 20 | **5× меньше swap** |
| `stat_interval` | 1с | 15с | **15× реже пробуждения** |
| Debug-сервисы | 35 запущено | **35 остановлено** | −100% |

### 🔋 Влияние на батарею

| Сценарий | Сток | ASB Balanced | ASB Battery |
|:---------|:----:|:------------:|:-----------:|
| Idle расход | ~55 мА/ч | ~32 мА/ч (**−40%**) | ~20 мА/ч (**−64%**) |
| Ночь 8ч | ~5–6% | ~3% (**−45%**) | ~1.5% (**−70%**) |
| Лёгкий SOT | базовый | **+15–20%** | **+30–40%** |

### 🌐 Сеть

| Параметр | Сток | ASB |
|:---------|:----:|:---:|
| TCP congestion | cubic | **BBR** |
| TCP fastopen | 1 | **3** (клиент+сервер) |
| `tcp_fin_timeout` | 60с | **20с** (3× быстрее) |
| `tcp_slow_start_after_idle` | 1 (сброс) | **0** (сохранять cwnd) |

---

## 🎵 Аудио-твики

| Область | Сток | ASB |
|:--------|:----:|:---:|
| Глубина наушников | 16/24-бит | **32-бит** |
| Обработка | PCM 32-бит | **PCM Float** |
| Макс. частота дискр. | 48 кГц | **192 кГц** |
| Цифровая громкость | 80–87/128 | **88/128** (+1–2 дБ) |
| DRC компрессор | ВКЛ | **ВЫКЛ** (чище звук) |
| Сложность кодека | 7–9/10 | **10/10** |
| BT A2DP макс | 96 кГц | **192 кГц** |
| LHDC качество | стандарт | **best** |
| LHDC версия | стандарт | **5** |
| Audio offload | частично | **полный** (AAC/ALAC/FLAC/Opus/WMA) |
| Абсолютная громкость | по устройству | **принудительно включена** |

---

## 📷 Камера-твики

| Функция | Сток | ASB |
|:--------|:----:|:---:|
| MFNR (многокадровое шумоподавление) | ограничено | **включено** |
| EIS (стабилизация) | стандарт | **включена** |
| SAT дистанция fallback | стоковая | **2.0м** |
| HFR-захват | стандарт | **включён** |
| Быстрый AF | стандарт | **включён** |

---

## 🔧 Твики ядра и системы

### Планировщик (WALT)

| Параметр | Что делает | Значение ASB |
|:---------|:-----------|:-------------|
| `sched_ravg_window` | Окно утилизации CPU | По профилю (8–32мс) |
| `sched_util_clamp_min` | Минимальный буст задач | **0** (убран принудительный буст) |
| `sched_idle_enough` | Порог определения idle | **45%** (+50% vs сток) |
| `sched_busy_hyst_ns` | Гистерезис занятости | **0** (перезаписывается каждый цикл) |
| `sched_schedstats` | Overhead статистики | **ВЫКЛ** |

### VM и память

| Параметр | Balanced | Battery | Performance |
|:---------|:--------:|:-------:|:-----------:|
| `swappiness` | 20 | 180 | 60 |
| `dirty_ratio` | 40% | 90% | 20% |
| `dirty_expire_centisecs` | 400 | 18000 | 80 |
| `vfs_cache_pressure` | 60 | 10 | 100 |
| `page-cluster` | 0 | 0 | 0 |
| `stat_interval` | 15 | 60 | 5 |
| `min_free_kbytes` | 32768 | 16384 | 65536 |

### Ввод-вывод

| Параметр | ASB |
|:---------|:----|
| Планировщик | `none` (прямая отправка) |
| `read_ahead_kb` | 128 |
| `iostats` | **ВЫКЛ** |
| `add_random` | **ВЫКЛ** |
| `rq_affinity` | 2 (привязка к CPU) |
| `nr_requests` | 64 |

### Сеть

| Параметр | ASB |
|:---------|:----|
| TCP congestion | **BBR** |
| Дисциплина очереди | **fq_codel** |
| TCP fastopen | **3** (полный) |
| `tcp_fin_timeout` | 20с |
| `tcp_notsent_lowat` | 128КБ |
| `rmem_max` / `wmem_max` | 16МБ |

---

## 📝 Снижение логирования

ASB останавливает **35+ отладочных/диагностических сервисов** при загрузке:

| Категория | Остановленные сервисы |
|:----------|:---------------------|
| Дампы крашей | `debuggerd`, `tombstoned`, `minidump`, `minidump32`, `minidump64` |
| Вендорная диагностика | `cnss_diag`, `qseelogd`, `tcpdump`, `charge_logger` |
| Телеметрия | `midasd`, `mqsasd`, `ostatsd`, `bootstat` |
| IMS отладка | Все IMS debug-пропсы отключены |
| Радио логи | `radio.adb_log_on=0`, `log_loc=0` |
| Ядро | `printk` = `0 0 0 0` |

**Результат:** меньше пробуждений CPU, меньше I/O, меньше расхода от фонового логирования.

---

## 👤 Карантин при смене пользователя

При переключении Android-пользователя (клон, гость): **90-секундный карантин** — anti-clamp ВЫКЛ, обучение ПРОПУСК, headroom ВЫКЛ. Шторм сервисов не заражает данные сессии.

---

## 🌡️ Thermal Debt

Если предыдущая perf-сессия закончилась горячей (≥75°C) и новая стартует менее чем через 2 минуты → `ac_budget` **урезается вдвое**. Модуль не летит сразу в ракету после горячей сессии.

---

## 📡 Определение возможностей устройства

Проверяется **один раз** при старте:

```
caps: msm=1 hr=1 thermal_cpu=1 thermal_skin=1 gpu=1 uclamp=0
```

Governor адаптируется к возможностям устройства — без жёстко зашитых предположений.

---

## 🩺 Диагностика

| Инструмент | Назначение |
|:-----------|:-----------|
| `asb_doctor.sh` | Проверка здоровья: HEALTHY / DEGRADED / UNHEALTHY / SOURCE_TREE |
| `session_history.jsonl` | Полная история сессий (последние 10, 30+ полей) |
| `pstats_*.json` | Персистентная память для каждого профиля |
| `asb_session_report.py` | Детальный markdown-отчёт с трендами |
| `asb_compare_sessions.py` | Сравнение сессий бок о бок |
| `asb_analyze.py` | Анализ лога governor'а |

---

## 🔧 Команды

```bash
asb status                            # JSON-статус
asb profile:performance               # переключить профиль
asb start-session:performance:auto    # профиль + режим + сброс
asb reload                            # перечитать конфиг
cat /dev/.asb/state                   # снимок состояния
tail -f /dev/.asb/governor.log        # живой лог
```

---

## 📱 Поддержка устройств

| Уровень | Устройства |
|:--------|:-----------|
| ✅ **Основное** | OnePlus 15 (CPH2745 / CPH2747) — полная настройка |
| ✅ Поддержка | OnePlus 13/13R/13s/13T, 12/12R, 11/11R, Open, Ace/Nord/Pad |

---

## 📦 Установка

1. Прошить через **KSU / KSUN / APatch / ReSuKiSu / Magisk**
2. Выбрать функции при установке (BT, Camera, CPU, VM, Net, WiFi, GPS, Kernel, Log)
3. Перезагрузка → governor стартует автоматически
4. Открыть **WebUI** → выбрать профиль
   
   <p align="center">
  <a href="https://github.com/krilikd/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C_%D0%BF%D0%BE%D1%81%D0%BB%D0%B5%D0%B4%D0%BD%D1%8E%D1%8E_%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8E-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Скачать последнюю версию">
  </a>
</p>

---

## ⭐ Поддержите проект

- ⭐ Поставьте звезду репозиторию
- 💬 [Telegram](https://t.me/DKomsomol)
- 🐛 Сообщайте об ошибках на GitHub

### 💖 Донат

Если ASB делает ваше устройство лучше, поддержите разработку:

<p align="center">
  <a href="https://paypal.me/lugaru46">
    <img src="https://img.shields.io/badge/PayPal-%D0%9F%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Поддержать через PayPal">
  </a>
</p>

---

## ⚠️ Дисклеймер

Модуль изменяет системное поведение. Используйте на свой страх и риск. Все твики **безопасны и обратимы** — удаление модуля восстанавливает стоковые настройки.

---

<p align="center"><i>Не магия — просто всё то, что сток оставляет на столе.</i></p>
