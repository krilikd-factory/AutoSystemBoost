<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">🚀 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Banner" width="100%">
</p>

<p align="center"><b>Adaptive Runtime Engine for OnePlus 15 • Snapdragon 8 Elite Gen 5</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Snapdragon_8_Elite-Gen_5-16a34a?style=for-the-badge" alt="SM8750">
  <img src="https://img.shields.io/badge/Root-Magisk_%7C_KernelSU-7c3aed?style=for-the-badge" alt="Root">
  <img src="https://img.shields.io/badge/Governor-Native_C-0ea5e9?style=for-the-badge" alt="C">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
</p>

---

## ✨ Not a Tweak Collection — a Runtime System

AutoSystemBoost is a **native C governor daemon** + shell orchestration + WebUI that makes real-time decisions about CPU, GPU, scheduler and thermal behavior every **2 seconds**.

```
┌──────────────────────────────────────────────────┐
│  WebUI — profile switch, live status             │
├──────────────────────────────────────────────────┤
│  action.sh → Unix socket → governor commands     │
├──────────────────────────────────────────────────┤
│  service.sh — boot orchestrator (1150 lines)     │
│  runtime/ — reconcile, watchdog, utils           │
├──────────────────────────────────────────────────┤
│  bin/asb — NATIVE C DAEMON (2766 lines)          │
│    ├── FSM: 6 states × 3 profiles                │
│    ├── Hysteresis: 2-tick up / 5-tick down       │
│    ├── Session telemetry: 25+ live metrics       │
│    ├── Persistent memory: EMA across reboots     │
│    ├── Learner: hourly usage pattern prediction  │
│    └── epoll: 0% CPU in DEEP_IDLE                │
├──────────────────────────────────────────────────┤
│  sysfs / procfs / cpufreq / WALT / KGSL          │
└──────────────────────────────────────────────────┘
```

---

## 🧠 FSM — 6-State Machine

| State | Entry Condition | CPU Caps (Balanced) | GPU | Polling |
|:------|:----------------|:-------------------:|:---:|:-------:|
| 🌙 `DEEP_IDLE` | Screen OFF | floor only | 0% | 5s |
| 💤 `LIGHT_IDLE` | Screen ON, low activity | 1.19 / 1.88 GHz | 15% | 2s |
| 📱 `MODERATE` | load ≥ 1.5 | dynamic | 40% | 2s |
| ⚡ `HEAVY` | GPU ≥ 35% or load ≥ 2.0 | 2.4 / 3.3 GHz | 65% | 2s |
| 🎮 `GAMING` | GPU ≥ 65% | 3.3 / 4.0 GHz | 100% | 2s |
| 🛡️ `SUSTAINED` | temp ≥ 65°C or caps unreachable | 80% range | 80% | 2s |

**Transitions:** ⬆️ Up: 2 ticks (4s) · ⬇️ Down: 5 ticks (10s) · 📴 Screen OFF → `DEEP_IDLE`: instant · 📱 Screen ON → `LIGHT_IDLE`: instant

**`DEEP_IDLE` power:** epoll blocks = **0% CPU**, ~50KB RSS. Wakes only on screen uevent or 5s thermal check.

---

## 🎯 Profile Comparison — Real Numbers

| Parameter | 🔥 Performance | ⚖️ Balanced | 🔋 Battery |
|:----------|:--------------:|:-----------:|:----------:|
| CPU min LITTLE | **2112 MHz** | 787 MHz | **384 MHz** |
| CPU min BIG | **2438 MHz** | 883 MHz | **768 MHz** |
| CPU max LITTLE | **3628 MHz** | 3302 MHz | **1325 MHz** |
| CPU max BIG | **4608 MHz** | 3974 MHz | **1133 MHz** |
| GPU cap | **100%** (1200 MHz) | 85% (1020 MHz) | **22%** (264 MHz) |
| RAVG window | **2** (8ms) | 3 (12ms) | **8** (32ms) |
| Top-app weight | **170** | 110 | **65** |
| ED boost | **64** | 10 | **0** |
| uclamp FG | **60–100%** | 15–70% | **0–12%** |
| Swappiness | **60** | 20 | **180** |
| Dirty writeback | **0.8s** | 4s | **180s** |
| WiFi PSM | **OFF** | auto | **ON** |
| GAMING state | ✅ allowed | ✅ allowed | **🚫 blocked** |
| Fast deep idle | — | — | **15 seconds** |

---

## 📊 Stock vs ASB — Verified Measurements

