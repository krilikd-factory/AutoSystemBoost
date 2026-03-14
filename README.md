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

<p align="center"><b>Advanced Adaptive Runtime Engine for OnePlus</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Root-Magisk%20%7C%20KernelSU-7c3aed?style=for-the-badge" alt="Root">
  <img src="https://img.shields.io/badge/Version-V22-16a34a?style=for-the-badge" alt="V22">
  <img src="https://img.shields.io/badge/OnePlus-15%20focused-red?style=for-the-badge" alt="OnePlus 15 focused">
  <img src="https://img.shields.io/badge/Cross--Device-Safer%20Install-0ea5e9?style=for-the-badge" alt="Safer install">
</p>

---

## ✨ What is AutoSystemBoost?

**AutoSystemBoost** is a comprehensive optimization module for rooted **OnePlus** devices that improves what you actually feel in daily use:

- ⚡ faster UI response and app launches
- 🎮 smarter high-load behavior with session-aware governor
- 🔋 genuine battery efficiency — not just capped clocks
- 🎵 improved audio quality and Bluetooth codec performance
- 📷 enhanced camera processing pipeline
- 🌐 tuned network stack for lower latency
- 🖥️ built-in **WebUI** for live profile switching

Instead of forcing one static tuning style, the module gives you three practical modes:

- 🔥 **Performance**
- ⚖️ **Balanced**
- 🔋 **Battery**

---

## 🖥️ Built-in WebUI

AutoSystemBoost includes a full **WebUI** accessible directly from Magisk / KernelSU:

- 📱 detected device and chipset display
- 🎛️ live profile switching (Performance / Balanced / Battery)
- ✅ active profile shown in the module card
- 🔗 quick Telegram shortcut
- 🧩 clean OnePlus-oriented layout

---

## 🎯 Profiles

### 🔥 Performance
- Full CPU/GPU frequency ceiling for SD8 Elite
- Aggressive WALT scheduler — top-app weight 170, ED boost enabled
- Minimum CPU floors at `2.1 GHz` (little) / `2.4 GHz` (big)
- GPU minimum 25% frequency floor, idle timer 48ms
- Low dirty writeback (800ms) for fast storage flush
- WiFi power save disabled, maximum TX queue

### ⚖️ Balanced
- CPU caps at `1.19 GHz` little / `1.88 GHz` big at idle, full ceiling available under load
- WALT top-app weight 110, moderate ED boost
- GPU max 85%, idle timer 64ms
- Balanced dirty writeback (4s), moderate swappiness
- WiFi power save auto

### 🔋 Battery
- CPU caps at `729 MHz` little / `1.07 GHz` big
- GAMING state blocked at governor level — no CPU spike from GPU activity
- Fast deep idle: governor enters DEEP_IDLE within 15s of low activity
- GPU capped at 22% maximum, idle timer 16ms
- High swappiness (180), extended dirty writeback (180s)
- WiFi power save on

---

## 🧠 Native Adaptive Governor (V22)

AutoSystemBoost V22 includes a **session-aware native governor** (`bin/asb`) that runs as a daemon and makes intelligent decisions every 2 seconds.

### FSM States

| State | Trigger | Behavior |
|-------|---------|----------|
| `DEEP_IDLE` | Screen off | Minimal wakeups, 5s polling |
| `LIGHT_IDLE` | Screen on, low load | Conservative caps |
| `MODERATE` | CPU load ≥ 1.5 or background current | Moderate caps |
| `HEAVY` | GPU ≥ 35% or load ≥ 2.0 | Active caps, boost eligible |
| `GAMING` | GPU ≥ 65% | Full performance caps, msm_perf boost |
| `SUSTAINED` | Thermal ≥ 65°C or GAMING caps unreachable | Stable practical mode |

### Gap-aware SUSTAINED
If GAMING CPU caps are being cut by the vendor thermal stack by more than 1500 MHz for 8+ seconds, the governor automatically transitions to SUSTAINED — a more conservative but genuinely achievable performance level — instead of fighting the thermal wall.

### Session Telemetry
The governor tracks per-session statistics visible in `asb status`:
- Time spent in each high-load state
- Average and peak cap gap in GAMING
- Sustained entry count (thermal vs unreachable)
- Peak temperature

