# 🚀 AutoSystemBoost V32 — Changelog

---

## V32 — 🧘 Calm Under Clamp

> **V31 taught ASB to recognize vendor clamp and stop fighting.**
> **V32 teaches ASB to stay calm, recover carefully, and spend less in dead windows.**

One principle: **if you already know the fight is lost, stop wasting energy on it.**

---

### 🎯 The Problem V32 Solves

V31 had futility suspend — after 2 backoffs, anti-clamp gives up. But the FSM didn't know. The gap was still huge from vendor clamp, so `gaming_unreachable` kept triggering SUSTAINED entry every few seconds:

```
18:03:41  enter_sustained: gaming_unreachable
18:03:45  exit_sustained: temp_dropped → GAMING cooldown=20s
18:03:59  enter_sustained: gaming_unreachable
  ... 10-20 useless transitions per minute ...
```

V32 eliminates this entirely and builds a complete post-clamp behavior system.

---

### 🔒 Clamp-Stable Hold

New `clamp_hold` field in FSM. When futility triggers, gap-triggered SUSTAINED entry is **blocked**.

| Component | What |
|:----------|:-----|
| Trigger | Futility suspend (2+ backoffs) |
| Effect | Blocks `gaming_unreachable` → SUSTAINED |
| Thermal | Still works (safety preserved) |
| Reset | Session reset only |
| Plan class | Auto-set to `PERF_CLAMPED` |

```
Before: GAMING → SUSTAINED → GAMING → SUSTAINED → ...  (~20/min)
After:  futility → clamp_hold → GAMING stays GAMING  (0 jitter)
```

---

### 🔍 Clamp Recovery Probe

clamp_hold isn't permanent blindness. A periodic probe checks if vendor clamp lifted.

#### Dual-cluster

Reads **both** policy0 AND policy6, uses `max(gap0, gap1)`. Single-cluster probe could miss big-core clamp.

#### Debounced

Requires **2 consecutive good probes** to lift hold. One lucky measurement doesn't count.

```
clamp_probe: gap ok (gap=50kHz/100kHz), need 1 more confirm
  ... 5 min later ...
clamp_probe: vendor clamp lifted (gap=40kHz/90kHz, 2+ good), plan rebuilt
```

#### Negative gap protection

Transient overshoot (`gap = -55kHz`) clamped to 0. No false positives from measurement noise.

#### Economy mode

After 10 minutes of confirmed hold, probe interval doubles:

| Hold duration | Probe interval |
|:-------------|:--------------:|
| 0–10 min | ~5 min (60 ticks) |
| 10+ min | ~10 min (120 ticks) |

If the wall hasn't moved in 10 minutes, stop knocking so often.

---

### 🔒 Hold-Aware Classifier

V31 had 3 vendor_clamp detection paths. V32 adds a 4th:

```c
if (cap_eff < 40 && !thermal_hot && fsm->clamp_hold && b50_pct < 10)
    limiter = "vendor_clamp";  /* futility already confirmed clamp */
```

**Why needed:** clamp_hold suppresses gap-triggered SUSTAINED → `unreachable` stays 0 → old classifier falls to `mixed`. The new path uses the hold flag itself as proof.

| # | Path | Key signal |
|:--|:-----|:-----------|
| 1 | High-headroom | `hr_min≥80, unreachable≥5` |
| 2 | Unreachable-dominant | `unreachable≥10, b50<10` |
| 3 | **Hold-aware** ✨ | `clamp_hold=1, b50<10` |
| 4 | Low-headroom | `b50≥15 or hr_min<50` |

---

### 🌪️ Storm Shield Re-Arm Hysteresis

**Problem from V31 logs:** shield exited after calm period, then re-armed 10 seconds later on the same old `wakes=5`:

```
13:48:47 storm_shield: exited (wakes=5)
13:48:57 storm_shield: activated (wakes=5)  ← same count, no new noise!
```

**Fix:** after smart exit, re-arm requires **3 new wakes** AND **2-minute cooldown**:

```
storm_shield: exited (wakes=5, rearm after 2min+3 new wakes)
  ... old wakes=5 ignored ...
  ... 2min + 3 new wakes later → can re-arm
```

---

### 📊 Session-Latched Telemetry

| Field | What it records |
|:------|:---------------|
| `had_clamp_hold` | Was clamp_hold **ever** set this session? |
| `had_futility` | Was futility **ever** triggered this session? |
| `clamp_hold` | Current live state at session end |

**Why needed:** recovery probe can clear `clamp_hold` mid-session. Without latched flags, postmortem loses the clamp history.

| `had_futility` | `clamp_hold` | Meaning |
|:-:|:-:|:--------|
| 1 | 1 | Clamp held to end |
| 1 | 0 | Was clamped, then recovered |
| 0 | 0 | No clamp confirmed |

Python report now shows 🔒 marker on clamped sessions and futility summary:

```
- 🔒 Futility: 2/5 sessions (hold=2, recovered=0)
```

---

### 📦 system.prop Changes

| Change | Before | After | Why |
|:-------|:------:|:-----:|:----|
| AI Display | `true` | `false` | CPU overhead reduction |
| VSync optimization | — | `true` | Frame pacing, display power |
| Optimize refresh | — | `1` | Display efficiency |
| USB DPL diagnostic | `dpl` | removed | Blocked USB tethering |

---

### 📈 By The Numbers

| Metric | V31 | V32 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 2,664 | 2,744 | +80 |
| FSM fields | 0 clamp | 3 (hold + 2 latched) | New subsystem |
| Vendor clamp paths | 3 | 4 | +hold-aware |
| Probe features | — | dual-cluster, debounced, economy | New |
| Shield re-arm | instant | 2min + 3 wakes | Hysteresis |
| FSM jitter under clamp | ~20/min | ~0 | Eliminated |

---

### 🏛️ V32 Architecture

```
V31: futility → stop fighting → still jitter in FSM → still probe too often
V32: futility → clamp_hold → FSM calm → probe careful → economy after 10min
```

The module now has a complete post-clamp lifecycle:

```
1. Detect clamp (anti-clamp ladder)
2. Confirm futility (2 backoffs)
3. Hold FSM (block gap-triggered SUSTAINED)
4. Classify honestly (hold-aware vendor_clamp)
5. Probe carefully (debounced, dual-cluster)
6. Economize (longer interval after 10min)
7. Record truthfully (session-latched telemetry)
```

---

> **V31 taught the module to stop punching the wall.**
> **V32 taught it to sit down, save energy, and only check the door once in a while.**