> Данные из реальных sysfs/procfs дампов OnePlus 15

### ⚡ Scheduler & CPU

| Metric | Stock OxygenOS | ASB Balanced |
|:-------|:--------------:|:------------:|
| `sched_util_clamp_min` | **1024** (all tasks forced max) | **0** (real utilization) |
| `sched_schedstats` | **1** (CPU overhead) | **0** |
| `sched_idle_enough` | **30** | **45** (+50%) |
| `sched_ravg_window` | **2** (8ms) | **3** (12ms, filtered spikes) |
| `sched_busy_hyst_ns` | 0 (HAL overrides to 99M) | **0** (re-applied every cycle) |
| CPU idle freq capture | **2362 MHz** | **998 MHz** (−58%) |
| `dirty_expire` | **2s** | **4s** (2× less I/O) |
| `swappiness` | **100** | **20** (5× less swap I/O) |
| `stat_interval` | **1s** | **15s** (15× fewer wakeups) |
| Debug services | 35 running | **35 stopped** |

### 🌡️ Thermal (idle, screen on)

| Zone | Stock | ASB Balanced | Delta |
|:-----|:-----:|:------------:|:-----:|
| CPU LITTLE | ~36.0°C | ~35.5°C | **−0.5°C** |
| CPU BIG | — | ~34.4°C | **below stock** |
| GPU | — | ~31.0°C | **very cool** |
| Battery | ~28.7°C | ~28.9°C | **≈ stock** |

### 🔋 Battery

| Scenario | Stock | ASB Balanced | ASB Battery |
|:---------|:-----:|:------------:|:-----------:|
| Idle drain | ~55 mAh/h | ~32 mAh/h (**−40%**) | ~20 mAh/h (**−64%**) |
| Night 8h | ~5–6% | ~3% (**−45%**) | ~1.5% (**−70%**) |
| Light SOT | baseline | **+15–20%** | **+30–40%** |
| Gaming SOT | baseline | **≈ stock** | N/A (blocked) |

### 🌐 Network

| Parameter | Stock | ASB |
|:----------|:-----:|:---:|
| TCP congestion | cubic | **BBR** |
| TCP fastopen | 1 | **3** (client+server) |
| `tcp_fin_timeout` | 60s | **20s** (3× faster) |
| `tcp_notsent_lowat` | 4 GB (off) | **128 KB** |
| `tcp_slow_start_after_idle` | 1 (reset) | **0** (keep cwnd) |

---

## 🛡️ Gap-Aware SUSTAINED

When vendor thermal stack cuts GAMING caps by > **1.5 GHz** for **8+ seconds**, governor enters `SUSTAINED` — achievable performance instead of fighting the thermal wall.

| Mode | Behavior | Best For |
|:-----|:---------|:---------|
| `burst` | Fast retry, `sustained_level=0.85` | Short benchmarks |
| `stable` | Slow retry, `sustained_level=0.78` | Long gaming |
| `auto` | Starts burst, degrades to stable when caps unreachable | **Recommended** |

Auto logs degradation with context: `auto: degraded burst->stable avg_gap=920k sus=5 gaming=1 sus_pct=72`

---

## 🔄 Persistent Feedback Loops

Governor reads session history at startup and adjusts behavior based on past patterns:

| Loop | Trigger | Action | Log |
|:-----|:--------|:-------|:----|
| 🔋 Battery idle #1 | `avg(bat_ttd)` > 60s | `bat_fast_idle_s` 15→10 | `feedback: avg_bat_ttd=72s >60s` |
| 🔋 Battery idle #2 | `avg(bat_ttd)` > 30s | `bat_fast_idle_s` 15→12 | `feedback: avg_bat_ttd=45s >30s` |
| 🔋 MODERATE domination | MODERATE > 60% of battery idle time | `bat_fast_idle_s` → 8 | `feedback: battery MODERATE=68%` |
| ⚡ Auto startup | >50% sessions degraded burst→stable | auto starts as stable | `feedback: 6/10 degraded` |

Safety: `bat_fast_idle_s` has a hard floor of **5 seconds** — feedback loops cannot push below this.

All adjustments are **explainable** — every change is logged with the exact numbers that triggered it.

---

## 📈 Session Telemetry (25+ metrics)

