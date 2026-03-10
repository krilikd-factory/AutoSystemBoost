<p align="center">
  <a href="README.md">
    <img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English">
  </a>
  <a href="README.ru.md">
    <img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский">
  </a>
</p>

<h1 align="center">🚀 AutoSystemBoost V18</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="AutoSystemBoost Banner" width="100%">
</p>

<p align="center"><b>Advanced Optimization Engine for OnePlus 15, with compatibility mode for other OnePlus devices</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Primary_Target-OnePlus_15-16a34a?style=for-the-badge" alt="Target">
  <img src="https://img.shields.io/badge/WebUI-Profiles-0ea5e9?style=for-the-badge" alt="WebUI">
  <img src="https://img.shields.io/badge/Magisk%20%7C%20KernelSU%20%7C%20APatch-Compatible-0ea5e9?style=for-the-badge" alt="Root Managers">
  <img src="https://img.shields.io/badge/Version-V18-22c55e?style=for-the-badge" alt="Version">
</p>

<p align="center">
AutoSystemBoost is an advanced <b>Android system optimization module</b> focused on scheduler efficiency, audio quality, camera tuning, network behavior and idle power management.
<br>
V18 adds a full <b>WebUI profile system</b> and a safer <b>multi-device compatibility layer</b> for other OnePlus models.
</p>

---

## ✨ What is new in V18

V18 is the first AutoSystemBoost release that combines:

- a built-in **WebUI**
- **live runtime profiles**
- safer install logic for **other OnePlus devices**
- the existing deep tuning stack for:
  - CPU / WALT / VM
  - audio and Bluetooth
  - camera and media
  - network / Wi-Fi / GPS

### New headline features

| Feature | V17 | V18 |
|---------|-----|-----|
| WebUI | No | **Yes** |
| Runtime profiles | No | **Performance / Balanced / Battery** |
| Live profile switching | No | **Yes** |
| OnePlus compatibility mode | Limited | **Improved** |
| OP15 remains best-tuned target | Yes | **Yes** |

---

## 🖥 WebUI & Profile System

V18 introduces a built-in WebUI with three runtime modes:

### 🔥 Performance
For gaming, faster app launches and more aggressive scheduler response.

Typical behaviour:
- faster ramp-up
- lower scheduler reaction window
- higher CPU minimum floors
- faster writeback timing
- shorter GPU idle timer

### ⚖️ Balanced
Default profile and the best all-round everyday mode.

Typical behaviour:
- clean scheduler response
- good UI smoothness
- strong idle efficiency
- sensible memory behaviour
- safe default profile for most users

### 🔋 Battery
For screen-off time, light use and maximum standby efficiency.

Typical behaviour:
- slower reaction window
- softer task placement
- longer dirty writeback intervals
- longer GPU idle timer
- deeper low-load behavior

### Why this matters

Older ASB releases used one fixed runtime behaviour.  
V18 lets the module adapt to the way the device is used right now.

---

## 📱 Device Support

### Primary target
AutoSystemBoost V18 is still tuned primarily for:

- **OnePlus 15**
- **Snapdragon 8 Elite Gen 5 / SM8850**

### Compatibility mode
V18 also introduces safer install logic for other OnePlus devices.

This includes conditional handling of device-sensitive files such as:
- camera configs
- media profiles
- audio policy overlays
- mixer / resourcemanager overlays
- selected vendor / ODM packages

### Important note
Compatibility mode improves safety, but it does **not** mean every non-OP15 model is tuned as perfectly as OnePlus 15.

**Best experience:** OnePlus 15  
**Broader compatibility:** other supported OnePlus models with filtered risky overlays

---

## ⚡ What AutoSystemBoost Improves

