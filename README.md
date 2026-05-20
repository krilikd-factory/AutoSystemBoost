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

## 📊 Measured Performance

<p align="center"><i>Every number below was measured on a real OnePlus 15 — multi-hour COD 144 fps sessions, overnight sleep, typical mixed daytime use. No simulations, no bench-only data.</i></p>

<table align="center">
<tr><th colspan="2">🎮 Heavy Gaming (COD 144 fps, sustained load)</th></tr>
<tr><td><b>Time spent in SUSTAINED</b></td><td align="center"><b>🟢 8.9 %</b> of session</td></tr>
<tr><td><b>Longest SUSTAINED lock</b></td><td align="center"><b>🟢 &lt; 2 min</b> (FSM self-escapes)</td></tr>
<tr><td><b>CPU temp — average under load</b></td><td align="center"><b>🟢 43.7 °C</b></td></tr>
<tr><td><b>CPU temp — max observed</b></td><td align="center"><b>🟢 76 °C</b></td></tr>
<tr><td><b>Surface hotspot — max</b></td><td align="center"><b>🟢 49 °C</b></td></tr>
<tr><td><b>Board temp — max</b></td><td align="center"><b>🟢 49 °C</b></td></tr>
<tr><td><b>Thermal sensor binding drift</b></td><td align="center"><b>🟢 0 events</b></td></tr>
<tr><td><b>Invalid/spike sensor reads</b></td><td align="center"><b>🟢 0 ticks</b> (cross-validated guard)</td></tr>
</table>

<table align="center">
<tr><th colspan="2">🌙 Overnight Battery Sleep</th></tr>
<tr><td><b>Outcome classification</b></td><td align="center"><b>🟢 clean_night</b></td></tr>
<tr><td><b>Idle quality score</b></td><td align="center"><b>🟢 98 / 100</b></td></tr>
<tr><td><b>Spurious wake events</b></td><td align="center"><b>🟢 0</b></td></tr>
<tr><td><b>Bat trust level</b></td><td align="center"><b>🟢 CLEAN</b></td></tr>
<tr><td><b>Drain over 7.5 h</b></td><td align="center"><b>🟢 &lt; 4 %</b></td></tr>
</table>

---

## 🧊 Thermal Engineering Highlights

<table align="center">
<tr>
  <td align="center">🌡️<br><b>Binding-Layer<br>Correctness</b></td>
  <td>CPU thermal source is <b>validated once and preserved</b> across rescans. If the primary sensor goes bad at runtime, the governor <b>permanently rebinds</b> to the fallback — not a per-tick workaround. No more stuck-on-dead-sensor sessions.</td>
</tr>
<tr>
  <td align="center">⚡<br><b>Cross-Validated<br>Spike Guard</b></td>
  <td>Single-tick sensor jumps of +25 °C are cross-checked against the fallback sensor. Physically impossible spikes (93 °C while neighbors sit at 54 °C) are <b>rejected</b>; legitimate fast heating passes because both sensors rise together.</td>
</tr>
<tr>
  <td align="center">⏱️<br><b>Time-Based<br>SUSTAINED Escape</b></td>
  <td>If device has been in <code>SUSTAINED</code> for ≥ 180 s with temp below <code>enter−3 °C</code> and trend flat/falling, FSM <b>breaks the lock</b> and allows caps to return to normal. Prevents 15-minute stuck states observed on steady-state gaming sessions.</td>
</tr>
<tr>
  <td align="center">🔌<br><b>Cap Desync<br>Protection</b></td>
  <td>Shell-layer screen-aware cap reconcile <b>honors the profile</b> — no more silent hardcoded overrides of the governor's thermal decisions. Verified every run via <code>cap_verify.txt</code> in the logkit.</td>
</tr>
<tr>
  <td align="center">📦<br><b>Scenario-Scoped<br>Logkit</b></td>
  <td>Three built-in collection scripts for sleep / mixed / gaming scenarios. Pre-extracts events that matter (SUSTAINED transitions, thermal source changes, TRUST gates, cap verification) so post-mortem analysis is one <code>grep</code> away.</td>
</tr>
</table>

---

## 🧠 FSM — 6-State Machine

