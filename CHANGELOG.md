# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V47-16a34a?style=for-the-badge" alt="V47">
  <img src="https://img.shields.io/badge/Previous-V46-6b7280?style=for-the-badge" alt="V46">
  <img src="https://img.shields.io/badge/versionCode-470-0ea5e9?style=for-the-badge" alt="versionCode">
  <img src="https://img.shields.io/badge/Smart_Mode-Adaptive-a78bfa?style=for-the-badge" alt="Smart Mode">
</p>

> **V47 introduces Smart Mode — a fourth adaptive profile that learns your time-of-day habits and blends battery↔balanced envelopes accordingly. Performance profile re-tuned cooler to stop fighting the vendor thermal HAL. Build pipeline split into release and debug flavors with identical learner behavior in both. Diagnostic surface area cleaned up.**

---

## ✨ Headline Features

### 🧠 Smart Mode — adaptive fourth profile

A brand-new profile that sits alongside battery / balanced / performance and **learns from your real usage**:

- **12 time-of-day buckets** (6 dayparts × weekday/weekend): sleep, wake, morn, day, eve, late
- **Blends battery and balanced envelopes** via learned `alpha_battery` weight per bucket — never learns raw frequency caps
- **Confidence gating**: < 0.35 ignore (baseline 50/50 blend), 0.35-0.65 mild influence (up to 40 % bucket strength), ≥ 0.65 strong but never above balanced sustained envelope
- **Hierarchical fallback**: exact bucket → daypart-only → daypart class → global average → safe default
- **Effective observations** counted by `duration × trust` — long CLEAN sessions teach, short NOISY sessions whisper, DIRTY sessions ignored entirely
- **Fixed 5 % learn rate** per session, capped — no single observation can swing a bucket more than 5 %
- **Time-decay** of stale data: full strength for 7 days, linear floor to 30 % at 36 days, zero from day 37
- **Night-safe override**: late hours + screen off + not charging + battery ≤ 60 % → force aggressive battery-lean
- **Thermal veto**: CPU hot / high vendor clamp / recovery active → confidence × 0.3, force battery-lean, zero interactive bonus
- **5-minute daypart smoothing** at boundary transitions (only when both buckets confident; hard switch otherwise)
- **App hint** as runtime modifier only (CPU-load heuristic, never primary truth)
- **Fully reversible** — disable Smart Mode and your previous manual profile is restored from `/data/adb/asb/smart_prev_profile`

---

## 🎯 V46 → V47 Comparison

| Area | V46 | V47 |
|---|---|---|
| **Profiles available** | 3 (battery / balanced / performance) | **4** (battery / balanced / performance / **smart**) |
| **Adaptive learning** | Per-profile FSM thresholds (`bat_fast_idle_s`, `heavy_load_enter`, `moderate_load_enter`) | + **Time-of-day buckets** (Smart Mode) |
| **Performance profile sustained heat** | Up to ~95 °C in long sessions (caps fought vendor PowerHAL) | **~71 °C** under same load (cooler caps + thermal veto) |
| **Multi-sensor thermal data** | Collected for observation | **Activated** as behavior trigger |
| **NOISY session trust tier** | Observed in shadow | **Activated** (learns at weight 0.15) |
| **Idle-warm intent class** | Detected, observe-only | **Activated** (forces PARTIAL trust) |
| **session_history.jsonl** | `/data/adb/modules/AutoSystemBoost/runtime/` (lost on module reinstall) | **`/data/adb/asb/`** (survives reinstall and module upgrade) |
| **Critical event log across reboots** | None — `governor.log` lost on reboot | New **`governor_persist.log`** in `/data/adb/asb/` (256 KB rotation, survives reboot) |
| **Build output** | Single zip | **Two zips** — `ASB-V47.zip` (release) + `ASB-V47-debug.zip` (full diagnostics) |
| **Smart Mode WebUI** | n/a | New AI-style profile button with live bucket / confidence / alpha readout |
| **Smart Mode CLI** | n/a | `tools/asb_smart_mode.sh status / enable / disable / reset` |

---

## 🚀 What's new in detail

### 🌡 Performance profile re-tuned

The V46 performance profile aimed at peak frequency and "fought" the OxygenOS vendor PowerHAL which clamped CPU anyway. Net result: 90 °C+ in long sessions with no actual perf benefit. V47 stops the fight.

