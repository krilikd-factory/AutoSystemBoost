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

# 🚀 AutoSystemBoost V22 MAJOR RELEASE

Compared to V21 | Date: 2026-03-14

---

# 🌟 What Changed in V22

`ASB-V22` is not a maintenance patch on top of V21.  
It is the release where AutoSystemBoost evolves from a working native governor into a **session-aware adaptive runtime** with a fundamentally smarter high-load engine.

**V21 = first native adaptive governor release**  
**V22 = first session-intelligent high-load governor release**

---

# 🧠 Session-Aware High-Load Engine

| Area | V21 | V22 |
|------|-----|-----|
| SUSTAINED state | Basic thermal-reactive | **Gap-aware + session-intelligent** |
| High-load strategy | Fixed behavior | **Configurable burst / stable / auto** |
| Session telemetry | None | **Full counters, timings, gap tracking** |
| Thermal sensor | Per-core hotspot (95–100°C) | **Cluster-level cpullc (55–70°C)** |
| Battery governor | Generic FSM | **Dedicated battery mode + GAMING suppression** |
| Auto degrade | None | **Burst → stable by gap or thermal ratio** |

---

# ⚙️ SUSTAINED State — Full Evolution

### Gap-aware entry

| Trigger | V21 | V22 |
|---------|-----|-----|
| Thermal throttle ≥ 65°C | ✅ | ✅ |
| GAMING caps unreachable (gap > 1500 MHz for 8s) | ❌ | ✅ **new** |

### Hysteresis and cycling prevention

| Feature | V21 | V22 |
|---------|-----|-----|
| `sustained_temp_exit=55` — exit hysteresis | ❌ | ✅ |
| `no_longer_heavy` exit obeys temp threshold | ❌ (bypassed) | ✅ fixed |
| `sustained_reentry_cooldown_s=20` | ❌ | ✅ |
| `gaming_retry_cooldown_s=30` | ❌ | ✅ |
| `gaming_retry_temp_max=50` — temperature gate | ❌ | ✅ |

### Result
✅ Stable SUSTAINED episodes instead of rapid cycling  
✅ GAMING entry only when thermally viable  
✅ `cap_gap_p0/p1` visible in `asb status` — shows real throttle depth  

---

# 📊 Session Telemetry

New in `asb status` and `cat /dev/.asb/state`:

| Counter | Description |
|---------|-------------|
| `ses_gaming` | GAMING entries this session |
| `ses_sustained` | SUSTAINED entries this session |
| `ses_thermal` / `ses_unreachable` | Thermal vs gap-triggered SUSTAINED |
| `ses_t_heavy` / `ses_t_gaming` / `ses_t_sustained` | Time in each state (seconds) |
| `ses_avg_gap_p0` | Average GAMING cap gap (kHz) |
| `ses_max_temp` | Peak temperature this session (°C) |
| `ses_auto_degraded` | Whether auto mode degraded burst → stable |
| `bat_deep_idle` / `bat_light_idle` | Deep/light idle time in battery mode |
| `bat_wake_cycles` | Wake-from-deep-idle count |

Reset: `asb reset-stats`

---

# 🎯 Adaptive High-Load Strategy (`highload_mode`)

| Mode | Behavior | Best for |
|------|----------|----------|
| `default` | Parameters from config | Manual tuning |
| `burst` | Aggressive retry, `sustained_level=0.85`, short cooldowns | Benchmarks |
| `stable` | Conservative retry, `sustained_level=0.78`, long cooldowns | Long gaming |
| `auto` | Starts as burst, degrades to stable on session data | All-purpose |

**Auto degrade fires when either condition is met:**
- `avg_gap_p0 > 800 MHz` AND `sus_entries ≥ 4 × gaming_entries`
- `time_in_sustained > 60%` of active time (over 120s minimum)

---

# 🌡️ Thermal Sensor Fix — Critical for SD8 Elite

| | V21 | V22 |
|--|-----|-----|
| Sensor | Per-core hotspot `cpu-1-1` | **Cluster average `cpullc-0-0`** |
| Typical load reading | 95–100°C (false) | **55–70°C (accurate)** |
| Impact | Premature SUSTAINED, instability | **Correct SUSTAINED timing** |

---

# 🔋 Battery Profile — Dedicated Governor Mode

| Feature | V21 | V22 |
|---------|-----|-----|
| GAMING suppression | None | **`bat_suppress_gaming=1` — GAMING blocked** |
| Fast deep idle | None | **`bat_fast_idle_s=15`** |
| GPU cap in light idle | None | **`bat_light_idle_gpu=10` (10% GPU)** |
| Battery telemetry | None | **3 new counters** |

---

# 🛠 Stability Fixes

| Fix | Impact |
|-----|--------|
| Watchdog 90s → 240s | Eliminates spurious governor restarts during screen-off |
| mA guard removed from GAMING | Noisy mA sensor no longer blocks GAMING at gpu=99% |
| SUSTAINED hysteresis direction fix | `no_longer_heavy` exit now correctly blocked by temp |
| Duplicate `fsm_session_reset` removed | Clean reload behavior |
| `highload_mode=auto` display fix | Was showing `default` in diag |

---

# ⚙️ New governor.conf Parameters (V22)

```ini
sustained_temp_exit=55          # exit hysteresis °C
gaming_retry_cooldown_s=30      # cooldown before GAMING retry
gaming_retry_temp_max=50        # temperature gate for retry
sustained_reentry_cooldown_s=20 # min interval between SUSTAINED episodes
gaming_gap_thresh=1500000       # gap threshold for gap-aware entry (kHz)
gaming_gap_ticks=4              # ticks above threshold to trigger
highload_mode=default           # burst / stable / auto / default
auto_degrade_gap_thresh=800000  # auto degrade gap threshold (kHz)
auto_degrade_sus_ratio=4        # auto degrade sus/gaming ratio
auto_degrade_thermal_pct=60     # auto degrade time-in-SUSTAINED %
bat_fast_idle_s=15              # fast deep idle in battery mode
bat_light_idle_gpu=10           # GPU % cap in LIGHT_IDLE battery mode
bat_suppress_gaming=1           # block GAMING in battery mode
```

---

# 📦 Developer Tools

`tools/asb_analyze.py` — Python session log analyzer:

```bash
python3 asb_analyze.py session1.txt session2.txt
```

Outputs: state distribution, SUSTAINED episodes, gap stats, thermal escalation rate,  
cycling detection, and a comparative table across sessions.

---

# ✅ V22 Summary

✔ **gap-aware SUSTAINED** — practical mode when GAMING caps are unreachable  
✔ **session telemetry** — 15 counters across all high-load states  
✔ **adaptive `highload_mode`** — burst / stable / auto  
✔ **thermal sensor fix** — cluster temp, not hotspot, on SD8 Elite  
✔ **battery governor mode** — GAMING blocked, fast deep idle, battery counters  
✔ **SUSTAINED hysteresis** — exit threshold, reentry cooldown, cycling fixed  
✔ **5 structural bugfixes** — watchdog, mA guard, hysteresis direction, degrade display  
✔ **Python log analyzer** — `tools/asb_analyze.py`  

**V22 makes ASB understand what the session is actually doing — not just react to it.**
