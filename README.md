<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">🛸 AutoSystemBoost</h1>
<p align="center">
  <img src="https://github.com/krilikd/AutoSystemBoost/blob/main/banner.png" alt="Banner" width="80%">
</p>

<p align="center"><b>Adaptive runtime engine for OnePlus — Snapdragon 8 Elite / Gen 3</b></p>
<p align="center"><i>A native C daemon that reads the device every 2 seconds and decides — it does not just write values once at boot.</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/Governor-Native_C-0ea5e9?style=for-the-badge" alt="C">
  <img src="https://img.shields.io/badge/Audio-Own_DSP_engine-dc2626?style=for-the-badge" alt="DSP">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
  <img src="https://img.shields.io/badge/Root-KSU_%7C_KSUN_%7C_APATCH_%7C_MAGISK-16a34a?style=for-the-badge" alt="Root">
</p>

<p align="center">
  <img src="https://img.shields.io/github/downloads/krilikd/AutoSystemBoost/total?style=for-the-badge&color=0969da&label=Downloads&logo=github" alt="Downloads">
  <img src="https://img.shields.io/github/v/release/krilikd/AutoSystemBoost?style=for-the-badge&color=16a34a&label=Latest" alt="Release">
  <img src="https://img.shields.io/github/stars/krilikd/AutoSystemBoost?style=for-the-badge&color=f59e0b&label=Stars&logo=github" alt="Stars">
</p>

---

## ⚡ What it actually is

Most modules are a list of values written once at boot. ASB is a **daemon**: it samples
CPU, GPU, thermals, battery and load every 2 seconds, moves through a 6-state machine,
and re-derives the caps each time. Plus an **audio DSP engine written from scratch**, a
learning profile that adapts to your day, and a WebUI to drive all of it.

| | Layer | Component | What it does |
|:---:|:---|:---|:---|
| 🧠 | **Core** | `bin/asb` | FSM · Session Plan · Anti-Clamp · Storm Shield · Camera Hold |
| 🎚 | **Audio** | `libasbdsp` | Own effect: loudness · compressor · limiter · bass shelf |
| 🔧 | **Shell** | `service.sh` | Boot config, reconcile, watchdog |
| 🖥 | **UI** | WebUI + Action | Profiles, live status, honest "not applied" report |
| 📡 | **HW** | Kernel | sysfs · procfs · cpufreq · WALT · KGSL |

---

## 📱 Device support

**Zero static vendor files.** ASB clones your phone's *own* stock files at install,
patches those copies, and mounts them back. Nothing from another model ever touches
your device.

| Tier | Devices | SoC |
|:---|:---|:---|
| 🥇 **Reference** — hand-validated | OnePlus 15 · 13 · 12 | SM8850 · SM8750 · SM8650 |
| 🥇 **Fully supported** — field-verified | Ace 6 · Ace 5 · 13R | SM8750 · SM8650 |
| ✅ **Device-native** | every other OnePlus — 15R, 13s/13T, 12R, 11/11R, Open, Ace 6T, Nord, Pad | various |

Reference devices get their own topology map, audio SKU and thermal profile behind a
**3-strike boot guard**. Everyone else runs the *identical* pipeline behind a stricter
**1-strike fuse** — one failed boot and the generated overlay is torn out before the
module mounts. Nothing is skipped, it is not a reduced mode; only the delivery differs.

> Sibling firmware is handled explicitly: the Ace 6 rides the same `sun` firmware as the
> OnePlus 13 and its fingerprint literally says `sun`. ASB matches `ktm` **before** the
> `sun` test, so it can never be mistaken for an OP13.

---

## 📦 Install

1. Flash in **KSU / KSUN / APatch / ReSuKiSu / Magisk**
2. Pick your feature categories at install — your choices are carried over on every update
3. Reboot → the governor starts on its own
4. Open the **WebUI** for profiles and settings, or tap **Action** for live status

<p align="center">
  <a href="https://github.com/krilikd/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_Download_Latest_Release-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Download">
  </a>
</p>

---

## 🎚 ASB DSP — our own audio engine

Volume curves can only redistribute the gain the device already gives you. To go
**above unity** you need real processing — so ASB ships its own effect, built from
scratch, in the module.

```
input → bass shelf (90 Hz) → soft-knee compressor → auto make-up → true-peak limiter → out
```