| State | Entry Condition | CPU Caps (Balanced) | GPU | Polling |
|:------|:----------------|:-------------------:|:---:|:-------:|
| 🌙 `DEEP_IDLE` | Screen OFF | floor only | 0% | 10s |
| 💤 `LIGHT_IDLE` | Screen ON, low activity | 1.19 / 1.88 GHz | 15% | 2s |
| 📱 `MODERATE` | load ≥ 1.5 | dynamic | 40% | 2s |
| ⚡ `HEAVY` | GPU ≥ 35% or load ≥ 2.0 | 2.4 / 3.3 GHz | 65% | 2s |
| 🎮 `GAMING` | GPU ≥ 65% | 3.3 / 4.0 GHz | 100% | 2s |
| 🛡️ `SUSTAINED` | temp ≥ 59°C (perf) or caps unreachable | 70% range | 80% | 2s |

**Transitions:** ⬆️ Up: 2 ticks (4s) · ⬇️ Down: 5 ticks (10s) · 📴 Screen OFF → `DEEP_IDLE`: instant

**`SUSTAINED` escape paths:**
- 🌡️ Temp drops below exit threshold (56°C for perf, 49°C for balanced) → normal exit
- ⏱️ **Time-based escape**: After ≥ 180s in SUSTAINED with temp ≤ `enter − 3` and flat/falling trend → forced exit

**`DEEP_IDLE` power:** epoll blocks = **0% CPU**, ~50 KB RSS.

---

## 🎯 Profile Comparison — Real Numbers

| Parameter | 🔥 Performance | ⚖️ Balanced | 🔋 Battery |
|:----------|:--------------:|:-----------:|:----------:|
| CPU min LITTLE | **1190 MHz** | 787 MHz | **307 MHz** |
| CPU min BIG | **1114 MHz** | 883 MHz | **614 MHz** |
| CPU max LITTLE | **3629 MHz** | 3302 MHz | **1133 MHz** |
| CPU max BIG | **4608 MHz** | 3974 MHz | **998 MHz** |
| CPU cap LITTLE | **3072 MHz** | 1190 MHz | **614 MHz** |
| CPU cap BIG | **2976 MHz** | 1882 MHz | **922 MHz** |
| GPU cap | **84%** (≈1008 MHz) | 85% (1020 MHz) | **15%** (≈180 MHz) |
| RAVG window | **2** (8 ms) | 3 (12 ms) | **10** (40 ms) |
| Top-app weight | **150** | 110 | **40** |
| ED boost | **30** | 10 | **0** |
| UCL FG | **60–96%** | 15–70% | **0–8%** |
| UCL Top | **88–100%** | 40–100% | **0–10%** |
| Swappiness | **12** | 35 | **200** |
| Dirty writeback | **0.8 s** | 4 s | **240 s** |
| WiFi PSM | **OFF** | auto | **ON** |
| Sched rate (µs) | **800** | 2500 | **16000** |
| GAMING state | ✅ allowed | ✅ allowed | **🚫 blocked** |
| SUSTAINED enter / exit | **59 / 56 °C** | 57 / 49 °C | — |
| Time-based escape | **≥ 180 s** | — | — |
| Fast deep idle | — | — | **8 seconds** |

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

On Snapdragon 8 Elite Gen 5, the vendor thermal stack often clamps frequencies below requested caps. ASB fights back — with a budget.

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

## 🧠 BG_TRIM — Smart Reclaim Engine (opt-in)

When enabled at install, BG_TRIM runs in the background to reduce memory pressure **without killing apps**. Selective, app-aware, and respects foreground state.

### Standby Bucket Strategy

| App Group | Bucket | Trim Level | Memcg |
|:----------|:------:|:----------:|:-----:|
| Launcher, keyboard, dialer, camera, maps, SystemUI | (system) | **never** | `memory.low` (protect) |
| Messengers (WhatsApp, Telegram, Signal, Viber, Messenger, Discord, Teams, WeChat) | **active** | **never** | `memory.low` (protect) |
| Gallery, photo editors, music players | **working_set** | HIDDEN (screen-off only) | — |
| Heavy social/media (Facebook, Instagram, Snapchat, TikTok, Netflix) | **rare** | BACKGROUND | `memory.high` (soft throttle) |

### What BG_TRIM Does Not Do

