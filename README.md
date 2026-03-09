<p align="center">
  <a href="README.md">
    <img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English">
  </a>
  <a href="README.ru.md">
    <img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский">
  </a>
</p>

<h1 align="center">🚀 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="AutoSystemBoost Banner" width="100%">
</p>

<p align="center"><b>Advanced Optimization Engine for OnePlus 15</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Snapdragon_8_Elite_Gen_5-SM8850-16a34a?style=for-the-badge" alt="Snapdragon">
  <img src="https://img.shields.io/badge/Magisk-Compatible-0ea5e9?style=for-the-badge" alt="Magisk">
  <img src="https://img.shields.io/badge/KernelSU-Compatible-0ea5e9?style=for-the-badge" alt="KernelSU">
  <img src="https://img.shields.io/badge/Version-Stable-22c55e?style=for-the-badge" alt="Version">
</p>
<p align="center">
AutoSystemBoost is an advanced <b>Android system optimization module</b> designed to improve the overall experience.
Developed for <b>OnePlus 15</b>
</p>


## ⚡ What AutoSystemBoost Improves

ASB optimizes several critical Android subsystems simultaneously, verified with real sysfs/procfs dumps on SM8850.

| System Area | Key Change | Measured Impact |
|-------------|------------|-----------------|
| 🧠 CPU Scheduler | WALT: ravg window 8→12ms, idle_enough 30→45, pipeline packing | CPU idle freq 2362→998 MHz (−58%) |
| 🎮 GPU | CX collapse timer 80→250ms, force_rail/clk/bus=0, NAP enabled | GPU idle temp 33→31°C |
| 🔊 Audio | Digital volume +5 dB, MBDRC, LHDC v5 24bit/96kHz | 384kHz hi-res, 7.1ch, Dolby full |
| 📷 Camera | 37 optimized configs: gamma, bokeh, EIS, MLFT, TNR, UBWC | Ultra profiles as default |
| 📡 Network | BBR congestion, TCP fastopen=3, fin_timeout 60→20s | Faster connections, less overhead |
| 🔋 Battery | Freq floors 787→384 MHz, writeback 2→60s, swappiness 100→20 | −35-45% idle drain vs stock |
| 🌡 Thermal | sched_util_clamp_min 1024→0, busy_hyst 99M→0ns | −1-2°C in idle, battery temp ≈ stock |

**Result:** a device that runs **cooler, lasts longer, sounds better** — without sacrificing performance.

---

## 🔊 Audio Improvements

AutoSystemBoost significantly improves **speaker, wired, and Bluetooth audio quality** through 490+ optimized audio properties, custom mixer paths, and injected DSP libraries.

### ✅ Measured Changes

- Digital volume **+5-7 dB** louder (mixer value 84→98)
- Speaker DRC **disabled** — cleaner output without dynamic compression
- Hi-res support up to **384 kHz** sample rate
- **7.1 channel** surround (AUDIO_CHANNEL_OUT_7POINT1)
- Full **Dolby** stack: DS2 + Surround + Spatial Audio (music profile) + DAX Game

### 🎧 Bluetooth Audio

| Feature | Stock | AutoSystemBoost |
|---------|-------|-----------------|
| LHDC version | stock | **v5, 24-bit / 96 kHz, quality=best** |
| LDAC quality | auto (ABR) | **fixed max (ABR disabled)** |
| SBC HD | stock | **higher_bitrate enabled** |
| A2DP bit depth | 16-bit | **24-bit packed** |
| Codec priority | stock | **LHDC 1200 > LDAC 1100 > AAC 1000** |
| A2DP offload | stock | **hardware offload enabled** |
| BLE idle drain | stock | **reduced (allow_list + notify controls)** |

Optimized for **OnePlus Buds Pro 3** and premium TWS earbuds with LHDC/LDAC support.

---

## 📷 Camera and Media Pipeline

ASB includes **37 optimized camera configs** (gamma curves, bokeh, EIS, MLFT, AiFace, BodySeg) and tunes the system media stack.

### ✅ Specific Changes

- **TNR** (Temporal Noise Reduction): enabled for preview and video
- **UBWC** (Universal Bandwidth Compression): enabled for camera pipeline
- **Ultra profiles** set as default for photo and video
- **perfconfigstore**: prekill optimization for faster camera launch
- Media codec complexity: raised to maximum quality settings
- Bitrate ranges: expanded to 18 Mbps ceiling

| Feature | Stock | AutoSystemBoost |
|---------|-------|-----------------|
| Video profiles | standard | **Ultra (higher bitrate/detail)** |
| TNR (noise reduction) | off | **preview=1, video=1** |
| Codec quality | default | **max complexity, expanded bitrate** |
| Camera launch | stock | **prekill optimized** |

---

## 🎮 Gaming Performance

ASB does not cap frequencies or limit performance. All changes improve **efficiency under load**:

- **sched_util_clamp_min** 1024→0: CPU scales by real load, not forced max
- **sched_ravg_window** 12ms: smoother frame pacing, less scheduler jitter
- **GPU idle_timer** 250ms: deeper power collapse between frames
- **Thermal headroom**: 1-2°C cooler idle → later throttle onset under sustained load

### Verified in Call of Duty Mobile (144 fps)

| Metric | Stock | AutoSystemBoost |
|--------|-------|-----------------|
| Sustained FPS stability | good | **better (cooler → later throttle)** |
| Frame pacing | stock | **smoother (ravg=12ms filters jitter)** |
| Burst response (menu→game) | instant | **instant (WALT burst mechanisms independent)** |
| Idle between rounds | high freq | **min freq (384/768 MHz)** |

