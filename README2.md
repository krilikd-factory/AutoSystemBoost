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
  <img src="https://img.shields.io/badge/Smart_Mode-Adaptive-a78bfa?style=for-the-badge" alt="Smart Mode">
  <img src="https://img.shields.io/badge/WebUI-Built--in-f59e0b?style=for-the-badge" alt="WebUI">
</p>

---

ASB is a **native C governor daemon** that replaces stock scheduler, thermal and battery decisions with a finite‑state machine tuned for the OnePlus 15 (SM8850, Adreno 840) on OxygenOS 16. It learns from your real usage — second by second on the tick layer, session by session on the learner, and **time-of-day by daypart** through Smart Mode.

Four profiles are available: three static (battery / balanced / performance) and one adaptive (smart) that blends battery and balanced envelopes based on what your phone is actually doing right now.

---

## 🧠 Smart Mode — adaptive fourth profile

Smart Mode is **not a new set of frequency caps**. It is a *blend layer* that picks how much of the battery envelope versus the balanced envelope to apply, based on the current context.

### Twelve time-of-day buckets

```
            Weekday   Weekend
SLEEP  (00-06)   #0       #1
WAKE   (06-09)   #2       #3
MORN   (09-12)   #4       #5
DAY    (12-17)   #6       #7
EVE    (17-21)   #8       #9
LATE   (21-24)   #10      #11
```

Each bucket stores blend weights, not raw frequencies: `alpha_battery`, `interactive_bonus`, `idle_bias`, `sleep_bias`, `net_conservative_bias`. Cold-start seed values match baseline behavior so Smart Mode **does not feel sluggish on first boot** — it behaves like balanced during the day and like battery at night.

### What it learns from your sessions

Each finalized session feeds back into the active bucket. Direction is chosen by the session outcome:

- Hot, drainy, or long sustained load → bias toward battery (alpha rises)
- Cool, clean, screen-on, interactive → bias toward balanced (alpha drops)
- Night screen-off with low wake count → raise `sleep_bias` and `net_conservative_bias`
- Hot session with thermal vetoes → reduce `interactive_bonus`

Learning rate is **fixed at 5 % per session**, weighted by `duration × trust`. A long CLEAN session moves a bucket by the full 5 %; a short NOISY session whispers (~0.4 %); a DIRTY session is **ignored entirely**. No bucket can swing more than 5 % from a single observation.

### Confidence gate — habit suggests, math decides

A bucket's influence depends on its **effective observations** count and how recently it was seen:

```
confidence < 0.35  →  bucket ignored, baseline 50/50 blend
0.35 - 0.65        →  soft blend (up to 40 % of bucket strength)
≥ 0.65             →  bucket leads, but never above balanced envelope
```

Old data decays: full strength for the first 7 days, linear floor down to 30 % at 36 days, zero from day 37 onward.

### Hierarchical fallback — never punished for missing data

If your "Sunday evening" bucket has no data:

1. exact `(EVE, weekend)` lookup
2. fall back to `(EVE, *)` — try the weekday version
3. fall back to **class** (evening-class buckets, averaged)
4. fall back to **global** average across all populated buckets
5. fall back to **safe default** (baseline behavior)

Cold-start always lands somewhere reasonable.

### Safety overlays — always above habit

Two hard overrides that no learning can bypass:

- **Night-safe override** — screen off + late hours + not charging + battery ≤ 60 % → force `alpha_battery ≥ 0.70` and zero out `interactive_bonus`. Sleep wins over any learned daytime behavior.
- **Thermal veto** — CPU ≥ 65 °C *or* high vendor clamp activity *or* recovery active → scale bucket confidence by 0.3, force `alpha_battery ≥ 0.70`, zero out `interactive_bonus`. Habit may suggest. Thermal reality decides.

Smart Mode is fully **reversible** — turn it off and your previous manual profile is restored from `/data/adb/asb/smart_prev_profile`.

---

## 🎯 The four profiles

| Profile | Use it when | Caps style |
|---|---|---|
| 🔋 **battery** | Long sessions, hot ambient, screen-off background | Conservative everywhere; aggressive deep-idle |
| ⚖️ **balanced** | Daily UI, mixed workload, default daily-driver | Responsive UI, sustainable sustained envelope |
| ⚡ **performance** | Short bursts, app launches, benchmarks | Higher caps but never above balanced for sustained load |
| 🧠 **smart** | "Set and forget" — phone learns when you sleep, work, play | Dynamic blend of battery × balanced based on context |

You can switch at any time via WebUI, action menu, or by writing to `/data/adb/modules/AutoSystemBoost/current_profile`.

---

## 🧠 FSM — 6-State Machine

