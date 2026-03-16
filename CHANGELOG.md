# 🚀 AutoSystemBoost — Changelog

---

## V25 — Stability & Real-World Fixes

> **V24 = persistent intelligence, session history, feedback loops.**
> **V25 = battle-tested on a real device for 24 hours. Every bug found — fixed.**

---

### 🔴 Critical Fix: WebUI Profile Switching Broken

`apply_profile.sh` depended on `common/profile_core.sh`, but the MMT installer deletes `common/` after installation. **Every WebUI profile switch failed silently** — the shell worker logged `worker failed: missing profile_core.sh` and exited.

| Component | Fix |
|:----------|:----|
| `common/install.sh` | Copies `profile_core.sh` → `runtime/` before `common/` cleanup |
| `apply_profile.sh` | Searches `runtime/` first, `common/` as fallback |

### 🔴 Critical Fix: Dirty Session History

When switching profiles via WebUI (e.g. performance → battery), session telemetry was **not reset**. Old GAMING/SUSTAINED counters from performance bled into the next battery session. At `idle_boundary`, this contaminated data was written to `session_history.jsonl` — making feedback loops unreliable.

**Real example from logs:**
```
profile=battery, gaming=9, sustained=9, avg_gap=2,369,225
```
9 GAMING entries in battery mode where `bat_suppress_gaming=1` — impossible data.

| Fix | Detail |
|:----|:-------|
| Profile change via socket | Now calls `session_history_append_ex` + `session_end_self_tune` + `fsm_session_reset` |
| New end reason | `"profile_change"` — visible in session history |

### 🟡 Fix: Benchmark Score Regression

`self_tune` lowered `sustained_level` too aggressively: `0.78 → 0.75 → 0.72` over two sessions. At 0.72, SUSTAINED used only 72% of the profile range — CPU got less frequency, but GAMING↔SUSTAINED cycling still generated heat. Result: lower benchmark scores AND higher temperatures.

| Parameter | V24 | V25 |
|:----------|:---:|:---:|
| `sustained_level` step | −0.03 per session | **−0.02** |
| `sustained_level` floor | 0.70 | **0.75** |
| Max possible reduction | 0.78 → 0.70 (−10%) | 0.78 → 0.76 (−3%) |

### 📝 Log Rotation

`governor.log` grew to 2100+ lines in one day (~3–5 MB/month). Now automatically rotated:

| Parameter | Value |
|:----------|:------|
| Max size | **200 KB** |
| Rotation | Current → `governor.log.1`, new file started |
| Max disk usage | ~400 KB (current + one backup) |
| Check frequency | Every 200 log writes |

### ✅ V25 Summary

| Fix | Impact | Status |
|:----|:-------|:------:|
| `profile_core.sh` missing after install | WebUI profile switching completely broken | ✅ Fixed |
| Session telemetry not reset on profile change | History contaminated with wrong profile data | ✅ Fixed |
| `sustained_level` self-tune too aggressive | Benchmark regression, no thermal benefit | ✅ Fixed |
| Log rotation | Unbounded log growth | ✅ Fixed |

**V25 is the first release validated against 24 hours of real device usage data — including sleep, daily use, benchmarks, and Call of Duty gaming sessions.**

---
---

## V24 — Persistent Intelligence

> **V23 = first session-aware governor with memory.**
> **V24 = first governor that learns from its own past and changes behavior.**

---

### 🧠 Core: Persistent Decision Layer

V24 adds three feedback loops that read session history at startup and adjust governor behavior based on accumulated patterns. This is the transition from **reactive governor** to **adaptive system with memory**.

#### Battery Feedback Loop #1 — Idle Discipline

Governor reads average `bat_ttd` (time-to-first-DEEP_IDLE) from past battery sessions:

| Historical Pattern | Action | Result |
|:-------------------|:-------|:-------|
| `avg(bat_ttd)` > 60s | `bat_fast_idle_s` 15 → 10 | Faster sleep entry |
| `avg(bat_ttd)` > 30s | `bat_fast_idle_s` 15 → 12 | Moderately faster |
| `bat_fast_idle_s` < 5 | Clamped to floor **5s** | Safety guard |

#### Battery Feedback Loop #2 — MODERATE Domination

If battery sessions historically spend >60% of tracked idle time in MODERATE (instead of DEEP/LIGHT_IDLE), wake discipline is too loose:

```
feedback: battery MODERATE=68% of idle time → bat_fast_idle 12→8
```

#### Auto History-Aware Startup

If >50% of accumulated sessions degraded from burst to stable, `highload_mode=auto` starts directly as stable — skipping the futile burst phase:

```
feedback: 6/10 sessions degraded → auto starting as stable
```

---

### 📊 Session History (`session_history.jsonl`)

Full session summaries stored as JSON Lines. Last 10 sessions, survives reboots.

Each entry contains **24 fields** with schema version:

```json
{"v":1,"ts":"2026-03-15 14:30","profile":"performance","mode":"auto","end":"screen_off",
 "gaming":3,"sustained":2,"thermal":1,"unreachable":1,
 "t_heavy":180,"t_gaming":95,"t_sustained":45,
 "avg_gap":420000,"max_temp":67,"degraded":0,
 "t2s":120,"t2th":180,"t2g":30,"eff":82,"recovery":1,"sus_pct":18,
 "bat_deep":0,"bat_light":0,"bat_mod":0,"bat_wake":0,"bat_ttd":0}
```

