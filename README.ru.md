<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-1f2937?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-16a34a?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">🛸 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Banner" width="80%">
</p>

<p align="center"><b>Адаптивный runtime-движок для OnePlus — Snapdragon 8 Elite / Gen 3</b></p>
<p align="center"><i>Reference-тюнинг на 15 · 13 · 12 — device-native на любом другом OnePlus</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus_15-SM8850-dc2626?style=for-the-badge" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus_13-SM8750-ea580c?style=for-the-badge" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus_12-SM8650-f59e0b?style=for-the-badge" alt="OP12">
  <br>
  <img src="https://img.shields.io/badge/Ace_6-ktm_·_boots_✓-22c55e?style=flat-square" alt="Ace 6">
  <img src="https://img.shields.io/badge/Ace_5-boots_✓-22c55e?style=flat-square" alt="Ace 5">
  <img src="https://img.shields.io/badge/any_OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
  <br>
  <img src="https://img.shields.io/badge/Root-KSU_%7C_KSUN_%7C_APATCH_%7C_RESUKISU_%7C_MAGISK-16a34a?style=for-the-badge" alt="Root">
  <img src="https://img.shields.io/badge/Governor-Native_C-0ea5e9?style=for-the-badge" alt="C">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
</p>

<p align="center">
  <img src="https://img.shields.io/github/downloads/krilikd/AutoSystemBoost/total?style=for-the-badge&color=0969da&label=%D0%A1%D0%BA%D0%B0%D1%87%D0%B8%D0%B2%D0%B0%D0%BD%D0%B8%D0%B9&logo=github" alt="Downloads">
  <img src="https://img.shields.io/github/v/release/krilikd/AutoSystemBoost?style=for-the-badge&color=16a34a&label=%D0%92%D0%B5%D1%80%D1%81%D0%B8%D1%8F" alt="Release">
  <img src="https://img.shields.io/github/stars/krilikd/AutoSystemBoost?style=for-the-badge&color=f59e0b&label=Stars&logo=github" alt="Stars">
</p>

---

<h2 align="center">✨ Не набор твиков — а полноценная runtime-система</h2>

<p align="center"><i>Нативный C-демон, который каждые 2 секунды считывает состояние устройства<br>и принимает решения о поведении CPU, GPU, термалов и планировщика в реальном времени.</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/5600+_lines-Native_C-0ea5e9?style=flat-square" alt="C">
  <img src="https://img.shields.io/badge/6_states-FSM-7c3aed?style=flat-square" alt="FSM">
  <img src="https://img.shields.io/badge/4_profiles-Adaptive-16a34a?style=flat-square" alt="Profiles">
  <img src="https://img.shields.io/badge/Smart_Mode-Self--checking-a78bfa?style=flat-square" alt="Smart Mode">
  <img src="https://img.shields.io/badge/12_fields-Session_Plan-e85d04?style=flat-square" alt="Plan">
  <img src="https://img.shields.io/badge/0%25_CPU-DEEP__IDLE-1f2937?style=flat-square" alt="Idle">
</p>

<table align="center">
<tr><td>

| | Layer | Component | Details |
|:---:|:-----:|:----------|:--------|
| 🖥️ | **UI** | WebUI | Переключение профилей, статус, инфо |
| ⚡ | **API** | Socket | `action.sh` → Unix-сокет → команды governor |
| 🔧 | **Shell** | Оркестратор | `service.sh` — загрузка, reconcile, watchdog |
| 🧠 | **Core** | C-демон | `bin/asb` — FSM, Session Plan, Anti-Clamp, Storm Shield |
| 📡 | **HW** | Ядро | sysfs · procfs · cpufreq · WALT · KGSL |

</td></tr>
</table>

<p align="center">
  <code>FSM</code> · <code>Smart Mode</code> · <code>Session Plan</code> · <code>Anti-Clamp</code> · <code>Storm Shield</code> · <code>Clamp Hold</code> · <code>BG_TRIM</code> · <code>Memcg v2</code>
</p>

---

## 📱 Поддержка устройств