```
 DEEP_IDLE  →  LIGHT_IDLE  →  MODERATE  →  HEAVY  →  GAMING
                                   ↓
                              SUSTAINED  (thermal hold-down)
```

Each tick (~1-3 s) the governor reads CPU load, GPU percent, thermals, screen state, battery, recovery state, and decides which state best fits *right now*. State transitions respect minimum dwell times to prevent flapping.

Smart Mode does **not** replace this FSM. Smart Mode replaces the *bounds* the FSM reads from — substituting a blended `PROFILE_SMART` envelope instead of the static battery / balanced / performance values.

---

## 🧊 Thermal engineering

- **Multi-sensor advisory** — skin / surface / board sensors all vote; CPU temperature alone is not enough on this device because GPU and modem are major heat sources.
- **Skin-hot trigger** — when both skin and surface sensors vote ≥ 80, the performance profile transitions to SUSTAINED even if CPU temp has not crossed its CPU-only threshold yet. This is the first behavioral use of multi-sensor data.
- **Vendor clamp tracker** — counts how often OxygenOS PowerHAL clamps CPU below ASB's intended frequency. Exposed as `vendor_clamp_1h` / `vendor_clamp_total`. Smart Mode reads this and triggers thermal veto when clamping activity is high.
- **Cold baseline sensor calibration** — sensors are profiled at boot to subtract per-zone offset bias before voting.

---

## ⚔️ Anti-Clamp System

OnePlus 15 ships with an aggressive vendor PowerHAL that can clamp CPU frequencies below what any custom governor would prefer. ASB's anti-clamp does not try to *fight* this — it tries to **detect and accommodate** it.

### Clamp-Stable Hold
When vendor clamp depth stays consistent for N ticks, ASB stops re-writing the same cap value. Fewer sysfs writes, less vendor reaction overhead, lets thermals settle.

### Recovery Probe
After a thermal cooldown, ASB attempts a gentle cap raise. If vendor immediately clamps it back down, the probe backs off and waits longer before the next attempt. This prevents the "ASB writes 2.6 GHz → vendor pulls to 1.1 GHz → ASB writes 2.6 GHz again..." spiral that wastes CPU cycles.

---

## 🌪️ Storm Shield — Battery Ultra-Light

When the battery profile detects extreme thermal pressure (multi-sensor advisory score high *and* CPU temp climbing), it engages a deeper conservation tier: `scaling_min` frozen at policy floor, GPU min force-pinned, RAVG ticks doubled, `idle_enough` raised aggressively. Recovers to normal battery behavior when temperatures normalize.

---

## 🧠 BG_TRIM — Smart Reclaim Engine (opt-in)

OxygenOS's Athena reclaim daemon is too eager — it kills apps you actively use. ASB ships a **safer reclaim policy** that respects the foreground app, your five most-used apps, and the current standby bucket.

### Standby Bucket Strategy
Apps in ACTIVE/WORKING_SET buckets are never trimmed. RARE/FREQUENT apps get gentler trim than NEVER. Bucket assignments are read from UsageStatsService.

### What BG_TRIM does not do
- Does not kill the foreground app
- Does not kill apps with active notifications
- Does not kill apps opened in the last 30 minutes

### OxygenOS Athena tuning
ASB sets `persist.sys.oplus.athena.reclaim_enable=0` and related props at boot to disable Athena's aggressive killer. Apps stay alive between launches.

### Telemetry-only disable
Athena's telemetry collection (separate from killing logic) is **left on** — uninstalling ASB or toggling BG_TRIM off restores stock behavior immediately.

---

## 🔑 Tencent Soter Auto-Fix

Tencent Soter (Chinese banking SDK fingerprint manager) breaks on rooted OnePlus 15 when its security check fails. ASB autodetects affected apps (AliPay, WeChat Pay, ICBC, etc.) and patches the Soter response at sysprop level. No more "fingerprint not enrolled" errors during root payment flows.

---

## 📊 Stock vs ASB — measured

### ⚡ Scheduler & CPU
| Metric | Stock OxygenOS | ASB battery | ASB balanced | ASB smart |
|---|---:|---:|---:|---:|
| Idle big-core freq | ~1.1 GHz | 614 MHz | 787 MHz | learned per-bucket |
| Light load big-core | ~2.2 GHz | 1.4 GHz | 1.8 GHz | learned per-bucket |
| Deep idle latency | variable | < 100 ms | < 80 ms | < 80 ms |
| RAVG ticks | default | 8 | 4 | blended |

### 🔋 Battery impact (CPH2745, 7300 mAh, 100 % → 5 % screen-off idle, room temperature)
| Profile | Drain rate | Total time |
|---|---:|---:|
| Stock | ~5.8 %/h | ~16 h 20 m |
| ASB battery | ~2.1 %/h | ~45 h |
| ASB balanced | ~3.4 %/h | ~28 h |
| ASB smart | ~3.2 %/h | ~29 h |

