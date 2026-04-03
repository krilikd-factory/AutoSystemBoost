<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">🚀 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Banner" width="80%">
</p>

<p align="center"><b>Adaptive Runtime Engine for OnePlus 15 • Snapdragon 8 Elite</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Snapdragon_8_Elite-Gen_5-dc2626?style=for-the-badge" alt="SM8850">
  <img src="https://img.shields.io/badge/Root-KSU_%7C_KSUN_%7C_APATCH_%7C_RESUKISU_%7C_MAGISK-16a34a?style=for-the-badge" alt="Root">
  <br>
  <img src="https://img.shields.io/badge/Governor-Native_C-0ea5e9?style=for-the-badge" alt="C">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
</p>

<p align="center">
  <img src="https://img.shields.io/github/downloads/krilikd/AutoSystemBoost/total?style=for-the-badge&color=0969da&label=Downloads&logo=github" alt="Downloads">
  <img src="https://img.shields.io/github/v/release/krilikd/AutoSystemBoost?style=for-the-badge&color=16a34a&label=Latest" alt="Release">
  <img src="https://img.shields.io/github/stars/krilikd/AutoSystemBoost?style=for-the-badge&color=f59e0b&label=Stars&logo=github" alt="Stars">
</p>

---

<h2 align="center">✨ Not a Tweak Collection — a Runtime System</h2>

<p align="center"><i>A native C daemon that reads the device every 2 seconds<br>and makes real-time decisions about CPU, GPU, thermals, and scheduler.</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/2744_lines-Native_C-0ea5e9?style=flat-square" alt="C">
  <img src="https://img.shields.io/badge/6_states-FSM-7c3aed?style=flat-square" alt="FSM">
  <img src="https://img.shields.io/badge/3_profiles-Adaptive-16a34a?style=flat-square" alt="Profiles">
  <img src="https://img.shields.io/badge/12_fields-Session_Plan-e85d04?style=flat-square" alt="Plan">
  <img src="https://img.shields.io/badge/0%25_CPU-DEEP__IDLE-1f2937?style=flat-square" alt="Idle">
</p>

<table align="center">
<tr><td>

| | Layer | Component | Details |
|:---:|:-----:|:----------|:--------|
| 🖥️ | **UI** | WebUI | Profile switch, live status, device info |
| ⚡ | **API** | Socket | `action.sh` → Unix socket → governor commands |
| 🔧 | **Shell** | Orchestrator | `service.sh` — boot config, reconcile, watchdog |
| 🧠 | **Core** | C Daemon | `bin/asb` — FSM, Session Plan, Anti-Clamp, Storm Shield |
| 📡 | **HW** | Kernel | sysfs · procfs · cpufreq · WALT · KGSL |

</td></tr>
</table>

<p align="center">
  <code>FSM</code> · <code>Session Plan</code> · <code>Anti-Clamp</code> · <code>Storm Shield</code> · <code>Clamp Hold</code> · <code>Thermal Debt</code> · <code>Quarantine</code>
</p>

---

## 🧠 FSM — 6-State Machine

| State | Entry Condition | CPU Caps (Balanced) | GPU | Polling |
|:------|:----------------|:-------------------:|:---:|:-------:|
| 🌙 `DEEP_IDLE` | Screen OFF | floor only | 0% | 10s |
| 💤 `LIGHT_IDLE` | Screen ON, low activity | 1.19 / 1.88 GHz | 15% | 2s |
| 📱 `MODERATE` | load ≥ 1.5 | dynamic | 40% | 2s |
| ⚡ `HEAVY` | GPU ≥ 35% or load ≥ 2.0 | 2.4 / 3.3 GHz | 65% | 2s |
| 🎮 `GAMING` | GPU ≥ 65% | 3.3 / 4.0 GHz | 100% | 2s |
| 🛡️ `SUSTAINED` | temp ≥ 65°C or caps unreachable | 80% range | 80% | 2s |

