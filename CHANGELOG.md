# 🚀 AutoSystemBoost V23 MAJOR RELEASE

Compared to V22 | Date: 2026-03-15

---

# 🌟 What Changed in V23

`ASB-V23` is not a maintenance patch on top of V22.  
It is the release where AutoSystemBoost evolves from a session-aware adaptive governor into a **session-intelligent runtime with persistent memory, recovery discipline, and a modular architecture**.

**V22 = first session-intelligent high-load governor release**  
**V23 = first self-learning, recovery-aware, architecturally clean release**

---

# 🧠 Session Intelligence — Time-to-First Metrics

V23 answers the question V22 could not: **how fast does this session actually break down?**

| Metric | V22 | V23 |
|--------|-----|-----|
| Time to first SUSTAINED | ❌ | ✅ `ses_t2s` — seconds from reset to first SUSTAINED |
| Time to first thermal collapse | ❌ | ✅ `ses_t2thermal` — seconds to first thermal-triggered SUSTAINED |
| SUSTAINED quality score | ❌ | ✅ `ses_efficiency` — 0–100 score per session |
| Thermal collapse counter | ❌ | ✅ `ses_recovery` — counts how many times thermal collapsed |

### What `ses_efficiency` measures

```
efficiency = 100 - gap_penalty - temp_penalty
  gap_penalty  = avg_gap_p0 / 15000  (capped at 50)
  temp_penalty = (max_temp - 55) × 2  (capped at 50)
```

- **100/100** = SUSTAINED at moderate temperature with small cap gap (useful throttle)
- **~50/100** = deep thermal wall, heavily throttled
- **< 30/100** = system was too hot and too throttled to be effective

**Logged on every SUSTAINED exit:**
```
exit_sustained: temp_dropped t=53°C → HEAVY cooldown=30s efficiency=87/100
```

---

# 💾 Persistent Session Memory

V23 introduces the first **cross-session memory** in ASB history.

| | V22 | V23 |
|-|-----|-----|
| Session history | Resets on every restart | **Persists across runs** |
| History file | None | `/dev/.asb/session_stats.json` |
| Rolling average | None | **EMA across last 10 sessions** |

### What is stored

```json
{"count":5,"t2s":95.0,"t2th":95.0,"temp":68.0,"gap":0.0,"eff":95.0}
```

| Field | Meaning |
|-------|---------|
| `count` | Number of sessions accumulated |
| `t2s` | Rolling avg seconds to first SUSTAINED |
| `t2th` | Rolling avg seconds to first thermal collapse |
| `temp` | Rolling avg peak temperature °C |
| `gap` | Rolling avg GAMING cap gap kHz |
| `eff` | Rolling avg sustained efficiency score |

**Shown in diag log at every governor startup:**
```
persistent stats: sessions=5 avg_t2s=95s avg_temp=68°C avg_gap=0 avg_eff=95
```

**Visible in `asb status`:**
```
hist_sessions, hist_t2s, hist_temp, hist_gap, hist_eff
```

---

# 🔁 Recovery Discipline

V22 had cooling and retry cooldowns. V23 adds **recovery intelligence**: after the chip has already collapsed twice in the same session, GAMING retry becomes more conservative automatically.

| Condition | V22 | V23 |
|-----------|-----|-----|
| After 1st thermal collapse | retry after cooldown | same |
| After 2nd+ thermal collapse | same retry threshold | **temp_max reduced by 5°C** |

```c
/* Recovery discipline: ses_recovery_count >= 2 → stricter temp gate */
if (temp_max > 0 && fsm->ses_recovery_count >= 2)
    temp_max -= 5;
```

This means: if the session has already shown that the chip overheats under GAMING load, ASB stops trying to re-enter GAMING until the chip is 5°C cooler than normal. No config needed — fires automatically.

---

# 🔋 Battery Branch — Active Improvements

V22 introduced the battery governor mode. V23 makes it smarter based on real device data.

### Problem observed in testing