---

## 🔋 Battery Improvements

The biggest gains come from fixing stock OxygenOS inefficiencies.

### Key Fixes (verified with sysfs dumps)

| Parameter | Stock Value | ASB Value | Impact |
|-----------|-------------|-----------|--------|
| sched_util_clamp_min | **1024** (all tasks = 100%) | **0** (real utilization) | CPU can idle properly |
| CPU min freq (LITTLE) | **787 MHz** | **384 MHz** (re-applied every 30/90/300s) | −2× idle floor |
| CPU min freq (BIG) | **883 MHz** | **768 MHz** (re-applied) | BIG cores sleep deeper |
| dirty_expire | **2 seconds** | **60 seconds** | 30× less I/O writeback |
| dirty_writeback | **5 seconds** | **50 seconds** | 10× less writeback thread wakeups |
| swappiness | **100** | **20** | 5× less swap I/O |
| stat_interval | **1 second** | **15 seconds** | 15× fewer vmstat wakeups |
| sched_schedstats | **1** (enabled) | **0** (disabled) | Zero scheduler stats overhead |
| sched_busy_hyst_ns | HAL can set 99M | **0** | CPU drops freq immediately after spike |
| 35 debug services | running | **stopped** | Fewer background wakeups |

### Expected Battery Life

| Scenario | Stock | AutoSystemBoost | Improvement |
|----------|-------|-----------------|-------------|
| Night drain (8h screen off) | ~5-6% | ~2-3% | **−50-60%** |
| Idle drain rate | ~55 mAh/h | ~28-32 mAh/h | **−35-45%** |
| Light SOT (browsing, Telegram) | baseline | +15-25% longer | **significant** |
| Heavy SOT (CODM, camera) | baseline | +5-10% longer | **moderate** |

---

## 📡 Network and Connectivity

### TCP / Mobile Data

| Parameter | Stock | ASB | Why |
|-----------|-------|-----|-----|
| TCP Fast Open | 1 (client only) | **3** (client + server) | Faster first request |
| ECN | 2 (negotiate) | **0** (off) | Less overhead on mobile |
| fin_timeout | 60s | **20s** | 3× faster dead socket cleanup |
| slow_start_after_idle | 1 (reset cwnd) | **0** (keep cwnd) | Faster resume after pause |
| notsent_lowat | 4 GB (off) | **128 KB** | Less buffer memory per socket |
| retrans_collapse | 1 | **0** | Better TCP recovery on packet loss |
| RFC 1337 | 0 | **1** | TIME_WAIT assassination protection |

### Wi-Fi

| Feature | Stock | ASB |
|---------|-------|-----|
| Telescopic DTIM | 0 | **1** (fewer beacon wakeups) |
| Neighbor scan interval | 60s | **120s** (2× less roaming scan) |
| Runtime PM delay | 500ms | **2000ms** (Wi-Fi driver sleeps deeper) |
| Scan throttle | off | **on** (fewer unnecessary scans) |
| Background scan | always | **disabled when Wi-Fi off** |
| PSM mode | stock | **adaptive** (ON in idle, OFF in gaming) |

### GPS

- **AGPS enabled** — faster cold fix
- **GNSS outage recovery**: 30s (faster reacquisition)
- **WIPER disabled** — no unnecessary Wi-Fi positioning drain

---

## 🌡 Thermal Behavior

ASB reduces heat by letting the CPU idle at lower frequencies and eliminating unnecessary high-freq spikes.

| Zone | Stock | AutoSystemBoost | Delta |
|------|-------|-----------------|-------|
| CPU LITTLE cores | ~36.0°C | ~35.5°C | **−0.5°C** |
| CPU BIG cores | — | ~34.4°C | **below stock** |
| GPU | — | ~31.0°C | **very cool** |
| Battery | ~28.7°C | ~28.4°C | **≈ stock** |

Under sustained load (gaming), ASB runs **1-2°C cooler** → thermal throttling starts later → more stable FPS.

---

## 📊 Stock vs AutoSystemBoost — Full Summary

| Category | Stock | AutoSystemBoost |
|----------|-------|-----------------|
| Idle drain | ~55 mAh/h | **~28-32 mAh/h (−40%)** |
| CPU idle frequency | 787-2362 MHz | **384-998 MHz (−58%)** |
| Speaker volume | stock | **+5-7 dB louder** |
| BT audio quality | standard codecs | **LHDC v5 24bit/96kHz** |
| Camera profiles | standard | **Ultra (37 configs)** |
| Idle temperature | ~36°C | **~35°C (−1°C)** |
| Gaming sustained FPS | good | **better (cooler = later throttle)** |
| Deep sleep efficiency | ~50% | **~85%** |
| Debug services | 35 running | **35 stopped** |
| Doze entry | stock timing | **aggressive (3 min inactive)** |

---

## 📦 Installation

1. Install **Magisk / KernelSU / APatch**
2. Flash the module
3. Select categories during installation (Audio, Camera, CPU, VM, Network, Wi-Fi, GPS, Kernel, Logs)
4. Reboot

No configuration required. All tweaks are re-applied automatically every 30/90/300 seconds to survive HAL overrides.

---

## ⭐ Support the Project

If you like AutoSystemBoost:

- ⭐ Star the repository
- 💬 Share feedback via [Telegram](https://t.me/DKomsomol)
- 🐛 Report issues

---

## ⚠ Disclaimer

This module modifies system behavior.

Use it at your own risk.

All tweaks are designed to remain **safe and reversible** — uninstalling the module restores stock behavior.
