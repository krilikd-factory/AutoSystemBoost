# 🚀 AutoSystemBoost — Changelog

---

## V27 — 🧠 Adaptive Intelligence & Thermal Awareness

> **V26 = governor learns in real time.**
> **V27 = governor understands *what it's doing*, *why it failed*, and *how to start smarter next time*.**

**Benchmark impact:** (+16%)
**Battery impact:** 8-hour night session — 4% drain (0.5%/h), 1 wake cycle

---

### 🔥 Core Architecture: Performance Auto-Degrade Fix

The most critical fix in V27. In V26, `profile:performance` forced `highload_mode=1` (burst), which **completely blocked** all three auto-degrade paths — they were gated by `highload_mode != 3`. Device was trapped in burst→thermal→SUSTAINED→burst cycle with no escape.

| What | V26 | V27 |
|:-----|:---:|:---:|
| Performance highload_mode | `1` (burst) — degrade blocked | `3` (auto) — degrade enabled |
| Auto-degrade for performance | ❌ Dead code | ✅ All 3 paths active |
| Path 2 (thermal pressure) | Blocked by `gaming_entries < 2` | Independent — fires with 0 gaming entries |
| Path 2 time gate | 120s minimum | **90s** — catches thermal wall faster |
| `auto_degrade_thermal_pct` | 45% | **35%** — earlier detection |
| `apply_stable_override()` | Didn't set `highload_mode` | Sets `highload_mode=2` — stops re-checking |

---

### 🌡️ Softer Burst-Start (Thermal Cycling Prevention)

V26 burst parameters caused rapid thermal cycling: exit→10s→re-enter→exit→10s→re-enter. V27 gives the device thermal breathing room.

| Parameter | V26 Burst | V27 Burst |
|:----------|:---------:|:---------:|
| `gaming_retry_cooldown_s` | 10 | **20** |
| `sustained_reentry_cooldown_s` | 10 | **20** |
| `sustained_level` | 0.85 | **0.82** |
| `gaming_retry_temp_max` | 50°C | **47°C** |

---

### 📊 Per-Profile Persistent Stats

V26 had one global `session_stats.json` — battery sessions with avg_temp=43°C diluted performance avg_temp=105°C, making history useless.

V27 splits into three independent files:

| File | Tracks |
|:-----|:-------|
| `pstats_battery.json` | Battery-only EMA: temp, efficiency, degrade, hot_fail |
| `pstats_balanced.json` | Balanced-only EMA |
| `pstats_performance.json` | Performance-only EMA + hot_fail_count |

Legacy `session_stats.json` still maintained for backward compatibility with Python tools.

---

### 🧠 History-Aware Performance Startup

When switching to performance, governor checks per-profile history before deciding burst vs stable:

| Condition | Action |
|:----------|:-------|
| `avg_temp ≥ 95°C` AND `avg_eff < 60%` (3+ sessions) | Skip burst → start **stable** |
| `degrade_count > 50%` of sessions | Skip burst → start **stable** |
| `hot_fail_count ≥ 2` | Skip burst → start **stable** |
| Otherwise | Normal auto-burst |

This means performance becomes **opportunistic**: burst when device is cool and history is favorable, stable-first when thermal wall is historically inevitable.

---

### 🔥 hot_fail_count — Thermal Wall Memory

New metric separate from `degrade_count`:

- **degrade_count** = "governor logic succeeded in saving the session"
- **hot_fail_count** = "device hit thermal wall regardless"

| Trigger | Condition |
|:--------|:----------|
| Increment | `max_temp ≥ 100°C` AND (`sus_pct ≥ 50%` OR (`t2s > 0` AND `t2s ≤ 90s`)) |
| Reason logged | `temp+sus`, `temp+t2s`, or `temp+sus+t2s` |
| Soft decay | Good performance session (temp < 90°C, no degrade) → count-- |

Soft aging also applies to `degrade_count` — old failures don't permanently lock stable-first.

---

### 🎯 Session Intent Classifier

Governor classifies each session after 90s of data or first thermal event:

| Intent | Conditions | Effect |
|:-------|:-----------|:-------|
| `benchmark` | GAMING + thermal + short session (<5min) | Immediate degrade to stable |
| `long_game` | GAMING + session ≥ 5min | `sustained_reentry_cooldown` → 30s |
| `sleep_idle` | DEEP_IDLE + wake ≤ 1 + age ≥ 30min + deep > 50% | Correct battery classification |
| `idle` | Battery + deep_idle > 60s | Normal idle behavior |
| `mixed` | Everything else | Default path |