On screen wake from DEEP_IDLE, load spikes to 12–21 immediately (Android system overhead). With V22's `heavy_load_enter=2.0`, the governor jumped to HEAVY within 4 seconds of every screen-on event, defeating the purpose of the battery profile.

### Fix: `bat_heavy_load_enter`

| | V22 | V23 |
|-|-----|-----|
| HEAVY threshold in battery | `2.0` (global) | **`4.0` (battery-specific)** |
| Screen wake behavior | HEAVY in 4s | Stays in LIGHT_IDLE through wake spike |
| Config key | ❌ | `bat_heavy_load_enter=4.0` |

### Battery params now wired (were config-only in V22)

| Parameter | V22 | V23 |
|-----------|-----|-----|
| `bat_fast_idle_s=15` | Stored in config, unused | **Active: LIGHT_IDLE → DEEP_IDLE in 15s** |
| `bat_light_idle_gpu=10` | Stored in config, unused | **Active: GPU capped at 10% in LIGHT_IDLE** |

Both fields were declared in V22 but never connected to the FSM. Now wired.

---

# 🎯 Profile-Aware `highload_mode`

V22 required manually setting `highload_mode` in `governor.conf`.  
V23 ties it to the active profile automatically.

| Profile switch | V22 | V23 |
|----------------|-----|-----|
| → `performance` | No change to highload_mode | **burst applied automatically** |
| → `battery` | No change to highload_mode | **burst cleared if active** |
| → `balanced` | No change | No change (respects config) |

**What burst means for performance profile:**
```
gaming_gap_ticks          = 3    (was 4)
gaming_retry_cooldown_s   = 20   (was 30)
gaming_retry_temp_max     = 50
sustained_level           = 0.85 (was 0.80)
sustained_reentry_cooldown_s = 10 (was 20)
```

**Logged on profile switch:**
```
profile:performance → highload burst applied
profile:battery → highload burst cleared
```

---

# 🏗 Architecture — Modular Shell Layer

V22 had a monolithic `service.sh` (1463 lines) that was the single point of failure for the entire module.

V23 splits it into focused modules:

| File | Role | Lines |
|------|------|-------|
| `service.sh` | Boot orchestrator, sources modules | ~1150 |
| `runtime/asb_utils.sh` | Profile vars, governor lifecycle | 178 |
| `runtime/asb_reconcile.sh` | Profile drift correction loop | 110 |
| `runtime/asb_watchdog.sh` | Governor process watchdog | 35 |

### Why `runtime/` not `common/`

MMT installer (`functions.sh`) runs `rm -rf $MODPATH/common` after installation. Files in `common/` are for install-time only and are deleted before `service.sh` ever runs. V23 places persistent runtime files in `runtime/` which survives the install cleanup.

### Watchdog threshold fix

| | V22 | V23 |
|-|-----|-----|
| Stale state threshold | **90s** (caused 3–4 restarts/hour) | **240s** |
| Root cause | DEEP_IDLE never writes state unless caps change | Keepalive write every 60s |

---

# 🔊 Audio Fix — Spatial Audio / 3D Audio

OnePlus 3D Audio (Pространственное аудио) buttons were non-functional in V22.

| Property | V22 | V23 |
|----------|-----|-----|
| `ro.audio.spatializer_enabled` | `false` | **`true`** |
| `ro.audio.spatializer_binaural_enabled_default` | `false` | **`true`** |
| `ro.audio.spatializer_transaural_enabled_default` | `false` | **`true`** |

All three modes now work: **Fixed**, **Head tracking**, and **Off**.

---

# ⚙️ Profile Tuning (V22 → V23)

### `performance.sh`

| Parameter | V22 | V23 |
|-----------|-----|-----|
| `SCHED_RATE` | 1000 | **800** |
| `SCHED_UP_RATE` | 400 | **300** |
| `SCHED_DOWN_RATE` | 1500 | **1200** |
| `SCHED_HISPEED_LOAD` | 65 | **60** |

Faster CPU ramp-up response for performance workloads.

### `balanced.sh`

