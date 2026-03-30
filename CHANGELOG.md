# 🚀 AutoSystemBoost V31 — Changelog

---

## V31 — 🧠 Session Plan Architecture & Adaptive Behavior

> **V30 taught ASB to describe what happened.**
> **V31 teaches ASB to decide what to do before each tick — and stop doing what doesn't work.**

Four pillars: **pre-computed policy** · **budgeted aggression** · **environmental awareness** · **behavioral adaptation**

---

### 🏗️ Session Plan — The Brain Upgrade

The single biggest architectural change since ASB's FSM was created.

**Before (V30):** Every tick re-evaluated the same questions — is this battery? Is screen off? Can I read headroom? Can I anti-clamp? The same conditional branches ran thousands of times per hour.

**After (V31):** Policy decisions are computed **once** on events and stored in a compact plan. The hot path just reads the answer.

```
Event happens → session_plan_build() → plan ready
Tick fires    → read plan.allow_hr, plan.ac_eligible, plan.deep_sleep → done
```

#### Plan struct (12 fields)

| Field | Type | Purpose |
|:------|:----:|:--------|
| `sensor_tier` | uint8 | FULL / REDUCED / SPARSE |
| `thermal_div` | uint8 | Read thermal every N ticks |
| `allow_hr` | uint8 | Headroom reads on/off |
| `ac_eligible` | uint8 | Anti-clamp allowed |
| `deep_sleep` | uint8 | Extended tick interval |
| `ac_prearm` | uint8 | Skip detection delay (perf only) |
| `ac_budget` | uint8 | Max anti-clamp windows per session |
| `ac_used` | uint8 | Budget counter (runtime) |
| `quarantine` | uint8 | User-switch quarantine flag |
| `plan_class` | uint8 | Session classification enum |
| `sensor_budget` | uint8 | Max full-mode reads per epoch |
| `sensor_used` | uint8 | Sensor budget counter |

#### Plan rebuild triggers

| Event | Budget reset? | Why rebuild |
|:------|:------------:|:------------|
| 🟢 Startup | ✅ | Fresh state |
| 📱 Screen toggle | ❌ | Sensor/sleep policy changes |
| 🔄 Profile change | ✅ | Everything changes |
| 📊 State band cross | ❌ | idle↔active↔heavy needs different policy |
| ⏱️ Session reset | ✅ | New session, new budget |

---

### 🎯 Plan Class — Know What You Are

Every session now has a single classification that drives behavior:

| Class | When | Behavior |
|:------|:-----|:---------|
| `IDLE_CLEAN` | Battery, screen off, deep idle | Sparse thermal, deep sleep ticks, no headroom |
| `IDLE_NOISY` | Battery, screen off, wakes detected | Reduced sensing, no anti-clamp |
| `DAILY_ACTIVE` | Battery/balanced, screen on | Normal daily operation |
| `PERF_ACTIVE` | Performance or heavy balanced | Full sensors, anti-clamp armed |
| `PERF_CLAMPED` | Performance under vendor clamp | Detected at session classification |
| `BENCHMARK` | Benchmark detected | Full burst, learning exempt |
| `QUARANTINE` | After user switch | Ultra-conservative, no learning |

---

### ⚔️ Anti-Clamp — Budgeted, Not Infinite

V30 had anti-clamp detection and a cadence ladder. V31 adds **economics**.

#### Window-based budget

| Profile | Budget | What it means |
|:--------|:------:|:-------------|
| Performance | 6 windows | ~18 dual-writes spread across session |
| Balanced | 3 windows | ~9 dual-writes, less aggressive |
| Battery | 0 | Anti-clamp disabled |

Each **window** = BURST (3 writes @ 2s) → HOLD (4s) → BACKOFF (30s). Budget counts windows, not individual writes.

#### Futility suspend 🛑

```
Backoff #1: "5 ineffective, actual=[1113600,1017600]" → try again
Backoff #2: "5 ineffective" → futility suspend → anti-clamp OFF for session
```

After 2 consecutive backoffs, ASB recognizes the vendor clamp is stronger and **stops wasting sysfs writes**. Reassert interval doubles. Futility resets only on real new session — not on screen toggle or band cross.

#### Prearm (performance only)

If persistent stats show `vendor_clamp` streak ≥ 3 sessions + heavy band → skip first detection delay and enter BURST immediately. Still respects temp/headroom/gap gates.

---

### 🌪️ Storm Shield — Battery Goes Ultra-Light

When battery screen-off session is noisy (wake_cycles ≥ 5, session > 5min), ASB enters **Storm Shield**:

| What changes | Normal | Storm Shield |
|:-------------|:------:|:------------:|
| Thermal reads | Every tick | Every 5th tick (~50s) |
| Tick interval | 5–10s | 10s (deep sleep) |
| Headroom | On/Reduced | **OFF** |
| Anti-clamp | Per profile | **OFF** |
| Self-tune | Active | **SKIP** |
| Learning (pstats) | Active | **SKIP** |

#### Smart exit

If wake noise stops growing for ~10 minutes, shield **auto-exits** and normal battery behavior resumes.

```
storm_shield: activated (wakes=7 age=312s), ultra-light mode
  ... 10 min of calm ...
storm_shield: exited (noise calmed for ~10min, wakes=7)
```

---

### 👤 User-Switch Quarantine

When Android user changes (clone, guest, secondary profile), ASB detects this and enters a **90-second quarantine**.

**Detection:** Screen ON check + periodic poll (~30s). Catches both unlock-triggered and in-UI user switches.

**During quarantine:** anti-clamp OFF, headroom OFF, learning SKIP, self-tune SKIP. Session history still written for diagnostics.

---

### 🌡️ Thermal Debt

If a performance session ends hot (≥ 75°C) and a new one starts within 120 seconds, `ac_budget` is **halved**. Prevents immediate re-launch of full burst into a still-warm device.

---

### 🔍 Hard Clamp Classification

V31 adds three vendor_clamp detection paths (V30 had one):

| Path | Condition | Catches |
|:-----|:----------|:--------|
| High-headroom | `cap_eff<40, hr_min≥80, unreachable≥5` | Clean clamp, device cold |
| Low-headroom | `cap_eff<55, (b50≥15 or hr_min<50)` | Clamp + headroom pressure |
| **Unreachable-dominant** ✨ | `cap_eff<40, unreachable≥10, b50<10` | Massive gap, moderate headroom |

---

### 📡 Device Capability Detection

Probed **once** at startup:

```
caps: msm=1 hr=1 thermal_cpu=1 thermal_skin=1 gpu=1 uclamp=0
```

| Capability | What it checks |
|:-----------|:--------------|
| `has_msm_perf` | msm_performance writable |
| `has_headroom` | cpu_max_freq readable |
| `has_thermal_cpu` | CPU thermal zone found |
| `has_thermal_skin` | Skin thermal zone found |
| `has_gpu_load` | GPU load sysfs readable |
| `has_uclamp` | uclamp.max available |

---

### 📊 Sensor Budget

| Profile | Budget | Duration at 5s ticks |
|:--------|:------:|:-------------------:|
| Performance | 120 reads | ~10 minutes |
| Balanced | 60 reads | ~5 minutes |
| Battery | 0 | Headroom never read |

When exhausted, headroom stops but thermal continues. Resets on plan rebuild.

---

### 🩺 Doctor Improvements

| Before (V30) | After (V31) |
|:-------------|:------------|
| Checks `$MODDIR/asb_governor` | Checks `$MODDIR/bin/asb` (real path) |
| `pidof asb_governor` | PID file + `pidof asb` |
| Binary missing → ❌ FAIL | Binary missing → ⚠️ WARN (shell fallback) |
| Source tree → UNHEALTHY | Source tree → `SOURCE_TREE` status |
| No plan visibility | Shows `quarantine=`, `plan_class=` |

---

### 🐛 Bug Fixes

| Bug | Fix |
|:----|:----|
| `pstats_performance.json` never created | Save pstats before profile_change reset |
| `idle_boundary` fires every ~70s after first | Reset `last_transition` in session reset |
| Futility cleared on brief load dip | Light reset preserves `g_ac_futile` |
| Storm Shield counters leak between activations | `storm_shield_reset()` helper |
| `INTENT_BENCHMARK` build error | Moved defines above `session_plan_build()` |
| Manifest governor hash empty | Fixed path to `$MODPATH/bin/asb` |

---

### 📦 Packaging

- `customize.sh`: Removed stale template references
- `uninstall.sh`: Removed legacy cleanup, added `/dev/.asb` wipe
- `common/install.sh`: Fixed governor hash path

---

### 📈 By The Numbers

| Metric | V30 | V31 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 2,159 | 2,664 | +505 |
| Plan fields | 0 | 12 | New subsystem |
| Anti-clamp budget | ∞ | 6 windows | Bounded |
| Limiter paths | 4 | 6 | +2 |
| Session classes | 0 | 7 | New taxonomy |
| New subsystems | — | 4 | Plan, Shield, Quarantine, Caps |

---

### 🏛️ Architecture

```
V30: tick → check profile → check screen → check state → decide → act
V31: event → build plan → tick → read plan → act
```

The hot path went from **12+ conditional branches per tick** to **3 plan field reads**.

---

> **V31 is not a bigger module. It's a smarter one.**
> Less noise. Less fighting. More knowing when to be quiet.