Любой OnePlus получает **device-native** установку: ASB не поставляет **ни одного
статического vendor-файла**. При установке он клонирует **собственные** стоковые
файлы устройства, патчит копии и монтирует их обратно. Файлы чужой модели никогда
не попадают на ваш телефон.

| Уровень | Устройства | SoC | Кодовое имя |
|:--------|:-----------|:----|:------------|
| 🥇 **Reference — выверено вручную** | OnePlus 15 (CPH2745 / CPH2747) | Snapdragon 8 Elite Gen 5 (SM8850) | `canoe` |
| 🥇 **Reference — выверено вручную** | OnePlus 13 (CPH2649 / 2653 / 2655) | Snapdragon 8 Elite (SM8750) | `sun` · `tuna` · `kera` |
| 🥇 **Reference — выверено вручную** | OnePlus 12 (CPH2581 / 2583 / 2573) | Snapdragon 8 Gen 3 (SM8650) | `pineapple` |
| ✅ **Device-native — загрузка проверена** | OnePlus Ace 6 (PLQ110 / OP6113) | SM8750 — *общая прошивка `sun`* | `ktm` |
| ✅ **Device-native — загрузка проверена** | OnePlus Ace 5 (CPH2691) | Snapdragon 8-серии | — |
| ✅ **Device-native** | OnePlus 15R, 13R / 13s / 13T, 12R, 11 / 11R, Open, Ace 6T, Ace / Nord / Pad | разные | — |

### Два пути, одна философия

**Reference-устройства** (определяются по подтверждённому кодовому имени) получают
полный clone-and-patch пайплайн — собственное сопоставление топологии CPU/GPU,
аудио-SKU, оверлеи камеры/медиа и термопрофиль, проверенные на реальном железе, а
не в симуляции — под защитой **3-strike boot guard**.

**Все остальные OnePlus** получают тот же device-native `/vendor`-оверлей, а их
`/odm` аудио и медиа доставляются через **runtime `mount --bind`** (клон в
`/data/adb/asb/odm_patched/`, патч, SELinux-контекст снимается с живой цели,
применение в `post-fs-data` до зигота). Сам раздел `/odm` никогда не изменяется, и
поверх него никогда не графтится каталог. Всё это работает под **1-strike boot
fuse**: одна неудачная загрузка вырезает сгенерированный оверлей *до* монтирования
модуля, и устройство поднимается в режиме governor-only.

> **Родственные прошивки обрабатываются явно.** Ace 6 (`ktm`) работает на **той же**
> SM8750-прошивке `sun`, что и OnePlus 13 — в его fingerprint буквально написано
> `sun`. ASB проверяет `ktm` / `plq110` / `op6113` **до** проверки на `sun`, поэтому
> перепутать его с OP13 невозможно. Тот же предохранитель не пускает
> `macan` / `fairlady` / `15R` / `Ace 6T` в ветку OP15.

---

## 📦 Установка

1. Прошить через **KSU / KSUN / APatch / ReSuKiSu / Magisk**
2. Выбрать функции при установке — **15 категорий** (сохраняются между обновлениями):
   - **Включены по умолчанию**: AUDIO, BT, CAMERA, CPU, VM, NET, WIFI, GPS, KERNEL, LOG, RADIO/IMS, DISPLAY, FPS, SECURITY
   - **Опционально**: BG_TRIM (Smart Reclaim + телеметрия OPPO)
3. Перезагрузка → governor стартует автоматически
4. Открыть **WebUI** → выбрать профиль, либо тапнуть **Action** в списке модулей для статуса

   <p align="center">
  <a href="https://github.com/krilikd/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C_%D0%BF%D0%BE%D1%81%D0%BB%D0%B5%D0%B4%D0%BD%D1%8E%D1%8E_%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8E-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Скачать последнюю версию">
  </a>
</p>

---

## 🧠 FSM — Конечный автомат из 6 состояний