| Parameter | V22 | V23 |
|-----------|-----|-----|
| `WALT_TOPAPP_WEIGHT` | 105 | **110** |
| `WALT_BOOST_MIN_UTIL` | 51 | **48** |
| `SCHED_RATE` | 3000 | **2500** |
| `SCHED_UP_RATE` | 1200 | **1000** |
| `SCHED_DOWN_RATE` | 4000 | **3500** |
| `SCHED_HISPEED_LOAD` | — | **85** |
| `GPU_IDLE_TIMER` | — | **64** |

Improved foreground app responsiveness, smoother GPU idle transitions.

### `battery.sh`

| Parameter | V22 | V23 |
|-----------|-----|-----|
| `WALT_TOPAPP_WEIGHT` | 60 | **65** |
| `WALT_BOOST_MIN_UTIL` | 140 | **150** |
| `UCL_TOP_MAX` | 16 | **18** |

Slightly higher foreground responsiveness in battery mode without sacrificing idle efficiency.

---

# 📊 New Session Telemetry Fields (V23)

Full list of new fields in `asb status` and `cat /dev/.asb/state`:

| Field | Description |
|-------|-------------|
| `ses_t2s` | Seconds from session start to first SUSTAINED |
| `ses_t2thermal` | Seconds from session start to first thermal SUSTAINED |
| `ses_efficiency` | SUSTAINED quality score 0–100 (last or worst episode) |
| `ses_recovery` | Number of thermal collapses this session |
| `hist_sessions` | Sessions accumulated in persistent stats |
| `hist_t2s` | Rolling avg time-to-first-SUSTAINED (seconds) |
| `hist_temp` | Rolling avg peak temperature (°C) |
| `hist_gap` | Rolling avg GAMING cap gap (kHz) |
| `hist_eff` | Rolling avg sustained efficiency score |

---

# ⚙️ New `governor.conf` Parameters (V23)

```ini
bat_heavy_load_enter=4.0    # battery: require load>4.0 for HEAVY (global default is 2.0)
```

All other V22 parameters remain unchanged and compatible.

---

# 🛠 Bug Fixes

| Bug | Impact | Fix |
|-----|--------|-----|
| `bat_fast_idle_s` and `bat_light_idle_gpu` were dead config fields | Battery LIGHT_IDLE had no GPU cap, no fast idle | Wired into FSM interpolation |
| `bat_deep_idle` counter always 0 | Battery telemetry useless | `fsm_profile_is_battery` not set on socket-initiated profile switch — fixed |
| `runtime/` files deleted by installer | governor crashed on boot (common/ wiped) | Moved to `runtime/` which survives MMT cleanup |
| Watchdog killed governor every 5–16 min during DEEP_IDLE | 3–4 unnecessary restarts per hour | State keepalive write every 60s |
| Watchdog threshold 90s too aggressive | Killed governor during normal DEEP_IDLE | Threshold raised to 240s |
| Spatial audio buttons non-functional | OnePlus 3D Audio settings had no effect | Three `ro.audio.spatializer_*` props set to `true` |

---

# ✅ V23 Summary

✔ **Session intelligence** — `ses_t2s`, `ses_t2thermal`, `ses_efficiency`, `ses_recovery`  
✔ **Persistent session memory** — rolling EMA across 10 sessions in `/dev/.asb/session_stats.json`  
✔ **Recovery discipline** — stricter GAMING retry after 2+ thermal collapses  
✔ **Battery intelligence** — `bat_heavy_load_enter=4.0` prevents spurious HEAVY on screen wake  
✔ **`bat_fast_idle_s` and `bat_light_idle_gpu` now active** — were config-only in V22  
✔ **Profile-aware highload_mode** — burst auto-applied on `profile:performance`  
✔ **Modular shell architecture** — `runtime/` layer, service.sh -313 lines  
✔ **Watchdog stability** — 90s → 240s threshold + 60s keepalive  
✔ **Spatial audio fix** — OnePlus 3D Audio fully functional  
✔ **Profile tuning** — all three profiles refined from real device data  

**V23 makes ASB remember what happened, understand why it happened, and behave differently next time.**

---