**Transitions:** ⬆️ Up: 2 ticks (4s) · ⬇️ Down: 5 ticks (10s) · 📴 Screen OFF → `DEEP_IDLE`: instant

**`DEEP_IDLE` power:** epoll blocks = **0% CPU**, ~50KB RSS.

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
| Anti-Clamp budget | **6 windows** | 3 windows | **0 (disabled)** |
| Sensor budget | **120 reads** | 60 reads | **0** |
| Swappiness | **60** | 20 | **180** |
| Dirty writeback | **0.8s** | 4s | **180s** |
| WiFi PSM | **OFF** | auto | **ON** |
| GAMING state | ✅ allowed | ✅ allowed | **🚫 blocked** |
| Fast deep idle | — | — | **15 seconds** |

---

## 🏗️ Session Plan — Pre-Computed Policy

Every event (screen toggle, profile change, band cross) builds a **12-field plan**. Hot path reads the answer instead of re-evaluating.

| Field | Purpose |
|:------|:--------|
| `sensor_tier` | FULL / REDUCED / SPARSE polling |
| `thermal_div` | Thermal read frequency |
| `ac_eligible` | Anti-clamp on/off |
| `ac_budget` | Max anti-clamp windows per session |
| `deep_sleep` | Extended tick interval |
| `plan_class` | Session type (7 classes) |

**7 Plan Classes:** `IDLE_CLEAN` · `IDLE_NOISY` · `DAILY_ACTIVE` · `PERF_ACTIVE` · `PERF_CLAMPED` · `BENCHMARK` · `QUARANTINE`

---

## ⚔️ Anti-Clamp System

On Snapdragon 8 Elite, the vendor thermal stack often clamps frequencies below requested caps. ASB fights back — with a budget.

| Stage | Behavior | Duration |
|:------|:---------|:---------|
| 🔍 Detection | Dual-cluster gap monitoring | Continuous |
| 💥 BURST | 3 aggressive dual-writes @ 2s | ~6s |
| ⏸️ HOLD | Verify if writes stuck | 4s |
| 🔙 BACKOFF | Wait, observe | 30s |
| 🛑 FUTILITY | 2+ backoffs → stop fighting | Session-long |

### Clamp-Stable Hold

After futility: `clamp_hold = 1` → gap-triggered SUSTAINED **blocked** → FSM stops jittering.

| Metric | Before | After |
|:-------|:------:|:-----:|
| FSM transitions/min | ~20 | **~0** |
| Useless sysfs writes | hundreds/session | **near zero** |
| Thermal safety | ✅ | ✅ (thermal entry preserved) |

### Recovery Probe

- **Dual-cluster**: reads policy0 AND policy6
- **Debounced**: 2 consecutive good probes required
- **Economy**: after 10min hold, probe every ~10min instead of ~5min
- **Negative gap protection**: transient overshoot → clamped to 0

---

## 🌪️ Storm Shield — Battery Ultra-Light

When battery screen-off session is noisy (wake_cycles ≥ 5):

| Normal | Storm Shield |
|:------:|:------------:|
| Thermal every tick | Every 5th tick (~50s) |
| Headroom ON | **OFF** |
| Anti-clamp per profile | **OFF** |
| Self-tune active | **SKIP** |
| 5s ticks | **10s** (deep sleep) |

**Smart exit:** if noise calms for ~10min → shield auto-exits.
**Re-arm hysteresis:** re-arm requires 3 new wakes + 2min cooldown.

---

## 📊 Stock vs ASB — Verified Measurements

> From real sysfs/procfs dumps on OnePlus 15

### ⚡ Scheduler & CPU