| Состояние | Условие входа | CPU Caps (Balanced) | GPU | Опрос |
|:----------|:--------------|:-------------------:|:---:|:-----:|
| 🌙 `DEEP_IDLE` | Экран выключен | минимум | 0% | 10с |
| 💤 `LIGHT_IDLE` | Экран включён, мало активности | 1.19 / 1.88 ГГц | 15% | 2с |
| 📱 `MODERATE` | load ≥ 1.5 | динамически | 40% | 2с |
| ⚡ `HEAVY` | GPU ≥ 35% или load ≥ 2.0 | 2.4 / 3.3 ГГц | 65% | 2с |
| 🎮 `GAMING` | GPU ≥ 65% | 3.3 / 4.0 ГГц | 100% | 2с |
| 🛡️ `SUSTAINED` | temp ≥ 59°C (perf) или caps недостижимы | 70% диапазона | 80% | 2с |

**Переходы:** ⬆️ Вверх: 2 тика (4с) · ⬇️ Вниз: 5 тиков (10с) · 📴 Экран OFF → `DEEP_IDLE`: мгновенно

**Выходы из `SUSTAINED`:**
- 🌡️ Температура упала ниже exit-порога (56°C perf, 49°C balanced) → обычный выход
- ⏱️ **Time-based escape**: После ≥ 180с в SUSTAINED при temp ≤ `enter − 3` и плоском/падающем тренде → принудительный выход

**`DEEP_IDLE`:** epoll блокирует = **0% CPU**, ~50 КБ RAM.

---

## 🧊 Ключевые thermal-решения

<table align="center">
<tr>
  <td align="center">🌡️<br><b>Корректность<br>привязки</b></td>
  <td>CPU-сенсор <b>валидируется один раз и сохраняется</b> через rescan'ы. Если primary-сенсор уходит в мусор на рантайме, governor <b>принудительно перепривязывается</b> на fallback — не per-tick workaround, а реальное binding change. Больше никаких сессий на мёртвом датчике.</td>
</tr>
<tr>
  <td align="center">⚡<br><b>Cross-validated<br>spike guard</b></td>
  <td>One-tick скачки сенсора на +25 °C <b>перекрёстно проверяются</b> против fallback. Физически невозможные спайки (93 °C когда соседи показывают 54 °C) <b>отклоняются</b>; реальный быстрый нагрев проходит, потому что оба сенсора растут вместе.</td>
</tr>
<tr>
  <td align="center">⏱️<br><b>Time-based<br>SUSTAINED escape</b></td>
  <td>Если устройство в <code>SUSTAINED</code> уже ≥ 180 с при температуре ниже <code>enter − 3 °C</code> и плоском/падающем тренде, FSM <b>ломает lock</b> и позволяет caps вернуться к нормальным значениям. Предотвращает 15-минутные застревания на steady-state игровых сессиях.</td>
</tr>
<tr>
  <td align="center">🔌<br><b>Защита<br>от cap desync</b></td>
  <td>Shell-слой screen-aware cap reconcile <b>соблюдает профиль</b> — больше никаких молчаливых hardcoded-overrides thermal-решений governor'а. Верифицируется в каждом запуске через <code>cap_verify.txt</code> в logkit.</td>
</tr>
<tr>
  <td align="center">📦<br><b>Scenario-scoped<br>logkit</b></td>
  <td>Три встроенных скрипта сбора для сценариев сон / дневное / игры. Pre-извлекает события, которые действительно важны (SUSTAINED переходы, смена thermal source, TRUST gates, cap verification) — post-mortem анализ в одно <code>grep</code>.</td>
</tr>
</table>

---

## 🎯 Сравнение профилей — реальные цифры