(Smart numbers improve as buckets train.)

### 🌐 Network
- WIFI_COUNTRY locked to IT (regulatory compliance for Italian power outputs, can be changed in `customize.sh`)
- NTP server set to `it.pool.ntp.org` for lower jitter in EU
- TCP buffers tuned for high-bandwidth scenarios (4K streaming, gaming)

---

## 🎵 Audio tweaks

- Spatial audio support enabled (`persist.bluetooth.spatial_audio_support`)
- Audio zoom disabled (was causing recording quality regressions)
- Wired headphone latency reduced via `audio.deep_buffer.media`

---

## 📷 Camera tweaks

- HDR+ priority elevated for Camera app
- AI scene-detection latency reduced
- Burst mode preallocates buffers for faster shot-to-shot

---

## 🔧 Kernel & System tweaks

### Scheduler (WALT)
WALT is the Qualcomm load tracker on SM8850. ASB tunes:
- `sched_ravg_window` per profile
- Boost levels via `sched_boost`
- `sched_min_task_util_for_colocation` adjusted for gaming/heavy

### VM & Memory
- `vm.swappiness` per profile (battery=150, balanced=80, perf=60)
- `vm.dirty_ratio` / `vm.dirty_background_ratio` tuned to reduce write storms
- `vm.min_free_kbytes` proportional to RAM (12 GB device: ~64 MB)

### I/O
- I/O scheduler: `mq-deadline` for UFS3.1 storage
- Read-ahead per profile (smaller in battery, larger in performance)

### Network
- `net.core.rmem_max` / `wmem_max` raised
- TCP fastopen enabled (`net.ipv4.tcp_fastopen=3`)

---

## 📝 Log reduction

Two build flavors are produced:

- **Release** — no transient `governor.log`, smaller package, the one for daily use
- **Debug** — per-tick `governor.log`, full diagnostic suite, use only when capturing logs for analysis

**The learner runs identically in both builds.** `session_history.jsonl`, `learn.bin`, `pstats_*.json`, `buckets.bin` writes are never gated by build mode — Smart Mode keeps adapting whether you flash release or debug. Only verbose per-tick logging is suppressed in release.

Critical events (governor start, profile change, recovery, sustained thermal events) are also mirrored to `/data/adb/asb/governor_persist.log` (256 KB rotation) which survives reboots in both builds.

---

## 🩺 Diagnostics

Several diagnostic tools ship with **debug builds only** (not in release zip):

- `tools/logkit/asb_log_smart_gaming.sh` — capture a gaming session with Smart Mode trace
- `tools/logkit/asb_log_smart_sleep.sh` — capture an overnight idle session
- `tools/logkit/asb_log_smart_daily.sh` — capture a full day of mixed use
- `tools/logkit/asb_log_battery_mixed.sh` — battery profile mixed-load capture
- `tools/logkit/asb_log_perf.sh` — performance profile capture
- `tools/asb_field_report.py` — parse `session_history.jsonl` into human summary
- `tools/asb_vendor_thermal_probe.sh` — discover OxygenOS thermal zones

Release builds ship only `tools/asb_smart_mode.sh` for user control of Smart Mode.

---

## 🔧 Commands

### Smart Mode control
```bash
# Show current state
sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh status

# Enable Smart Mode (governor picks up on next read)
sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh enable

# Disable + restore previous manual profile
sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh disable

# Wipe all bucket learning (defaults reseeded on next boot)
sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh reset
```

### Action menu
Long-press the module in your root manager and pick "Action". You get an interactive menu with:

- Current battery, temperature and time-to-empty stats per profile
- Quick profile switch
- Smart Mode status and toggle
- Smart Mode bucket / confidence / current alpha live readout

Then automatically opens the support channel.

---

## 📱 Device support

**Primary target:** OnePlus 15 (CPH2745, codename "alor"), Snapdragon 8 Elite Gen 5 (SM8850-AC), Adreno 840.

**OS:** OxygenOS 16 (Android 16, kernel 6.12.x).

**Root managers:** KernelSU, KSUNext, APatch, ReSukiSU, Magisk.

Other devices may work but profile bounds are tuned specifically for SM8850 thermal/perf characteristics. Use at your own risk on other SoCs.

---

## ⭐ Support the project

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

This module modifies system behavior. Use at your own risk. All tweaks are **safe and reversible** — uninstalling restores stock. Smart Mode learning data lives in `/data/adb/asb/` and persists across module reinstalls — wipe it via the `reset` command above if you want a clean start.

---

<p align="center"><i>Not magic — just everything stock leaves on the table.</i></p>