| System Area | Main Focus | V18 Result |
|-------------|------------|-------------|
| 🧠 CPU Scheduler / WALT | better task packing and more useful runtime behavior | **profile-based tuning** |
| 🔋 VM / Idle | lower wakeup noise and cleaner background behaviour | **better per-scenario control** |
| 🎮 GPU | less waste during idle and frame gaps | **profile-aware idle timing** |
| 🔊 Audio / Bluetooth | louder, cleaner, more capable output | **retained and expanded** |
| 📷 Camera / Media | higher quality defaults and tuned configs | **retained** |
| 🌐 Network / Wi‑Fi / GPS | cleaner transport and connectivity behavior | **retained** |
| 📱 Device Safety | safer install on non-OP15 OnePlus devices | **improved** |

---

## 🔊 Audio Improvements

AutoSystemBoost keeps the strong audio stack from the V17 generation and beyond.

### Main audio goals
- better speaker and Bluetooth sound quality
- stronger codec handling
- cleaner audio policy behavior
- higher-end playback capability where supported

### Highlights
- tuned audio policy and mixer paths
- stronger Bluetooth codec behaviour
- high-resolution playback improvements
- Dolby / extended audio stack handling where present
- user-facing optimization aimed at premium TWS use

### Bluetooth focus
Optimized especially for:
- **OnePlus Buds Pro 3**
- high-end LHDC / LDAC capable earbuds

---

## 📷 Camera and Media

V18 retains the camera/media tuning direction established in earlier advanced builds:

- camera config overlays
- media profile tuning
- video pipeline quality improvements
- tuned camera launch / media handling behavior

### Important compatibility note
Because camera and media files are highly device-specific, V18 now applies more careful filtering on non-OP15 devices to reduce the risk of:
- broken camera startup
- wrong media profile mapping
- incompatible audio/media policy overlays

That is one of the biggest structural improvements in V18.

---

## 🌐 Network, Wi‑Fi and GPS

V18 keeps the modern network stack direction used in previous high-end ASB builds.

### Areas covered
- TCP tuning
- congestion control handling
- Wi‑Fi scan / wakeup behaviour
- idle network behavior
- GPS / AGPS improvements

### Goal
Not fake benchmark gains, but cleaner real-world behaviour:
- faster recovery after idle
- less useless background activity
- better standby discipline
- more consistent everyday responsiveness

---

## 🔋 Battery, Heat and Real-World Use

V18 is designed to be more flexible than V17, not just more aggressive.

### What this means in practice
- **Balanced** remains the best everyday mode
- **Performance** exists for demanding sessions
- **Battery** exists for long standby / lighter usage

### Expected character vs stock
- lower background noise
- cleaner scheduler behaviour
- better idle return
- less unnecessary frequency holding
- lower light-load heat spikes

### Expected character vs V17
- more user control
- wider runtime range
- more polished daily experience
- broader device safety

---

## 📦 Installation

1. Install **Magisk**, **KernelSU** or **APatch**
2. Flash the module
3. Select desired install categories during setup
4. Reboot
5. Open the **WebUI** to switch profiles when needed

### Available install categories
- Audio
- Camera
- CPU
- VM
- Network
- Wi‑Fi
- GPS
- Kernel
- Logs

---

## 🧩 WebUI Support

V18 includes a built-in WebUI profile interface.

Depending on your environment, access may work through:
- native KernelSU / MMRL WebUI integration
- external WebUI hosts such as KSUWebUIStandalone / WebUI X

The WebUI shows:
- current active profile
- profile cards
- quick live switching
- visible runtime mode state

---

## ⭐ Support the Project

If you like AutoSystemBoost:

- ⭐ Star the repository
- 💬 Share feedback via [Telegram](https://t.me/DKomsomol)
- 🐛 Report issues and device-specific compatibility feedback

---

## ⚠ Disclaimer

This module modifies system behaviour.

Use it at your own risk.

AutoSystemBoost is designed to remain as safe and reversible as possible, but:
- the best tuning quality is still on **OnePlus 15**
- other OnePlus models use a **compatibility-oriented path**, not a perfect one-to-one vendor match