| | |
|:---|:---|
| 🔊 **`dsp_loudness`** | **+1 … +20 dB** of real gain above unity |
| 🥁 **`dsp_bass`** | **+1 … +10 dB** low shelf at 90 Hz — body, not sub rumble |
| 🛡 **No clipping** | Soft-knee compression and a true-peak limiter sit after the boost |
| ⚡ **Live** | Moving a slider goes to the running effect over binder — no `audioserver` restart, no drop-out |
| 🎧 **Everything** | Attached to the **global mix**: music, video, games, calls, any app |

**Why it needed building twice.** Android 13+ binds effects through the
`android.hardware.audio.effect` **AIDL** contract — a legacy `.so` is never attached to
the stream at all. ASB ships both from one shared core, so the sound is identical either
way. And because OxygenOS never applies config-declared post-processing, a companion
daemon creates the effect **programmatically on the global mix** — otherwise it would
stay silent until you happened to open an EQ app.

> The bass shelf sits at the **head** of the chain on purpose. Placed after the
> compressor and limiter, the added low-end energy would escape every safeguard and
> clip on the way out.

---

## 🎵 Audio — three switches, not a pile of flags

| Setting | Options | What it does |
|:---|:---|:---|
| **`audio_profile`** | `stock` · `hifi` · `eq_compat` | `hifi` = 32-bit float, 192 kHz, DRC off. `eq_compat` hands the stream to ViPER/JamesDSP — ASB steps aside instead of fighting for the output |
| **`audio_dac_hifi`** | on / off | The mixer half on its own switch: Class-H DAC, flat EQ, companders off |
| **`media_loudness`** | `stock` · mild · strong · max | Reshapes the volume curves themselves — position-weighted, so the boost lands at 40–80 % of slider travel where people actually listen |

Plus, versus stock: headphone path at **32-bit float** instead of 16/24-bit, **192 kHz**
max rate, DRC compressor **off**, codec complexity **10/10**, BT A2DP up to **192 kHz**,
LHDC v5 at best quality, full offload for AAC/ALAC/FLAC/Opus/WMA, and adaptive bitrate
on SBC/AAC for steadier Bluetooth on a weak link.

> 100 % volume is **never** raised. That is unity — past it you are only clipping.

---

## 🧠 The governor

**6 states.** `DEEP_IDLE` → `LIGHT_IDLE` → `MODERATE` → `HEAVY` → `SUSTAINED` → `GAMING`.
Each has its own caps, dwell times and entry/exit hysteresis. DEEP_IDLE costs **0 % CPU** —
the daemon genuinely stops working when the screen is off.

**Smart Mode** is a 4th, adaptive profile — and not a new set of caps. It *blends*
between the battery and balanced envelopes based on what it has learned about your day:
12 time-of-day buckets, weekday/weekend split, session history, a battery-budget model.
It never exceeds the balanced envelope and never drops below the battery floor. Habit
suggests; a confidence gate decides. Safety overlays — thermal veto, low battery,
night-safe — always win over habit.

**📷 Camera Hold.** A 4K60 capture lights up neither GPU busy nor the one-minute
loadavg — the ISP and the hardware encoder carry the work, while the HAL threads that do
need the CPU need it on a 16.6 ms deadline. ASB detects the streaming pipeline and holds
interactive caps, restores the cpuset to every core and lifts the `uclamp` ceilings the
camera HAL sits under — then puts every value back exactly as it found it.

**Anti-Clamp · Storm Shield · Session Plan.** The vendor thermal HAL clamps back; ASB
detects a stable clamp and stops fighting it, probes for recovery, and pre-computes the
whole session policy up front instead of recalculating every tick.

---

## 🎯 Profiles — real numbers

| Parameter | 🔥 Performance | ⚖️ Balanced | 🔋 Battery |
|:---|:---:|:---:|:---:|
| CPU min LITTLE / BIG | 1190 / 922 MHz | 787 / 883 MHz | 307 / 614 MHz |
| CPU cap LITTLE / BIG | 2400 / 2746 MHz | 1190 / 1882 MHz | 922 / 922 MHz |
| GPU min floor | 8 % | 0 % | 0 % |
| `uclamp` top / bg | 90 / 50 | 85 / 35 | 50 / 40 |
| RAVG window | 2 (8 ms) | 3 (12 ms) | 8 (32 ms) |
| Swappiness | 12 | 35 | 80 |
| VFS cache pressure | 30 | 80 | 120 |
| Dirty writeback | 10 s | 60 s | 600 s |
| Wi-Fi power save | off | auto | on |
| GAMING state | ✅ | ✅ | 🚫 blocked |
| SUSTAINED enter / exit | 59 / 56 °C | 57 / 49 °C | — |