Intent is stored in session history (`"intent":"benchmark"`) and exported to state file for WebUI/tools.

---

### ⏱️ Live State Time Accounting Fix (`fsm_flush_state_time`)

**The bug:** FSM accumulated state time only on state *transitions*. Device sleeping 8 hours in DEEP_IDLE without transitioning → `bat_deep=30s` instead of `28800s`. All battery metrics were wrong.

**The fix:** New `fsm_flush_state_time()` function accumulates time in current state without requiring a transition. Called at 6 points:

| Call Site | Why |
|:----------|:----|
| Before `profile_change` save | Correct profile attribution |
| Before `new_session` save | Complete previous session data |
| Before `manual_end` save | Clean end-session |
| Before `idle_boundary` check | Accurate DEEP_IDLE time for threshold |
| Before shutdown summary | Correct final log |
| Before shutdown save | Complete persistent stats |

---

### ⚡ Performance Profile Thermal Optimization

V26 `performance.sh` generated heat between benchmark phases through high CPU floors and aggressive boosting. V27 saves thermal budget for when it matters.

| Parameter | V26 | V27 | Why |
|:----------|:---:|:---:|:----|
| `CPU_MIN_LITTLE` | 2,112,000 | **1,497,600** | 2.1 GHz floor burns heat at idle; scheduler ramps in 300µs anyway |
| `CPU_MIN_BIG` | 2,438,400 | **1,881,600** | Same — high floor = wasted thermal budget |
| `WALT_ED_BOOST` | 64 | **55** | 64% pushed cores to max on any activity |
| `WALT_BUSY_HYST` | 32ms | **12ms** | 32ms held frequency after load dropped |
| `WALT_TOPAPP_WEIGHT` | 170 | **190** | Better top-app scheduling priority |
| `WALT_BOOST_MIN_UTIL` | 12 | **32** | Higher utilization before boost kicks in |
| `SCHED_DOWN_RATE` | 1200 | **1000** | Faster frequency ramp-down |
| `SCHED_HISPEED_LOAD` | 60 | **55** | Earlier hispeed engagement |
| `GPU_MIN_PCT` | 25% | **10%** | GPU floor 25% heated chip during CPU/MEM/UX tests |

---

### 🔋 Battery Profile Tuning

| Parameter | V26 | V27 | Impact |
|:----------|:---:|:---:|:-------|
| `bat_heavy_load_enter` | 20.0 | **4.0** | V26 threshold was so high battery *never* entered HEAVY |
| `bat_moderate_load_enter` | 12.0 | **3.0** | Allows proper idle/moderate separation |
| `SCHED_RATE` | 8000 | **12000** | Less aggressive scheduler |
| `SCHED_DOWN_RATE` | 12000 | **20000** | Faster return to low frequency |
| `WALT_TOPAPP_WEIGHT` | 65 | **60** | Less boost for foreground tasks |
| `UCL_FG_MAX` | 12% | **10%** | Tighter foreground uclamp |
| `UCL_TOP_MAX` | 18% | **15%** | Tighter top-app uclamp |
| `GPU_MAX_PCT` | 22% | **18%** | Lower GPU ceiling for battery |

---

### 🔧 Self-Tune Improvements

| Rule | V26 | V27 |
|:-----|:----|:----|
| Efficiency force-stable | `< 30%` | **`< 50%`** — real data showed 45% already futile |
| Thermal force-stable (new) | — | `max_temp ≥ 100°C` AND `sus_pct ≥ 40%` |
| `degrade_at_age` tracking (new) | — | Seconds from session start to auto-degrade |

---

### 🐍 Python Tools Upgrade

**`asb_session_report.py`:**