| Параметр | 🔥 Performance | ⚖️ Balanced | 🔋 Battery |
|:---------|:--------------:|:-----------:|:----------:|
| CPU мин LITTLE | **1190 МГц** | 787 МГц | **307 МГц** |
| CPU мин BIG | **1114 МГц** | 883 МГц | **614 МГц** |
| CPU макс LITTLE | **2957 МГц** | 3302 МГц | **1805 МГц** |
| CPU макс BIG | **3302 МГц** | 3974 МГц | **2208 МГц** |
| CPU cap LITTLE | **2304 МГц** | 1190 МГц | **922 МГц** |
| CPU cap BIG | **2611 МГц** | 1882 МГц | **922 МГц** |
| GPU лимит | **70%** | 85% | **50%** |
| GPU мин floor | **8%** | 0% | **0%** |
| RAVG окно | **2** (8 мс) | 3 (12 мс) | **8** (32 мс) |
| UCL_TOP макс | **90%** | 85% | **50%** |
| UCL_BG макс | **60%** | 35% | **40%** |
| Swappiness | **12** | 35 | **100** |
| Dirty writeback | **0.8 с** | 4 с | **240 с** |
| VFS cache pressure | **30** | 80 | **400** |
| Stat interval | **8 с** | 30 с | **240 с** |
| Min free KB | **32768** | 32768 | **114688** |
| Compaction proactive | **0** | 10 | **20** |
| WiFi power-save | **ВЫКЛ** | авто | **ВКЛ** |
| GAMING состояние | ✅ разрешено | ✅ разрешено | **🚫 заблокировано** |
| SUSTAINED вход / выход | **59 / 56 °C** | 57 / 49 °C | — |
| Time-based escape | **≥ 180 с** | — | — |
| Быстрый deep idle | — | — | **8 секунд** |

> **Smart** профиль (4-й, адаптивный) — описан в секции ниже. В этой статической таблице его нет, потому что его caps не фиксированы: они **смешиваются в рантайме** между envelope'ами **battery** и **balanced** на основе обучения по времени суток. Никогда не превышает sustained-envelope **balanced** и не опускается ниже safety-floor **battery**.

---

## 🧠 Smart Mode — адаптивный четвёртый профиль

Smart Mode — это **не новый набор frequency caps**. Это *слой смешивания* поверх уже существующих envelope'ов **battery** и **balanced**, который выбирает какую долю каждого применить в текущем контексте. FSM не меняется — Smart Mode просто подменяет bounds, которые читает FSM.

### 12 buckets по времени суток

```
            Будни   Выходные
SLEEP  (00-06)   #0       #1
WAKE   (06-09)   #2       #3
MORN   (09-12)   #4       #5
DAY    (12-17)   #6       #7
EVE    (17-21)   #8       #9
LATE   (21-24)   #10      #11
```

Каждый bucket хранит **веса смешивания, а не сырые частоты**:

| Вес | Диапазон | Что делает |
|:----|:--------:|:-----------|
| `alpha_battery` | 0.00–1.00 | 0 = чистый balanced, 1 = чистый battery |
| `interactive_bonus` | 0.00–0.15 | Лёгкий буст отзывчивости UI когда позволяет контекст |
| `idle_bias` | -0.20–+0.20 | Сделать idle-пороги жёстче или мягче |
| `sleep_bias` | 0.00–1.00 | Предпочитать deep-idle поведение в этом bucket'е |
| `net_conservative_bias` | 0.00–1.00 | Быть консервативнее с сетью в этом bucket'е |

Cold-start seed'ы совпадают с baseline-поведением, поэтому Smart Mode **не ощущается вялым в первый день** — днём он работает как **balanced**, ночью как **battery**, ещё до того как обучился.

### Чему Smart Mode учится из каждой сессии

Каждая завершённая сессия обновляет активный bucket. Направление выбирается по результату сессии:

| Результат сессии | Эффект на bucket |
|:-----------------|:-----------------|
| Жарко, большой drain, долгая sustained-нагрузка | `alpha_battery` ↑ (в сторону battery) |
| Прохладно, чисто, экран включён, интерактивно | `alpha_battery` ↓ (в сторону balanced) |
| Ночь, экран выключен, мало wake | `sleep_bias` ↑ и `net_conservative_bias` ↑ |
| Жаркая сессия со срабатываниями thermal veto | `interactive_bonus` ↓ |

Скорость обучения **зафиксирована на 5 % за сессию**, взвешенно по `duration × trust`:

| Сессия | вес длительности | вес доверия | фактический шаг |
|:-------|:----------------:|:-----------:|:---------------:|
| Длинная CLEAN (≥ 30 мин) | 1.00 | 1.00 | **5.00 %** |
| Средняя CLEAN | 0.50 | 1.00 | 2.50 % |
| Длинная PARTIAL | 1.00 | 0.40 | 2.00 % |
| Длинная NOISY | 1.00 | 0.15 | 0.75 % |
| Любая DIRTY | любой | **0.00** | **0 %** (игнорируется) |