> **Smart** is not in this table on purpose — its caps are not fixed. They are blended
> at runtime between the battery and balanced envelopes.

---

## 📊 Stock vs ASB

Measured from real sysfs/procfs dumps on OnePlus 15 / 13 / 12.

### ⚡ Scheduler & CPU

| Metric | Stock OxygenOS | ASB Balanced | |
|:---|:---:|:---:|:---:|
| `sched_util_clamp_min` | 1024 (pinned max) | 0 (real util) | **−100 %** |
| CPU freq captured at idle | 2362 MHz | 998 MHz | **−58 %** |
| `stat_interval` | 1 s | 15 s | **15× fewer wakeups** |
| Debug services running | 35 | 0 | **−100 %** |

### 🔋 Battery

| Scenario | Stock | ASB Balanced | ASB Battery |
|:---|:---:|:---:|:---:|
| Idle drain | ~55 mAh/h | ~32 mAh/h **−40 %** | ~20 mAh/h **−64 %** |
| Overnight, 8 h | ~5–6 % | ~3 % **−45 %** | ~1.5 % **−70 %** |
| Light screen-on time | baseline | **+15–20 %** | **+30–40 %** |

### 🌐 Network

| Parameter | Stock | ASB |
|:---|:---:|:---:|
| TCP congestion | cubic | **BBR** where the kernel offers it, cubic otherwise |
| TCP fastopen | 1 | **3** (client + server) |
| `tcp_fin_timeout` | 60 s | **20 s** |
| `tcp_slow_start_after_idle` | 1 (resets cwnd) | **0** (keeps it) |

### 📷 Camera

| Feature | Stock | ASB |
|:---|:---:|:---:|
| MFNR multi-frame NR | limited | **enabled** |
| EIS stabilization | default | **enabled** |
| HFR capture · fast AF | default | **enabled** |
| SAT fallback distance | stock | **2.0 m** |
| Tone / retouch tuning | stock | **device-native, patched from your own files** |

---

## 🛡 Safety

- Every tweak is **reversible** — uninstall restores stock, nothing is written to a real partition
- **Boot guard**: 1 or 3 strikes depending on tier — a failed boot removes the overlay *before* the module mounts
- **Thermal protection is never overridden**: the junction hard-limit and the writer's thermal cap always apply, even when a feature relaxes the soft battery lean
- **Config survives updates**: your WebUI settings, active profile and everything Smart Mode has learned live outside the module directory and are carried over key by key

---

## 🩺 Diagnostics & commands

Tap **Action** in the module list for live status: governor state, battery lean,
learning confidence, temperatures, time-to-empty, audio, camera, memory, network — and a
**NOT APPLIED** section that checks the system for evidence each setting actually landed
and lists only what did not.

```bash
su -c 'asb status'                # JSON status
su -c 'asb profile:performance'   # switch profile live
su -c 'asb reload'                # re-read config
su -c 'asbdiag'                   # full system report → /sdcard/asb_diag_report.txt
su -c 'tail -f /dev/.asb/governor.log'
```

| Tool | Purpose |
|:---|:---|
| `asbdiag` | Full PASS/FAIL report of what is actually live |
| `asb_doctor.sh` | Health check: HEALTHY / DEGRADED / UNHEALTHY |
| `session_history.jsonl` | Last 10 sessions, 30+ fields each |
| `asb_session_report.py` | Markdown report with trends |

---

## ⭐ Support

- ⭐ Star the repository · 🐛 report issues on GitHub
- 💬 [Telegram](https://t.me/DKomsomol)

<p align="center">
  <a href="https://paypal.me/lugaru46">
    <img src="https://img.shields.io/badge/PayPal-Donate-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate via PayPal">
  </a>
</p>

---

## ⚠️ Disclaimer

This module modifies system behaviour. Use at your own risk. All tweaks are safe and
reversible — uninstalling restores stock.

---

<p align="center"><i>Not magic — just everything stock leaves on the table.</i></p>