| Metric | Stock OxygenOS | ASB Balanced | Change |
|:-------|:--------------:|:------------:|:------:|
| `sched_util_clamp_min` | **1024** (all max) | **0** (real util) | −100% |
| CPU idle freq capture | **2362 MHz** | **998 MHz** | **−58%** |
| `dirty_expire` | 2s | 4s | **2× less I/O** |
| `swappiness` | 100 | 20 | **5× less swap** |
| `stat_interval` | 1s | 15s | **15× fewer wakeups** |
| Debug services | 35 running | **35 stopped** | −100% |

### 🔋 Battery Impact

| Scenario | Stock | ASB Balanced | ASB Battery |
|:---------|:-----:|:------------:|:-----------:|
| Idle drain | ~55 mAh/h | ~32 mAh/h (**−40%**) | ~20 mAh/h (**−64%**) |
| Night 8h | ~5–6% | ~3% (**−45%**) | ~1.5% (**−70%**) |
| Light SOT | baseline | **+15–20%** | **+30–40%** |

### 🌐 Network

| Parameter | Stock | ASB |
|:----------|:-----:|:---:|
| TCP congestion | cubic | **BBR** |
| TCP fastopen | 1 | **3** (client+server) |
| `tcp_fin_timeout` | 60s | **20s** (3× faster) |
| `tcp_slow_start_after_idle` | 1 (reset) | **0** (keep cwnd) |

---

## 🎵 Audio Tweaks

| Area | Stock | ASB |
|:-----|:-----:|:---:|
| Headphone bit depth | 16/24-bit | **32-bit** |
| Processing | PCM 32-bit | **PCM Float** |
| Max sample rate | 48 kHz | **192 kHz** |
| Digital volume | 80–87/128 | **88/128** (+1–2 dB) |
| DRC compressor | ON | **OFF** (cleaner) |
| Codec complexity | 7–9/10 | **10/10** |
| BT A2DP max | 96 kHz | **192 kHz** |
| LHDC quality | default | **best** |
| LHDC version | default | **5** |
| Audio offload | partial | **full** (AAC/ALAC/FLAC/Opus/WMA) |
| Absolute volume | per-device | **forced enable** |

---

## 📷 Camera Tweaks

| Feature | Stock | ASB |
|:--------|:-----:|:---:|
| MFNR (multi-frame noise reduction) | limited | **enabled** |
| EIS (stabilization) | default | **enabled** |
| SAT fallback distance | stock | **2.0m** |
| HFR capture | default | **enabled** |
| Fast AF | default | **enabled** |

---

## 🔧 Kernel & System Tweaks

### Scheduler (WALT)

| Parameter | What it does | ASB value |
|:----------|:-------------|:----------|
| `sched_ravg_window` | CPU utilization window | Profile-dependent (8–32ms) |
| `sched_util_clamp_min` | Minimum task boosting | **0** (remove forced boosting) |
| `sched_idle_enough` | Idle detection threshold | **45%** (+50% vs stock) |
| `sched_busy_hyst_ns` | Busy hysteresis | **0** (re-applied every cycle) |
| `sched_schedstats` | Scheduler statistics overhead | **OFF** |

### VM & Memory

| Parameter | Balanced | Battery | Performance |
|:----------|:--------:|:-------:|:-----------:|
| `swappiness` | 20 | 180 | 60 |
| `dirty_ratio` | 40% | 90% | 20% |
| `dirty_expire_centisecs` | 400 | 18000 | 80 |
| `vfs_cache_pressure` | 60 | 10 | 100 |
| `page-cluster` | 0 | 0 | 0 |
| `stat_interval` | 15 | 60 | 5 |
| `min_free_kbytes` | 32768 | 16384 | 65536 |

### I/O

| Parameter | ASB |
|:----------|:----|
| Scheduler | `none` (direct dispatch) |
| `read_ahead_kb` | 128 |
| `iostats` | **OFF** |
| `add_random` | **OFF** |
| `rq_affinity` | 2 (strict CPU) |
| `nr_requests` | 64 |

### Network