#### Session End Reasons

| `"end"` | Trigger |
|:--------|:--------|
| `screen_off` | Screen turned off (natural boundary) |
| `shutdown` | Governor stopped (reboot / kill) |
| `new_session` | `start-session:*` command received |
| `idle_boundary` | 30 minutes of continuous DEEP_IDLE |

#### Atomic Write Protection

History is written to `.tmp` first, then `rename()` to final path. If governor is killed mid-write, the previous valid history is preserved.

---

### 🔋 Battery Telemetry V2

Three new FSM fields bring battery branch to the same maturity level as high-load:

| Field | Description |
|:------|:------------|
| `bat_time_moderate_sec` | Time spent in MODERATE during battery mode |
| `bat_screen_off_count` | Number of screen-off events in battery mode |
| `bat_time_to_first_deep` | Seconds from session start to first DEEP_IDLE entry |

All fields tracked in FSM, exposed in `write_state`, included in session_end log and session_history JSONL.

---

### ⏱️ New Metric: `ses_time_to_first_gaming` (t2g)

How fast does a gaming session actually start? Recorded on first GAMING entry, visible in:
- `/dev/.asb/state` as `ses_t2g`
- `session_end` log marker
- `session_history.jsonl` as `"t2g"`

---

### 🛡️ DEEP_IDLE Auto-Boundary

30 minutes of continuous DEEP_IDLE = automatic session end. Governor saves history, saves persistent stats, resets telemetry. Prevents stale metrics from accumulating during overnight sleep.

---

### 💾 Persistent Stats — Improvements

| Change | V23 | V24 |
|:-------|:----|:----|
| Storage path | `/dev/.asb/` (tmpfs — **lost on reboot**) | `/data/adb/.../runtime/` (**survives reboot**) |
| Save trigger | Governor shutdown only | **Every screen-off** + shutdown + start-session |
| Fields | count, t2s, t2th, temp, gap, eff | + **`degrade_count`** (sessions where auto degraded) |
| State file | `hist_sessions`, `hist_t2s`, `hist_temp`, `hist_gap`, `hist_eff` | + **`hist_deg`** |

> **Critical fix:** V23's cross-session memory was stored in tmpfs and silently lost on every reboot. The entire `hist_*` feature was non-functional. V24 moves it to `/data/` partition.

---

### 🎯 Atomic Session Start

New socket command for clean test setup:

```bash
asb start-session:performance:auto
```

Atomically: save previous session stats → save history → set profile → set highload mode → reset telemetry → log `session_start` marker. Eliminates dirty test data from mixed states.

---

### 📝 Session Markers

Machine-readable log entries for automated analysis:

**On startup / start-session:**
```
session_start profile=performance highload=auto bat=85% temp=32
```

**On shutdown:**
```
session_end gaming=3 sustained=2 thermal=1 unreachable=1 t_heavy=180s t_gaming=95s t_sustained=45s avg_gap=420000 max_temp=67 auto_degraded=0 t2s=120s t2thermal=180s t2g=30s efficiency=82 recovery=1 bat_deep=0s bat_light=0s bat_mod=0s bat_wake=0 bat_ttd=0s sus_pct=18%
```

---

### 🛠️ New Tools

| Tool | Purpose |
|:-----|:--------|
| `tools/asb_session_report.py` | Markdown report from `session_history.jsonl` — trends, battery analysis, recommendations |
| `tools/asb_compare_sessions.py` | Side-by-side comparison of multiple test log files |

#### Session Report Example Output

```
# 📊 ASB Session History Report
Sessions: 8

## 📉 Trends
| Metric              | Average | Min | Max  |
|---------------------|---------|-----|------|
| Max temperature     | 65°C    | 58°C| 72°C |
| Avg cap gap         | 380 kHz | 0   | 920k |
| Efficiency          | 78%     | 45% | 95%  |

## 💡 Recommendations
- ⚠️ Auto degraded in 5/8 sessions — burst often non-viable
```

### ✅ V24 Summary

| Feature | Status |
|:--------|:------:|
| Session history (JSONL, last 10, atomic write) | ✅ |
| Schema version (`"v":1`) | ✅ |
| 4 formal session end reasons | ✅ |
| Battery feedback loop #1 (bat_ttd → idle discipline) | ✅ |
| Battery feedback loop #2 (MODERATE domination) | ✅ |
| Auto history-aware startup (degrade → stable) | ✅ |
| Safety floor for bat_fast_idle_s (5s minimum) | ✅ |
| DEEP_IDLE 30-min auto-boundary | ✅ |
| Persistent stats on `/data/` (survives reboot) | ✅ |
| Screen-off save (stats + history) | ✅ |
| `degrade_count` in persistent stats | ✅ |
| `ses_time_to_first_gaming` (t2g) | ✅ |
| `bat_time_moderate_sec` / `bat_screen_off_count` / `bat_time_to_first_deep` | ✅ |
| `start-session:profile:mode` atomic command | ✅ |
| Session markers in log (session_start / session_end) | ✅ |
| `tools/asb_session_report.py` | ✅ |
| `tools/asb_compare_sessions.py` | ✅ |
| README.md + README.ru.md rewritten | ✅ |

**V24 makes ASB not just remember what happened — but change its own behavior based on what it learned.**

---