| Metric | Description |
|:-------|:------------|
| `ses_gaming` / `ses_sustained` | GAMING / SUSTAINED entry count |
| `ses_thermal` / `ses_unreachable` | SUSTAINED reason breakdown |
| `ses_t_heavy/gaming/sustained` | Seconds in each state |
| `ses_avg_gap_p0` / `ses_max_gap_p0` | Cap gap kHz (avg / peak) |
| `ses_max_temp` | Peak temperature °C |
| `ses_t2s` / `ses_t2thermal` | Time to first SUSTAINED / thermal |
| `ses_efficiency` | Quality score 0–100 |
| `ses_recovery` | Thermal collapse count |
| `bat_deep_idle` / `bat_light_idle` / `bat_moderate` | Seconds in each idle state (battery mode) |
| `bat_wake_cycles` | Wake-from-DEEP_IDLE count |
| `bat_screen_off` | Screen-off events in battery mode |
| `bat_ttd` | Time to first DEEP_IDLE entry (seconds) |
| `hist_*` | **Persistent cross-reboot averages** (EMA, 10 sessions) |

### 🧠 Cross-Session Memory

Two persistence layers, both survive reboots:

| File | Format | Purpose |
|:-----|:-------|:--------|
| `runtime/session_stats.json` | EMA averages | Rolling stats across last 10 sessions (t2s, temp, gap, efficiency, degrade count) |
| `runtime/session_history.jsonl` | JSON Lines (last 10) | Full session summaries with 20+ fields each — used by Python tools |

Stats saved on every **screen-off** event. Governor starts with knowledge from past sessions. Python report tool reads history to generate trend analysis and recommendations.

---

## 🎵 Audio

| Area | Stock | ASB |
|:-----|:-----:|:---:|
| Headphone depth | 16/24-bit | **32-bit** |
| Processing | PCM 32-bit | **PCM Float** |
| Max sample rate | 48 kHz | **192 kHz** |
| Digital volume | 80–87/128 | **88/128** (+1–2 dB) |
| DRC compressor | ON | **OFF** (cleaner) |
| Soft-clipper | ON | **OFF** |
| HPF / LPF | ON | **OFF** (full range) |
| Codec complexity | 7–9/10 | **10/10** |
| Bitrate | up to 960 kbps | **up to 18 Mbps** |
| BT A2DP | 44.1–96 kHz | **up to 192 kHz** |
| LHDC LL | not always | **enabled** |
| Audio offload | partial | **full** (AAC/ALAC/FLAC/Opus/WMA) |

## 📷 Camera

| Feature | Stock | ASB |
|:--------|:-----:|:---:|
| MFNR | limited | **enabled** |
| EIS | default | **enabled** |
| SAT fallback | stock | **2.0m** |
| HFR capture | default | **enabled** |
| Fast AF | default | **enabled** |

---

## 🔧 Commands

```bash
asb status                            # JSON status
asb profile:performance               # switch live
asb start-session:performance:auto    # atomic: profile + mode + reset
asb reload                            # re-read config
asb reset-stats                       # reset telemetry
cat /dev/.asb/state                   # state snapshot
tail -f /dev/.asb/governor.log        # live log

# Analysis (PC)
python3 tools/asb_analyze.py log.txt
python3 tools/asb_compare_sessions.py log1.txt log2.txt
python3 tools/asb_session_report.py session_history.jsonl -o report.md

# Session history (persists across reboots)
cat /data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl
cat /data/adb/modules/AutoSystemBoost/runtime/session_stats.json
```

---

## 📱 Device Support

| Tier | Devices |
|:-----|:--------|
| ✅ **Primary** | OnePlus 15 (CPH2745 / CPH2747) — fully tuned |
| ✅ Supported | OnePlus 13/13R/13s/13T, 12/12R, 11/11R, Open, Ace/Nord/Pad |

Non-OP15 devices receive script/prop tweaks; vendor overlays pruned automatically.

---

## 📦 Installation

1. Flash in **Magisk / KernelSU**
2. Select features (BT, Camera, CPU, VM, Net, WiFi, GPS, Kernel, Log)
3. Reboot → governor starts automatically
4. Open **WebUI** → choose profile

---

## ⭐ Support the Project

- ⭐ Star the repository
- 💬 [Telegram](https://t.me/DKomsomol)
- 🐛 Report issues on GitHub

---

## 🏁 Final Note

AutoSystemBoost is designed to make a rooted OnePlus device feel **deliberate**:

- faster when you want speed
- calmer when you want efficiency
- smarter about high-load sessions
- better audio and camera without additional apps

---

## ⚠️ Disclaimer

This module modifies system behavior. Use at your own risk. All tweaks are **safe and reversible** — uninstalling restores stock.

---

<p align="center"><i>Not magic — just everything stock leaves on the table.</i></p>
