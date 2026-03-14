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

---

# 🚀 AutoSystemBoost V21 MAJOR RELEASE

Compared to V20 | Date: 2026-03-12

---

# 🌟 What Changed in V21

`ASB-V21` moves AutoSystemBoost from a profile-based module into a **native adaptive runtime platform**.

**V20 = strong modern profile release**  
**V21 = first native adaptive governor release**

---

# 🧠 Native Adaptive Governor

| Area | V20 | V21 |
|------|-----|-----|
| Runtime brain | Shell-driven | **Native governor daemon** |
| Control path | Shell profile apply | **Socket-controlled adaptive runtime** |
| State tracking | Implicit | **Explicit FSM (5 states)** |
| Adaptive FSM | No | **Yes** |
| Runtime logs | Basic | **`/dev/.asb/governor.log`** |

### FSM States

- `DEEP_IDLE` — screen off, minimal wakeups
- `LIGHT_IDLE` — screen on, low activity
- `MODERATE` — medium CPU / background
- `HEAVY` — sustained high load
- `GAMING` — GPU ≥ 65%, full performance

---

# 📦 Bundled Governor Binary

| Area | V20 | V21 |
|------|-----|-----|
| Native binary | No | **Yes (`bin/asb`)** |
| Source tree | No | **Yes (`src/`)** |
| Runtime ownership | Shell | **Governor daemon + shell fallback** |

---

# 🔍 Diagnostics

| Feature | V20 | V21 |
|---------|-----|-----|
| State file | No | **`/dev/.asb/state`** |
| Governor log | No | **`/dev/.asb/governor.log`** |
| JSON status | No | **`asb status`** |
| Profile command | File change | **`asb profile:performance`** |

---

# ✅ V21 Summary

✔ native adaptive governor daemon  
✔ explicit 5-state runtime FSM  
✔ socket-based profile control  
✔ bundled binary + source tree  
✔ runtime diagnostics and state visibility  
✔ cleaner shell vs governor role split  