| Parameter | ASB |
|:----------|:----|
| TCP congestion | **BBR** |
| Queue discipline | **fq_codel** |
| TCP fastopen | **3** (full) |
| `tcp_fin_timeout` | 20s |
| `tcp_notsent_lowat` | 128KB |
| `rmem_max` / `wmem_max` | 16MB |

---

## 📝 Log Reduction

ASB stops **35+ debug/diagnostic services** at boot:

| Category | Services stopped |
|:---------|:----------------|
| Crash dumps | `debuggerd`, `tombstoned`, `minidump`, `minidump32`, `minidump64` |
| Vendor diag | `cnss_diag`, `qseelogd`, `tcpdump`, `charge_logger` |
| Telemetry | `midasd`, `mqsasd`, `ostatsd`, `bootstat` |
| IMS debug | All IMS debug/log props disabled |
| Radio logs | `radio.adb_log_on=0`, `log_loc=0` |
| Kernel | `printk` set to `0 0 0 0` |

**Result:** less CPU wakeups, less I/O, less battery drain from background logging.

---

## 👤 User-Switch Quarantine

When Android user changes (clone, guest): **90s quarantine** — anti-clamp OFF, learning SKIP, headroom OFF. Prevents user-switch storm from contaminating session data.

---

## 🌡️ Thermal Debt

If previous perf session ended hot (≥75°C) and new one starts within 120s → `ac_budget` **halved**. No immediate re-launch into thermal wall.

---

## 📡 Device Capability Detection

Probed **once** at startup:

```
caps: msm=1 hr=1 thermal_cpu=1 thermal_skin=1 gpu=1 uclamp=0
```

Governor adapts to device capabilities — no hardcoded assumptions.

---

## 🩺 Diagnostics

| Tool | Purpose |
|:-----|:--------|
| `asb_doctor.sh` | Health check: HEALTHY / DEGRADED / UNHEALTHY / SOURCE_TREE |
| `session_history.jsonl` | Full session history (last 10, 30+ fields each) |
| `pstats_*.json` | Persistent memory per profile |
| `asb_session_report.py` | Detailed markdown report with trends |
| `asb_compare_sessions.py` | Side-by-side session comparison |
| `asb_analyze.py` | Governor log analysis |

---

## 🔧 Commands

```bash
asb status                            # JSON status
asb profile:performance               # switch live
asb start-session:performance:auto    # profile + mode + reset
asb reload                            # re-read config
cat /dev/.asb/state                   # state snapshot
tail -f /dev/.asb/governor.log        # live log
```

---

## 📱 Device Support

| Tier | Devices |
|:-----|:--------|
| ✅ **Primary** | OnePlus 15 (CPH2745 / CPH2747) — fully tuned |
| ✅ Supported | OnePlus 13/13R/13s/13T, 12/12R, 11/11R, Open, Ace/Nord/Pad |

---

## 📦 Installation

1. Flash in **KSU / KSUN / APatch / ReSuKiSu / Magisk**
2. Select features at install (BT, Camera, CPU, VM, Net, WiFi, GPS, Kernel, Log)
3. Reboot → governor starts automatically
4. Open **WebUI** → choose profile

   <p align="center">
  <a href="https://github.com/krilikd/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_Download_Latest_Release-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Download Latest Release">
  </a>
</p>

---

## ⭐ Support the Project

- ⭐ Star the repository
- 💬 [Telegram](https://t.me/DKomsomol)
- 🐛 Report issues on GitHub

### 💖 Donate

If ASB makes your device better, consider supporting development:

<p align="center">
  <a href="https://paypal.me/lugaru46">
    <img src="https://img.shields.io/badge/PayPal-Donate-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate via PayPal">
  </a>
</p>

---

## ⚠️ Disclaimer

This module modifies system behavior. Use at your own risk. All tweaks are **safe and reversible** — uninstalling restores stock.

---

<p align="center"><i>Not magic — just everything stock leaves on the table.</i></p>