### Adaptive High-Load Strategy
Set in `config/governor.conf`:
```
highload_mode=burst    # benchmarks / short sessions
highload_mode=stable   # long gaming sessions
highload_mode=auto     # intelligent burst→stable transition
highload_mode=default  # manual parameters
```

### Control commands
```bash
asb status           # full JSON status
asb profile:battery  # switch profile live
asb reload           # reload governor.conf
asb reset-stats      # reset session counters
tail -f /dev/.asb/governor.log
cat /dev/.asb/state
```

---

## 🎵 Audio Improvements

AutoSystemBoost applies a comprehensive audio enhancement stack during installation:

### Signal Chain Quality
| Area | Stock | AutoSystemBoost |
|------|-------|-----------------|
| Headphone bit depth | 16/24-bit | **32-bit** |
| Speaker bit depth | 16/24-bit | **32-bit** |
| Processing precision | PCM 32-bit | **PCM Float** |
| Hardware compressor (COMP) | Enabled (reduces dynamics) | **Disabled — wider dynamic range** |
| Soft-clipper | Enabled (adds distortion) | **Disabled — cleaner peaks** |
| IIR EQ bands | Enabled (colors sound) | **Disabled — flat response** |
| Voice sidetone | Enabled | **Disabled** |

### Volume & Output
| Area | Stock | AutoSystemBoost |
|------|-------|-----------------|
| Digital volume register | 80–87 / 128 | **88 / 128 (+1–2 dB)** |
| HPHL / HPHR output volume | Default (may be limited) | **Maximum (20/20)** |
| CLSH class-H mode | NORMAL_DSM_OUT | **CLSH_DSM_OUT — better efficiency** |
| HiFi mode | Off on some builds | **Enabled** |
| High-pass filter | Enabled (cuts sub-bass) | **Disabled — full low end** |
| Low-pass filter | Enabled | **Disabled — extended treble** |
| VBAT protection (limits output) | Enabled | **Disabled** |

### Sample Rate & Codec Support
| Area | Stock limit | AutoSystemBoost |
|------|------------|-----------------|
| Headphone output sample rate | Up to 48 kHz | **Up to 192 kHz (hi-res audio)** |
| Speaker / PCM output | 32–48 kHz | **Up to 384 kHz** |
| Audio codec sample range | Fixed ranges | **1–192 000 Hz unlocked** |
| Audio bitrate range | Up to 320–960 kbps | **Up to 18 Mbps** |
| Codec complexity (Opus/FLAC) | 7–9 / 10 | **Maximum (10 / 10)** |
| A2DP Bluetooth sample rates | 44100–96000 Hz | **Up to 192 000 Hz** |

### Bluetooth Audio
| Area | Stock | AutoSystemBoost |
|------|-------|-----------------|
| LHDC low-latency (LHDC LL) | Not always active | **Enabled** |
| AOSP low-latency codec | Not always active | **Enabled** |
| A2DP offload | Default | **Enabled — lower CPU usage** |
| Bluetooth trace logging | Enabled (wastes RAM/battery) | **Disabled** |
| AAC frame control | Enabled (adds latency) | **Disabled — cleaner AAC** |
| BT audio sample rate policy | Narrow | **Full range enabled** |

### Audio Offload
All hardware audio decode offload paths are enabled: AAC, ALAC, APE, FLAC, PCM 16/24, Vorbis, WMA, Opus. This moves decoding off the CPU to dedicated DSP hardware, reducing battery usage during music playback.

### App Whitelist
Neutron Player, Spotify, YouTube Music, Tidal, Qobuz, VK Music, Deezer, Apple Music, UAPP, jetAudio, and more are added to the high-quality audio processing whitelist for access to kernel audio paths.

> **Practical result:** headphone output is louder and cleaner, compression artifacts are reduced, hi-res audio files play at their native sample rate, and Bluetooth headphones receive higher quality streams.

---

## 📷 Camera Improvements

AutoSystemBoost enables advanced camera processing properties:

| Feature | Stock | AutoSystemBoost |
|---------|-------|-----------------|
| MFNR (Multi-Frame Noise Reduction) | May be limited | **Enabled** — cleaner low-light shots |
| EIS (Electronic Image Stabilization) | Default | **Enabled** — smoother video |
| SAT fallback distance | Stock threshold | **2.0 m** — better zoom transitions |
| Main camera HFR (High Frame Rate) | Default | **Enabled** — high-fps capture |
| Fast AF | Default | **Enabled** — snappier autofocus |