- ❌ Never trim foreground app (`dumpsys activity` top-app check)
- ❌ Never set `persist.sys.oplus.high_performance=1` (contradicts the goal)
- ❌ Never touch `memory.max` (kills apps)
- ❌ Never throttle GMS / Play Store / Quick Search (handles its own scheduling)
- ❌ No aggressive `device_idle_constants` (delays notifications)
- ❌ No wildcard package matching (explicit lists only)

### OxygenOS Athena Tuning

- `persist.sys.oplus.athena.reclaim_enable=1` — allow reclaim
- `persist.sys.oplus.athena.force_kill=0` — forbid outright kills
- `persist.sys.oplus.athena.limit_count=120`
- DeepThinker kept enabled (needed for AI Suggestions widget, 3D wallpaper)

### Telemetry-Only Disable

Only **4 pure analytics uploaders** are disabled: `com.oplus.midas`, `com.oplus.olc`, `com.oplus.crashbox`, `com.oplus.logkit`. Two telemetry HAL services stopped: `cammidasservice-V1`, `olc2-V3`. **No** ContentProviders, **no** IPC framework, **no** customization.

---

## 🛡️ OnePlus Feature Recovery

A startup hook enforces **27 OnePlus packages as enabled** on every boot — fixes packages disabled by old modules, manual `pm disable`, or stale state from any source. `pm enable` on already-enabled packages is a no-op, so this is free.

| Category | Packages |
|:---------|:---------|
| AI / smart features | aimemory, deepthinker, athena, pantanal.ums, appsense |
| Health / activity | healthservice, trafficmonitor |
| Network quality | nas, nhs |
| System updates | sauhelper, sau, romupdate |
| Platform deps | appplatform, appbooster, epona |
| Customization | customize.coreapp, customize.cust_manage, customize.systemui, customize.opmconfigs |
| UI / settings | wirelesssettings, powermonitor |
| Charging / signal | qualityprotect |
| Observability | metis, statistics.rom, onetrace |
| Gaming network | gameopt, gamespaceui |

Audio HAL suspend-blocker props (legacy from earlier builds) are also cleared every boot — prevents audio pipeline from keeping the kernel awake after BT audio sessions.

---

## 🔑 Tencent Soter Auto-Fix

WeChat, Alipay, and several Chinese banks use the Tencent Soter biometric protocol. On OnePlus global ROMs, the `vendor.soter` daemon often misbehaves after boot — losing fingerprint auth in those apps.

ASB runs an automatic repair in the background after `sys.boot_completed=1`:

```
stop vendor.soter
pm clear com.tencent.soter.soterserver
start vendor.soter
```

Repeated for 5 minutes. Users without Tencent apps are unaffected — the loop is a no-op on devices without those packages.

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
2. Select features at install — **15 categories** (saved between updates):
   - **Always on by default**: AUDIO, BT, CAMERA, CPU, VM, NET, WIFI, GPS, KERNEL, LOG, RADIO/IMS, DISPLAY, FPS, SECURITY
   - **Opt-in**: BG_TRIM (Smart Reclaim + OPPO telemetry trim)
3. Reboot → governor starts automatically
4. Open **WebUI** → choose profile, or tap **Action** in module list for live status

   <p align="center">
  <a href="https://github.com/krilikd/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_Download_Latest_Release-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Download Latest Release">
  </a>
</p>

---

## 💾 Config Persistence

Your category selections are saved to `/data/adb/asb_user_config` — **outside the module directory**. When you flash an update, the installer detects the saved configuration:

```
================================================
  Saved configuration found
    from: 2026-05-20 12:30:00
    ver:  Vxx
  VOL+ = use saved  |  VOL- = re-select
================================================
```

- **VOL+** — apply saved choices, install completes in ~3 seconds
- **VOL-** — re-run the interactive flow, save new choices
- **timeout (10s)** — defaults to saved (conservative)

Active profile is also mirrored to `/data/adb/asb_active_profile` — your `performance` / `balanced` / `battery` choice survives reinstall.

---

## 🎯 Action Button — Live Status

Tap **Action** in the module list (Magisk/KSU) for an instant readout:

```
  ASB · battery

  🌡  CPU      : 39°C
  🔋 Battery  : 31.5°C   78%

  Estimated time to 0%:
    📱 screen on  : ~9h 22m
    💤 screen off : ~75h 0m

  Opening Telegram channel...
```

CPU temp, battery temp + level, time-to-empty estimates (screen on / screen off, calibrated per profile). Then automatically opens the support channel.

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