| Bound | V46 | V47 |
|---|---:|---:|
| `PERFORMANCE_CPU_CAP_BIG` | 2611200 (2.61 GHz) | **2342400** (2.34 GHz) |
| `PERFORMANCE_CPU_CAP_LITTLE` | 2304000 | **2150400** |
| `PERFORMANCE_GPU_MAX_PCT` | 70 | **50** |
| `PERFORMANCE_CPU_MIN_BIG` | 1113600 | **921600** |
| `perf_hot_guard_temp` | 66 °C | **63 °C** |
| `perf_skin_hot_thresh` | n/a | **80** (new — first behavioral use of multi-sensor data) |

Peak burst frequency (`PERFORMANCE_CPU_MAX_BIG=3302400`, 3.30 GHz) **unchanged**. Only steady-state caps lowered.

### 🧠 Smart Mode plumbing (see Headline Features above)

A new `PROFILE_SMART` enum value reads its envelope from a mutable `g_smart_bounds` slot updated by the Smart Mode tick. The FSM treats it like any other profile — Smart Mode does not change the state machine, only the bounds it reads from.

Storage: `/data/adb/asb/buckets.bin` (12 × 36 bytes + 16-byte header = 448 bytes), atomic temp+rename writes, automatic `.bak` rotation every ~5 minutes, magic+version header for corruption detection, three-level load fallback (main → backup → seed defaults).

### 📊 Multi-sensor thermal voting widened

V46 collected skin / surface / board sensor data for observation. V47 activates two new behavioral hooks:

- **Mode A bias**: `adv_score ≥ 70` AND `gaming_ticks > 60` → would shorten gaming dwell
- **Mode B bias**: `skin + surface ≥ 75` AND `CPU < 60 °C` → would prevent gaming-state entry
- **`perf_skin_hot_thresh=80`**: when both skin and surface vote ≥ 80, performance profile transitions to SUSTAINED even before CPU temp crosses its CPU-only threshold

Vendor clamp tracker now exposes `vendor_clamp_1h` and `vendor_clamp_total` counters that Smart Mode's thermal veto consults.

### 🔁 Persistent learning survives module reinstall

V46 stored `session_history.jsonl` inside `/data/adb/modules/AutoSystemBoost/runtime/` — wiped by Magisk/KSU on every module reinstall. V47 moves it to `/data/adb/asb/session_history.jsonl` which is outside the module directory and persists across reinstalls. One-shot migration runs on first V47 boot to copy any existing legacy file.

Same treatment for legacy `/data/adb/asb_*` flag files — automatically migrated to `/data/adb/asb/*` on first boot.

### 📝 Persistent critical-event log

New `/data/adb/asb/governor_persist.log` (256 KB rotation, separate file handle from `/dev/.asb/governor.log`) captures critical events: governor start, profile changes, recovery events, sustained thermal episodes. Survives reboots, available in both release and debug builds.

### 📦 Release / Debug build split

Two zips per release:

- **`ASB-V47.zip`** — production. No transient `governor.log`, no `tools/logkit/`, no `tools/asb_field_report.py`. Smaller, focused.
- **`ASB-V47-debug.zip`** — full diagnostics. Per-tick `governor.log` enabled (compile flag `ASB_DEBUG_BUILD=1`), all logkit scripts included.

**The learner runs identically in both builds.** `session_history.jsonl`, `learn.bin`, `pstats_*.json`, `buckets.bin` writes are never gated by build mode. Only verbose per-tick logging is suppressed in release.

### ⚙️ Self-tune cadence stabilized

V46 logged a same-second `self_tune` warning for several parameters because the cadence guard checked a global timestamp rather than per-parameter. V47 introduces per-param timestamps (`tfi`, `thl`, `tml`, `tlg`) in `pstats_*.json` so each parameter has its own 2-hour adjustment window. No more spurious adjustments on the same tick.

### 🛡 Schema migration 14 → 15

`config/governor.conf` schema bumped to 15 so the additive merge picks up the new `perf_skin_hot_thresh` key and 13 new Smart Mode keys (`smart_mode_enabled`, `smart_conf_low`, `smart_conf_high`, etc.). Existing user customizations preserved — only missing keys are added.

### 🩺 Diagnostic tools