> **Practical result:** lower-light photos are sharper, video is more stable, zoom switching is smoother, and autofocus is faster.

---

## 📊 Stock vs AutoSystemBoost

> These are **practical target ranges**, not laboratory guarantees. Real results depend on kernel, ROM, installed apps, and usage pattern.

### Daily behavior

| Category | Stock | AutoSystemBoost target |
|---------|-------|------------------------|
| UI responsiveness | baseline | **~8–18% faster perceived response** |
| App launch speed | baseline | **~5–15% faster** |
| Animation stability | can dip under burst | **more stable / less micro-stutter** |
| Standby drain | baseline | **~3–10% lower in Balanced/Battery** |
| Audio headphone output | conservative | **louder, wider dynamic range** |
| BT audio quality | default codec negotiation | **max quality paths enabled** |
| Camera low-light | stock MFNR behavior | **improved noise reduction** |

### Expected battery vs stock

| Scenario | Stock | Target |
|---------|-------|--------|
| Overnight standby | baseline | **~3–10% better** in Balanced/Battery |
| Light daily use | baseline | **~4–9% better** in Battery |
| Mixed daily use | baseline | **~0–6% better** in Balanced |
| Heavy gaming | baseline | **equal or worse** in Performance (by design) |

---

## ⚙️ Main Tuning Areas

AutoSystemBoost adjusts multiple parts of the runtime stack:

- 🧠 **WALT / RAVG scheduler** — per-profile tuning for idle sufficiency and cluster thresholds
- 📈 **uclamp** — top-app, foreground, and background clamping per profile
- 🖲️ **CPU frequency floors and caps** — profile-specific min/max per cluster
- 🎮 **GPU idle timer and power level** — profile-aware GPU behavior
- 💾 **VM tuning** — swappiness, dirty writeback, VFS pressure, watermarks
- 🌐 **Network stack** — TCP buffers, qdisc, BBR/CUBIC congestion control, keepalive
- 📶 **WiFi** — power save mode, TX queue length, country code
- 🎵 **Audio** — bit depth, sample rate, codec offload, compression, BT codecs
- 📷 **Camera** — MFNR, EIS, SAT, HFR, FastAF
- 🗺️ **GPS** — AGPS server tuning
- 🧹 **System** — log reduction, dropbox cleanup, ZRAM configuration

---

## 📱 Device Support

### ✅ Best experience
**OnePlus 15** (CPH2745 / CPH2747) — primary reference device, fully tuned.

### ✅ Broader support
The module installs safely on other OnePlus devices with automatic overlay pruning:

- OnePlus 13 / 13R / 13s / 13T
- OnePlus 12 / 12R
- OnePlus 11 / 11R
- OnePlus Open
- Ace / Nord / Pad models

Non-OP15 devices receive script/prop tweaks with device-specific vendor overlays removed automatically.

---

## 🌡️ Profile Philosophy

| Profile | Heat | Battery | Response | Governor |
|--------|------|---------|----------|---------|
| 🔥 Performance | higher | lower | **fastest** | Full caps, boost active |
| ⚖️ Balanced | moderate | good | **best overall** | Dynamic caps, session-adaptive |
| 🔋 Battery | lowest | best | conservative | GAMING blocked, fast deep idle |

---

## 📦 Installation

1. Flash in **Magisk / KernelSU**
2. Select features during install (Bluetooth, Camera, CPU, VM, Network, WiFi, GPS, Kernel, Log)
3. Reboot
4. Open **WebUI** → choose profile

---

## ✅ Recommended Usage

- Use **Balanced** as your default daily profile
- Switch to **Performance** for gaming, benchmarks, or heavy apps
- Use **Battery** for travel, long standby, or light-use sessions

---

## ⚠️ Important Notes

- Root required (Magisk or KernelSU)
- Best results on **OnePlus 15**
- Performance profile intentionally increases power draw and heat
- Battery profile intentionally reduces peak performance in exchange for efficiency
- Audio and camera changes apply only on OP15 or when installed with those features enabled

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

Not magic. Just everything stock leaves on the table, collected in one place.
