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

<p align="center"><b>Advanced Optimization Engine for OnePlus</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/Root-Magisk%20%7C%20KernelSU-7c3aed?style=for-the-badge" alt="Root">
  <img src="https://img.shields.io/badge/WebUI-Performance%20%7C%20Balanced%20%7C%20Battery-16a34a?style=for-the-badge" alt="Profiles">
  <img src="https://img.shields.io/badge/OnePlus-15%20focused-red?style=for-the-badge" alt="OnePlus 15 focused">
  <img src="https://img.shields.io/badge/Cross--Device-Safer%20Install-0ea5e9?style=for-the-badge" alt="Safer install">
</p>

---

## ✨ What is AutoSystemBoost?

**AutoSystemBoost** is a tuning module for rooted **OnePlus** devices focused on what people actually notice in daily use:

- ⚡ faster UI response
- 🔋 better standby efficiency
- 🎮 stronger foreground behavior for gaming and heavy sessions
- 🧠 cleaner scheduler and memory behavior
- 🖥️ built-in **WebUI** with live profile switching

Instead of forcing one static tuning style, the module gives you three practical modes:

- 🔥 **Performance**
- ⚖️ **Balanced**
- 🔋 **Battery**

---

## 🖥️ Built-in WebUI

AutoSystemBoost includes a full **WebUI** with:

- 📱 detected device / chipset display
- 🎛️ live profile switching
- ✅ active profile shown directly in the module card
- 🔗 quick Telegram shortcut
- 🧩 cleaner OnePlus-oriented layout

This matters because the module is no longer a “flash once and hope” tweak pack.  
You can actually switch the behavior of the phone depending on your usage.

---

## 🎯 Profiles

### 🔥 Performance
Built for:
- gaming
- heavier multitasking
- faster app launches
- stronger top-app bias
- lower scheduler latency

### ⚖️ Balanced
Built for:
- daily use
- smooth UI
- sane heat
- stable battery life
- best all-round behavior

### 🔋 Battery
Built for:
- light usage
- standby-heavy days
- lower wakeups
- calmer background behavior
- stronger efficiency bias

---

## 📊 Stock vs AutoSystemBoost

> These values are **practical target ranges / expected behavior**, not laboratory guarantees.  
> Real-world results depend on kernel, ROM build, installed apps, radio conditions, ambient temperature and usage style.

### Daily behavior vs stock

| Category | Stock behavior | AutoSystemBoost target |
|---------|----------------|------------------------|
| UI responsiveness | baseline | **~8–18% faster perceived response** |
| App launch speed | baseline | **~5–15% faster foreground app opening** |
| Animation stability under load | can dip under burst load | **more stable / less micro-stutter** |
| Standby drain | baseline | **~3–10% lower overnight drain in Balanced/Battery** |
| Background churn | stock reclaim behavior | **reduced background noise / cleaner scheduling** |
| Foreground priority | stock top-app behavior | **stronger top-app bias in Performance** |
| Live tuning control | none | **WebUI profile switching** |

### Profile behavior vs stock

| Profile | Compared to stock | Best use case |
|--------|-------------------|---------------|
| 🔥 Performance | **~10–20% snappier foreground feel**, faster ramps, higher heat / power draw | gaming, stress sessions, heavy apps |
| ⚖️ Balanced | **~5–12% cleaner daily feel**, smoother task handling, better consistency | everyday use |
| 🔋 Battery | **~5–20% better standby/light-use efficiency**, lower wakeups, calmer memory behavior | travel, standby-heavy days, light use |

### Expected battery direction vs stock

| Scenario | Stock | AutoSystemBoost target |
|---------|-------|------------------------|
| Overnight standby | baseline | **~3–10% better** in Balanced / Battery |
| Light daily use | baseline | **~4–9% better** in Battery |
| Mixed daily use | baseline | **~0–6% better** in Balanced |
| Heavy gaming | baseline | **equal or worse battery life** in Performance, by design |

### Expected thermal direction vs stock

| Scenario | Stock | AutoSystemBoost target |
|---------|-------|------------------------|
| Light use | normal | **slightly lower background activity** in Battery |
| Mixed use | normal | **roughly similar or slightly cleaner thermals** in Balanced |
| Gaming / heavy load | normal | **higher sustained heat in Performance**, intentional trade-off |

---

## ⚙️ Main tuning areas

AutoSystemBoost adjusts multiple important parts of the runtime stack:

- 🧠 **WALT / RAVG scheduler**
- 📈 **uclamp** and top-app weighting
- 🖲️ profile-based CPU frequency floors
- 🎮 GPU idle timing
- 💾 VM tuning, dirty writeback and cache pressure behavior
- 🌐 network and queue tuning
- 🧩 selective compatibility logic for vendor/system overlays

The goal is not to chase benchmark screenshots at any cost.  
The goal is to make the phone feel faster, cleaner and more useful in actual use.

---

## 📱 Device support

### ✅ Best experience
- **OnePlus 15**

This is still the primary reference device and the most fully optimized target.

### ✅ Broader support
The module now behaves more safely on other OnePlus devices as well, including examples such as:

- OnePlus 13 / 13R / 13s / 13T
- OnePlus 12 / 12R
- OnePlus 11 / 11R
- OnePlus Open
- Ace / Nord / Pad models

---

## 🌡️ Performance philosophy

| Profile | Heat | Battery | Response |
|--------|------|---------|----------|
| 🔥 Performance | higher | lower | **fastest** |
| ⚖️ Balanced | moderate | good | **best overall balance** |
| 🔋 Battery | lowest of the three under light use | best standby / light-use efficiency | slowest, intentionally |

Battery is **not** meant to feel like Performance with free battery on top.  
Silicon still has the annoying habit of obeying physics.

---

## 📦 Installation

1. Flash the module in **Magisk / KernelSU / compatible root environment**
2. Reboot
3. Open **WebUI**
4. Choose the profile that matches your usage

---

## ✅ Recommended usage

- Use **Balanced** as your default daily profile
- Switch to **Performance** only when you actually need the extra speed
- Use **Battery** for travel, standby-heavy days or light-use sessions

---

## ⚠️ Important notes

- Root is required.
- Best results are still expected on **OnePlus 15**.
- Other OnePlus devices are handled more safely than before, but they are still not equal to the OP15 reference target.
- Performance profile intentionally increases power draw and heat.
- Battery profile prioritizes efficiency over raw speed.

---

## ⭐ Support the Project

If you like AutoSystemBoost:

- ⭐ Star the repository
- 💬 Share feedback via [Telegram](https://t.me/DKomsomol)
- 🐛 Report issues

---

## 🏁 Final note

AutoSystemBoost is meant to make a rooted OnePlus device feel **more deliberate**:

- faster when you want speed
- calmer when you want efficiency
- easier to control through WebUI

Not magic. Just much smarter than leaving everything on stock behavior.