New logkit scripts (debug build only):

- `asb_log_smart_gaming.sh` — captures a gaming session with Smart Mode trace TSV (one row per poll: bucket, daypart, confidence, alpha, app hint, fallback level, CPU temp, etc.)
- `asb_log_smart_sleep.sh` — captures an overnight idle session
- `asb_log_smart_daily.sh` — captures a full day of mixed use
- `asb_vendor_thermal_probe.sh` — discovers OxygenOS thermal zone aliases for sensor mapping

New CLI in both release and debug:

- `tools/asb_smart_mode.sh status / enable / disable / reset` — user-facing Smart Mode control

---

## 🔧 Migration & Compatibility

### V46 → V47 upgrade behavior

- **Smart Mode is off by default for V46 upgraders**. Your manual profile (battery / balanced / performance) is detected and preserved. The migration code looks for V46 signs: `/data/adb/asb/active_profile`, `/data/adb/asb/user_config`, `/data/adb/asb/learn/`, `/data/adb/asb/pstats_battery.json`. If any of these exist, Smart Mode stays disabled and `smart_prev_profile` is set to your current profile.
- **Fresh installs default to Smart Mode on** with `smart_prev_profile=balanced` as the fallback if you later disable it.
- **Legacy `session_history.jsonl` migrated** one-shot to `/data/adb/asb/` on first V47 boot.
- **`governor.conf` additive merge** preserves all your customizations and only adds missing keys.

### Preserved V46 behavior

- All V46 thermal, idle and wake learning logic unchanged
- Crash Recovery v2 (tiered L1 / L2 / L3) unchanged
- Profile bounds for **battery and balanced are bit-exact V46**
- BG_TRIM, Storm Shield, Anti-Clamp, Tencent Soter — all preserved
- FSM scheduling logic identical to V46 apart from the new intent class and bias mode tracking
- Default behavior on first boot is V46-equivalent (Smart Mode off for upgraders)

### Reversibility

Smart Mode is fully reversible. Disable it via:

```bash
sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh disable
```

Your `smart_prev_profile` value is restored as the active profile. To completely wipe Smart Mode learning (12 buckets back to seed defaults):

```bash
sh /data/adb/modules/AutoSystemBoost/tools/asb_smart_mode.sh reset
```

---

## 📊 Field-test results

Single 42-minute Call of Duty Mobile session at room temperature, screen on, not charging.

| Metric | V46 performance profile | V47 smart profile |
|---|---:|---:|
| Peak CPU temperature | ~95 °C | **71 °C** |
| Battery temperature peak | ~50 °C | **47 °C** |
| Time above 70 °C CPU | ~35 % of session | **3 %** |
| Thermal veto fires | n/a (didn't exist) | 57 ticks once CPU hit 65 °C+ |
| Vendor clamp activity | high | moderate (governor no longer fighting) |

Smart Mode does not fight vendor clamps — it works *inside* what the vendor PowerHAL allows and picks better blends than performance ever could.

---

## 🚫 What V47 deliberately does NOT change

- All V46 critical fixes preserved (description boot-init, `/data/local/tmp` wildcard, OOM tuning relaxation)
- Crash Recovery v2 (tiered L1 / L2 / L3 + `recovery.json`) unchanged
- Profile bounds for **battery and balanced are bit-exact V46**
- WebUI Live overlay unchanged
- Per-app auto-profile still not implemented (still rejected — polling cost too high; Smart Mode uses CPU-load heuristic instead)
- BG_TRIM / Storm Shield / Anti-Clamp / Tencent Soter all preserved

---

## 🧠 Trust + intent decision matrix

| Trust | Intent | Learner action |
|---|---|---|
| CLEAN | IDLE, MIXED | Full weight 1.0 |
| CLEAN | SLEEP_IDLE | Forced PARTIAL (sleep is inherently noisy) |
| PARTIAL | any | Weight 0.4 |
| **NOISY** | any | **Weight 0.15** (newly activated) |
| DIRTY | any | Skipped entirely |
| any | **IDLE_WARM** | **Forced PARTIAL** (warm idle is ambiguous) |
| any | SLEEP_IDLE | Forced PARTIAL |

Smart Mode bucket learning uses the same trust tiers, with `quality = duration_weight × trust_weight` capped at 5 % step per session.

---