| Feature | Description |
|:--------|:------------|
| **Intent** column | Shows session type in detail table |
| **Intent distribution** | Summary shows `benchmark=2, mixed=3` counts |
| **Reason** column (battery) | `failed_to_settle`, `failed_by_screen_on`, `failed_by_wake_noise`, `moderate_dominated`, `incomplete_telemetry` |
| **Trust** column (battery) | `clean` / `partial` / `dirty` per session |
| **🔍 Data Quality** section | Counts clean/partial/dirty, marks partial as "excluded from learning" |
| **Degrade speed** KPI | avg/min/max `deg_age` in Summary |
| **sleep_idle** handling | Governor intent → automatic "screen-off efficient" classification |
| **Telemetry incomplete** detection | dur > 1h, bat_deep < 120s, idle_q = -1 → flagged in anomalies |
| **Long uninterrupted deep** | dur ≥ 2h, wake/h ≤ 1, deep ≥ 70% → "screen-off efficient" |
| **Benchmark recommendation** | "burst бесполезен для бенчмарков" when all benchmark sessions degraded |

**`asb_compare_sessions.py`:**

| Feature | Description |
|:--------|:------------|
| **Intent** column | Added to Session Detail table |
| **`deg_age`** in JSONL loader | Available for analysis |
| **Benchmark+degraded** recommendation | "stable is optimal for this workload" |

**`asb_analyze.py`:**

| Feature | Description |
|:--------|:------------|
| **Intent** parsing | Reads `intent: classified as X` from governor.log |
| **Intent action** parsing | Reads `intent: benchmark+thermal` actions |
| **Intent display** | Shows intent in single-session summary |

---

### 📤 State/Status Export

New fields exported to `/dev/.asb/state` and status JSON for WebUI and debug:

| Field | Source | Description |
|:------|:-------|:------------|
| `intent` | FSM | Current session intent (benchmark/sleep_idle/etc) |
| `hot_fail` | Per-profile pstats | Thermal wall hit count |
| `degrade_at_age` | FSM | Seconds from start to degrade (0 if not degraded) |
| `profile_deg` | Per-profile pstats | Profile-specific degrade count |

---

### 📝 Session History v4 Schema

| New Field | Type | Description |
|:----------|:-----|:------------|
| `"intent"` | string | Session intent classification |
| `"deg_age"` | long | Seconds from session start to auto-degrade |

Backward compatible: Python tools use `.get()` — old v2/v3 records work without changes.

---

### 🐛 Bug Fixes

| Bug | Impact | Fix |
|:----|:-------|:----|
| **Auto-degrade dead for performance** | burst→thermal→SUSTAINED loop with no escape | `highload_mode=3` (auto) instead of `1` (burst) |
| **Path 2 blocked by gaming_entries** | Thermal-only scenarios never degraded | Path 2 now independent of gaming data |
| **`apply_stable_override` didn't set mode** | After degrade, mode stayed `3`, auto-degrade re-checked every tick | Sets `highload_mode=2` |
| **Battery clear missed auto mode** | `performance→battery` didn't reset `highload_mode=3` | Checks `== 1 \|\| == 3` |
| **`bat_time_deep_idle_sec` not accumulated** | 8-hour DEEP_IDLE showed 30s — all battery metrics wrong | `fsm_flush_state_time()` at all save points |
| **Intent benchmark no-op** | Classified benchmark but did nothing | Now calls `apply_stable_override()` immediately |
| **Display paths missing "auto"** | State file showed "default" for auto mode | All 5+ display paths now show "auto" |
| **`hot_fail` t2s=0 false positive** | Sessions without SUSTAINED triggered hot_fail (0 ≤ 90) | Added `t2s > 0` guard |

---

### ✅ V27 Summary

| Feature | Status |
|:--------|:------:|
| Performance auto-degrade fixed (3 independent paths) | ✅ |
| Softer burst-start (reduced thermal cycling) | ✅ |
| Per-profile persistent stats (3 separate files) | ✅ |
| History-aware performance startup (burst vs stable) | ✅ |
| hot_fail_count with reason logging | ✅ |
| Soft aging for hot_fail and degrade counts | ✅ |
| Session intent classifier (6 intents) | ✅ |
| fsm_flush_state_time (DEEP_IDLE accounting fix) | ✅ |
| Performance profile thermal optimization (9 params) | ✅ |
| Battery profile tuning (8 params) | ✅ |
| Self-tune: efficiency 30→50%, max_temp trigger | ✅ |
| Python: trust flag, fail_reason, intent, data quality | ✅ |
| State/status export: intent, hot_fail, deg_age | ✅ |
| Session history v4 schema | ✅ |
| 8 bug fixes | ✅ |

**V27 is where ASB stops being reactive and becomes predictive — it remembers what went wrong, classifies what's happening now, and makes smarter decisions before the thermal wall hits.**

---