Ни одно наблюдение не сдвинет bucket больше чем на 5 %.

### Самопроверка

Smart Mode не просто прогнозирует — он проверяет и корректирует себя:

| Возможность | Что делает |
|:------------|:-----------|
| **Цикл точности бюджета** | Оценивает собственный прогноз батареи против реального расхода (`budget_accuracy_score` 0–100), и при односторонней ошибке 3 окна подряд подправляет drain-rate в пределах ±12 % — полностью паузится ночью, где сравнение бессмысленно |
| **Гигиена ночного обучения** | Отклоняет wake-сэмплы вне правдоподобного окна, чтобы одна странная ночь (дрёма, поездка) не сбила выученный график |
| **Честный вердикт качества** | Давление vendor-клампа называется главной причиной только когда явно доминирует — горячая игра под терморегуляцией больше не помечается ложно как «vendor war» |
| **Cool Gaming** *(опционально)* | Раньше включает предиктивный термонаклон в играх для более холодного профиля ценой пика fps — выключено по умолчанию |

### Confidence gate — привычка предлагает, математика решает

Влияние bucket'а зависит от количества **effective observations** и того как давно он использовался:

| Confidence | Эффект |
|:----------:|:-------|
| < 0.35 | bucket игнорируется, baseline 50/50 blend |
| 0.35 – 0.65 | мягкое смешивание (до 40 % силы bucket'а) |
| ≥ 0.65 | bucket ведёт, но **никогда не выше balanced envelope** |

Старые данные деградируют: полная сила первые 7 дней, линейный спуск до пола 30 % к 36 дню, ноль с 37-го дня. Bucket который ты перестал использовать будет вежливо забыт, а не заморозит телефон в устаревшем паттерне.

### Иерархический fallback — никогда не наказывает за отсутствие данных

Если в bucket'е "воскресный вечер" нет данных:

1. точный поиск `(EVE, weekend)`
2. fallback к `(EVE, *)` — попробовать будний вариант
3. fallback к **классу** (buckets evening-класса, усреднённые)
4. fallback к **глобальному** усреднению по всем заполненным buckets
5. fallback к **safe default** (baseline-поведение)

Cold-start всегда приземляется на что-то разумное.

### Safety overlays — всегда выше habit

Два жёстких override'а, которые никакое обучение не может обойти:

| Override | Когда триггерится | Что форсирует |
|:---------|:------------------|:--------------|
| 🌙 **Night-safe override** | экран выключен + поздний час + не на зарядке + батарея ≤ 60 % | `alpha_battery ≥ 0.70`, обнулить `interactive_bonus`, поднять `idle_bias` |
| 🌡 **Thermal veto** | CPU ≥ 65 °C ИЛИ высокая активность vendor clamp ИЛИ recovery активен | confidence × 0.3, force `alpha_battery ≥ 0.70`, обнулить `interactive_bonus` |

**Habit may suggest. Thermal reality decides.**

### Обратимость

Smart Mode полностью обратим — выключи его, и предыдущий manual профиль восстановится из `/data/adb/asb/smart_prev_profile`. Данные обучения buckets хранятся в `/data/adb/asb/buckets.bin` (+ автоматический `.bak`) и переживают переустановку модуля. Используй команду `reset` если нужен чистый старт.

```bash
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh status'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh enable'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh disable'
su -c 'sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh reset'
```

WebUI выводит Smart Mode-кнопку рядом с тремя классическими профилями с live-readout'ом текущего bucket'а, daypart'а, процента confidence, текущего `alpha_battery` и признака активности safety overlay.

---

## 📊 Измеренные показатели

<p align="center"><i>Каждая цифра ниже измерена на реальном железе — преимущественно OnePlus 15, с OnePlus 13 и 12 в тестовом парке — в многочасовых сессиях COD 144 fps, ночном сне и типичном дневном смешанном использовании. Никаких симуляций, никакого чистого бенча.</i></p>

<table align="center">
<tr><th colspan="2">🎮 Тяжёлые игры (COD 144 fps, длительная нагрузка)</th></tr>
<tr><td><b>Время в SUSTAINED</b></td><td align="center"><b>🟢 8.9 %</b> от сессии</td></tr>
<tr><td><b>Самый долгий SUSTAINED-лок</b></td><td align="center"><b>🟢 &lt; 2 мин</b> (FSM сам выходит)</td></tr>
<tr><td><b>CPU температура — средняя под нагрузкой</b></td><td align="center"><b>🟢 43.7 °C</b></td></tr>
<tr><td><b>CPU температура — максимум</b></td><td align="center"><b>🟢 76 °C</b></td></tr>
<tr><td><b>Surface hotspot — максимум</b></td><td align="center"><b>🟢 49 °C</b></td></tr>
<tr><td><b>Board температура — максимум</b></td><td align="center"><b>🟢 49 °C</b></td></tr>
<tr><td><b>Дрейф привязки термосенсора</b></td><td align="center"><b>🟢 0 событий</b></td></tr>
<tr><td><b>Невалидные/spike показания</b></td><td align="center"><b>🟢 0 тиков</b> (cross-validated guard)</td></tr>
</table>

<table align="center">
<tr><th colspan="2">🌙 Ночной сон на батарее</th></tr>
<tr><td><b>Классификация исхода</b></td><td align="center"><b>🟢 clean_night</b></td></tr>
<tr><td><b>Качество простоя (idle quality)</b></td><td align="center"><b>🟢 98 / 100</b></td></tr>
<tr><td><b>Паразитные пробуждения</b></td><td align="center"><b>🟢 0</b></td></tr>
<tr><td><b>Уровень доверия (bat trust)</b></td><td align="center"><b>🟢 CLEAN</b></td></tr>
<tr><td><b>Разряд за 7.5 ч</b></td><td align="center"><b>🟢 &lt; 4 %</b></td></tr>
</table>

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

На Snapdragon 8 Elite Gen 5 вендорный thermal stack часто зажимает частоты ниже запрошенных. ASB борется — но с бюджетом.

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

## 🧠 BG_TRIM — Smart Reclaim Engine (опционально)

При включении на установке BG_TRIM работает в фоне для снижения давления на память **без убийства приложений**. Селективно, по группам, с учётом foreground state.

### Стратегия standby buckets

| Группа приложений | Bucket | Trim Level | Memcg |
|:------------------|:------:|:----------:|:-----:|
| Лаунчер, клавиатура, телефон, камера, карты, SystemUI | (system) | **никогда** | `memory.low` (защита) |
| Мессенджеры (WhatsApp, Telegram, Signal, Viber, Messenger, Discord, Teams, WeChat) | **active** | **никогда** | `memory.low` (защита) |
| Галерея, фоторедакторы, музыкальные плееры | **working_set** | HIDDEN (только при экране off) | — |
| Тяжёлые соцсети/медиа (Facebook, Instagram, Snapchat, TikTok, Netflix) | **rare** | BACKGROUND | `memory.high` (soft throttle) |

### Чего BG_TRIM НЕ делает

- ❌ Не trim'ит foreground app (`dumpsys activity` top-app проверка)
- ❌ Не ставит `persist.sys.oplus.high_performance=1` (противоречит цели)
- ❌ Не трогает `memory.max` (убивает приложения)
- ❌ Не throttle'ит GMS / Play Store / Quick Search (свой scheduling)
- ❌ Не использует агрессивный `device_idle_constants` (задерживает уведомления)
- ❌ Не использует wildcard package matching (только явные списки)

### Тюнинг OxygenOS Athena

- `persist.sys.oplus.athena.reclaim_enable=1` — разрешить reclaim
- `persist.sys.oplus.athena.force_kill=0` — запретить kill процессов
- `persist.sys.oplus.athena.limit_count=120`
- DeepThinker остаётся включён (нужен для AI Suggestions виджета, 3D обоев)

### Отключение только телеметрии

Отключаются только **4 чистых analytics-аплоадера**: `com.oplus.midas`, `com.oplus.olc`, `com.oplus.crashbox`, `com.oplus.logkit`. Останавливаются 2 telemetry HAL сервиса: `cammidasservice-V1`, `olc2-V3`. **Никаких** ContentProvider'ов, **никакого** IPC framework, **никакой** кастомизации.

---

## 🔑 Авто-фикс Tencent Soter

WeChat, Alipay и ряд китайских банков используют биометрический протокол Tencent Soter. На OnePlus global ROM демон `vendor.soter` часто ведёт себя некорректно после загрузки — теряется отпечаток в этих приложениях.

ASB запускает автоматическое восстановление в фоне после `sys.boot_completed=1`:

```
stop vendor.soter
pm clear com.tencent.soter.soterserver
start vendor.soter
```

Повторяется в течение 5 минут. Пользователи без Tencent-приложений не затронуты — цикл становится no-op на устройствах без этих пакетов.

---

## 📊 Сток vs ASB — реальные измерения

> Данные из реальных sysfs/procfs дампов OnePlus 15 / 13 / 12

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
| `swappiness` | 35 | 100 | 12 |
| `dirty_expire_centisecs` | 6000 | 240000 | 1000 |
| `dirty_writeback_centisecs` | 4000 | 240000 | 800 |
| `vfs_cache_pressure` | 80 | 400 | 30 |
| `page-cluster` | 1 | 3 | 0 |
| `stat_interval` | 30 | 240 | 8 |
| `min_free_kbytes` | 32768 | 114688 | 32768 |
| `compaction_proactiveness` | 10 | 20 | 0 |
| `lru_gen` (если writable) | 7 | 7 | 7 |

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

Запускать с root (`su -c` из любого терминала — Termux, ADB shell, root file manager terminal):

```bash
su -c 'asb status'                          # JSON-статус
su -c 'asb profile:performance'             # переключить профиль вживую
su -c 'asb start-session:performance:auto'  # профиль + режим сессии + сброс
su -c 'asb reload'                          # перечитать конфиг
su -c 'cat /dev/.asb/state'                 # снимок состояния
su -c 'tail -f /dev/.asb/governor.log'      # живой лог
```

Бинарь `asb` доступен через `/system/bin/asb` (маленький wrapper, форвардящий в `/data/adb/modules/AutoSystemBoost/bin/asb`). Governor требует root, поэтому все команды `asb` нужно вызывать через `su`. Wrapper создаётся модулем автоматически — настройка PATH не нужна.

---

## 💾 Сохранение конфигурации

Ваши настройки переживают переустановки и обновления — ничего не сбрасывается при прошивке новой версии.

- **Переключатели и ползунки WebUI** (агрессивные аудио/камера-твики, Cool Gaming, Уклон Smart в автономность, трим фона, управление UX, …) хранятся в `config/governor.conf`. При каждой переустановке установщик переносит ваши сохранённые значения поверх свежих дефолтов, ключ за ключом — ваш выбор побеждает, а новые для версии ключи добавляются чисто.
- **Активный профиль** (`performance` / `balanced` / `battery` / `smart`) дублируется в `/data/adb/asb/active_profile`, **вне** директории модуля, и восстанавливается при загрузке.
- **Состояние Smart-режима и всё, что он выучил** — ваши бакеты по времени суток, история сессий, модель бюджета батареи — лежат в `/data/adb/asb/`, тоже вне модуля, поэтому обновление не заставляет Smart учиться с нуля.

Прошивайте обновление прямо поверх и перезагрузитесь — все настройки и выученные данные вернутся.

---

## 🎯 Кнопка Action — живой статус

Тапни **Action** в списке модулей (Magisk/KSU) — получишь моментальный отчёт:

```
  ASB · battery

  🌡  CPU      : 39°C
  🔋 Battery  : 31.5°C   78%

  Прогноз разряда до 0%:
    📱 экран вкл : ~9ч 22м
    💤 экран выкл: ~75ч 0м

  Открытие Telegram канала...
```

Температура CPU, батареи + уровень, прогноз времени работы (экран вкл/выкл, калиброванный под профиль). Затем автоматически открывается канал поддержки.

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
