# ASB Log Schemas

This document describes every file the ASB governor and logkit produce, what fields each schema version contains, and how the fields are derived. It exists so that:

1. Old session_history files can still be parsed after schema bumps.
2. Anyone (Claude, ChatGPT, you in six months) can understand what `bat_trust=2` or `limiter=vendor_clamp` actually means without reading the C source.
3. When a new field is added, this doc is the single place that records the schema delta.

## Files Produced

| File | Format | Producer | When |
|:--|:--|:--|:--|
| `/dev/.asb/state` | key=value text | C governor, every tick | Always while daemon running |
| `/dev/.asb/governor.log` | freeform text, ringbuffered | C governor | On significant events |
| `/dev/.asb/auto_battery_state` | `<active> <restore_idx>` | C governor | On auto-battery state change |
| `/data/adb/modules/AutoSystemBoost/runtime/session_history.jsonl` | JSON Lines, one session per line | C governor | On session end / profile change |
| `/data/adb/modules/AutoSystemBoost/runtime/persistent_stats.dat` | binary | C governor | Profile change, daemon shutdown |
| `<logkit_dir>/perf_trace.txt` | pipe-delimited CSV | logkit shell | 1s sampling during capture |
| `<logkit_dir>/battery_trace.txt` | pipe-delimited CSV | logkit shell | 5s sampling during battery captures |
| `<logkit_dir>/status_watch.txt` | concatenated state JSON | logkit shell | 5s sampling |
| `<logkit_dir>/cap_verify.txt` | freeform text report | logkit shell | At capture finalize |
| `<logkit_dir>/cap_source_summary.txt` | text histogram | logkit shell | At capture finalize |

---

## `session_history.jsonl` — current schema **v9**

One JSON object per line, appended on every session end (profile change, daemon restart, or session-ended event). File is capped at `SESSION_HISTORY_MAX` lines (oldest dropped first).

The `v` field declares the schema version. **Any consumer must read `v` first and reject lines with unknown versions** rather than assume field set.

### v9 fields

| Field | Type | Range / Domain | Meaning |
|:--|:--|:--|:--|
| `v` | int | `9` | Schema version. Bumped whenever any field is added, removed, or its meaning changes. |
| `ts` | string | `"YYYY-MM-DD HH:MM"` | Local-time session-end timestamp, minute resolution. |
| `profile` | string | `battery` \| `balanced` \| `performance` | Profile active for the session. |
| `mode` | string | `default` \| `burst` \| `stable` \| `auto` | `highload_mode` config setting at session end. |
| `end` | string | session-end reason | `new_session`, `profile_change`, `profile_drift_resync`, etc. The C call site for `session_history_append_ex()` passes this string. |
| `gaming` | int | ≥0 | Count of FSM `GAMING` state entries during session. |
| `sustained` | int | ≥0 | Count of `SUSTAINED` state entries. |
| `thermal` | int | ≥0 | Count of state transitions caused by thermal triggers. |
| `unreachable` | int | ≥0 | Count of ticks where the FSM target cap was not reached on sysfs (vendor clamp suspected). |
| `t_heavy` | long, seconds | ≥0 | Cumulative time in `HEAVY` state. |
| `t_gaming` | long, seconds | ≥0 | Cumulative time in `GAMING` state. |
| `t_sustained` | long, seconds | ≥0 | Cumulative time in `SUSTAINED` state. |
| `avg_gap` | int, kHz | ≥0 | Average gap between FSM-desired cap and sysfs-actual `scaling_max_freq` for policy0. Used to compute `cap_eff`. |
| `max_temp` | int, °C | typically 20-100 | Peak `cpu_max_c` reported by thermal subsystem during session. |
| `skin_max_temp` | int, °C | typically 20-50 | Peak skin temp (`sys_therm_X` exterior sensor). |
| `surface_max_temp` | int, °C | typically 20-55 | Peak `surface_hotspot = max(skin, board)`. |
| `board_max_temp` | int, °C | typically 20-55 | Peak board temperature. |
| `degraded` | int | 0 or 1 | Whether session ended with `ses_auto_degraded=1` (FSM forced degraded mode). |
| `temp_invalid_n` | int | ≥0 | Count of ticks where temp read returned a sentinel/invalid. |
| `temp_last_reason` | string | `ok`, `no_iface`, `out_of_range`, etc. | Last `temp_invalid_reason` observed. `ok` if all reads valid. |
| `t2s` | long, seconds | -1 if not reached, else ≥0 | Time-to-first-sustained from session start. |
| `t2th` | long, seconds | -1 or ≥0 | Time-to-first-thermal-trigger. |
| `t2g` | long, seconds | -1 or ≥0 | Time-to-first-gaming-state. |
| `eff` | int, 0-100 | Sustained efficiency score. Higher = stayed productive longer before SUSTAINED. |
| `recovery` | int | ≥0 | Count of recoveries from SUSTAINED back to active. |
| `sus_pct` | int, 0-100 | % of active time (heavy+gaming+sustained) spent in SUSTAINED. |
| `bat_deep` | long, seconds | ≥0 | Battery-profile-only: time in `DEEP_IDLE` state. |
| `bat_light` | long, seconds | ≥0 | Time in `LIGHT_IDLE` state. |
| `bat_mod` | long, seconds | ≥0 | Time in `MODERATE` state. |
| `bat_wake` | int | ≥0 | Number of `bat_wake_cycles` during session. |
| `bat_ttd` | long, seconds | -1 or ≥0 | Battery time-to-first-`DEEP_IDLE`. |
| `wake_screen` | int | ≥0 | Wake-ups while screen was on. |
| `wake_bg` | int | ≥0 | Wake-ups while screen was off (background). |
| `radio_ticks` | int | ≥0 | Ticks where cellular radio was active. |
| `idle_q` | int, 0-100 or -1 | Battery-profile-only **Idle Quality**: `bat_deep_pct - wake_penalty`. -1 if too-short session to compute. |
| `cap_eff` | int, 0-100 or -1 | Cap efficiency: `((target - avg_gap) / target) * 100`. -1 if no gaming entries. |
| `dur` | long, seconds | ≥0 | Session duration (now - ses_start_ts). |
| `intent` | string | `unknown`, `benchmark`, `idle`, `mixed`, `sleep_idle` | Inferred session intent. |
| `deg_age` | long, seconds | ≥0 | Age at which session was degraded (if it was). |
| `asb` | string | e.g. `V42`, `V41` | Module version writing this entry. |
| `learn_exempt` | int | 0 or 1 | 1 if session is BENCHMARK and should not feed into learning. |
| `hr_avg` | int, 0-100 or -1 | Average headroom % over session. |
| `hr_min` | int, 0-100 or -1 | Minimum headroom % observed. |
| `hr_b70` | int | ≥0 | Sample count where headroom < 70%. |
| `hr_b50` | int | ≥0 | Sample count where headroom < 50%. |
| `hr_n` | int | ≥0 | Total headroom samples taken. |
| `limiter` | string | `none`, `reachable`, `vendor_clamp`, `thermal`, `mixed` | What limited the session — classifier verdict. |
| `reach` | int, 0-100 or -1 | Reachability score = `(cap_eff + hr_avg) / 2`. |
| `bat_reason` | string | `none`, `wake_noise`, `screen_on`, `no_settle` | Battery-profile failure cause when `idle_q` is low. |
| `conf` | string | `low`, `medium`, `high`, `learn_exempt` | Confidence in classification. Affects whether session is allowed to influence learning. |
| `sig` | string | session "signature" classification | Composite class derived from `sus_pct`, `limiter`, `reach`, `bat_reason`, `conf`, `idle_q`. |
| `mid_tune` | string | `none`, `light`, `heavy` | Whether mid-session self-tune fired. |
| `mid_n` | int | ≥0 | Count of mid-session tunings. |
| `anomaly` | string | classification e.g. `extreme_temp`, `none` | Anomaly flag. |
| `clamp_hold` | int | 0 or 1 | Whether vendor clamp was "held" at session end. |
| `had_clamp_hold` | int | 0 or 1 | Whether clamp_hold was ever true during session. |
| `had_futility` | int | 0 or 1 | Whether FSM detected futile cap-write attempts. |
| `bat_trust` | int | -1, 0, 1, 2 | Battery-only trust tier. `-1`=N/A, `0`=DIRTY (rejected from learning), `1`=PARTIAL (weight 0.25), `2`=CLEAN (full weight). |
| `bat_outcome` | string | `none`, classification | Battery-profile outcome label. |
| `perf_outcome` | string | `none`, classification | Performance-profile outcome label. |
| `env` | string | `quiet`, `noisy`, `hostile` | Environment classification from `classify_environment()`. |

### Schema version history

| Version | When | Changes from previous |
|:--|:--|:--|
| v7 | early V38 | Added `temp_invalid_n`, `temp_last_reason`. |
| v8 | V38 RC | Added `skin_max_temp`, `surface_max_temp`, `board_max_temp`. |
| **v9** | V40 | Added `bat_trust`, `bat_outcome`, `perf_outcome`, `env`. |

Older versions are read-only — V42 still includes legacy lines with `v<9` but does not generate them.

---

## `/dev/.asb/state` — current state file (no version field)

Plain `key=value\n` text. Read by WebUI, `asb_doctor.sh`, `lk_status_json()`, and `runtime/asb_reconcile.sh`. Rewritten every FSM tick (atomic via `.tmp` + rename).

This is **not** JSON despite logkit's `lk_status_json()` parsing it. Each line is one field. Lines may appear in any order between releases — consumers must search by key, not position.

### Key categories

**Identity / state**
- `state` — FSM state (`DEEP_IDLE`/`LIGHT_IDLE`/`MODERATE`/`HEAVY`/`SUSTAINED`/`GAMING`)
- `profile` — current profile name
- `mA` — current battery draw (positive=discharging)
- `gpu_pct` — GPU load %
- `load1` — 1-min CPU load average
- `cpu_max=a,b,c` — FSM-desired cpu_max for policy0, policy6, policy_2 (third often 0)
- `thermal` — thermal cap kHz applied if any (0 if no thermal clamp)
- `cap_temp` — current `cpu_max_c` from active thermal source
- `headroom_pct` — current headroom 0-100 or -1 if invalid
- `perf_cap_p0`, `perf_cap_p6` — what governor declared via msm_performance interface (0 if no_iface)
- `predict` — next-state prediction string
- `screen` — 1 if screen on, 0 off
- `capacity` — battery percentage 0-100
- `dwell_sec` — seconds in current state
- `boost` — 1 if msm_performance boost active

**Cap-source diagnostics** (V39 r2+)
- `cap_gap_p0`, `cap_gap_p1` — `desired - actual` per policy. Positive=vendor clamped down.
- `last_sustained_reason` — string label for last SUSTAINED entry cause
- `highload_mode` — `default` | `burst` | `stable` | `auto`

**Session counters** — match `ses_*` family in session_history. `ses_gaming`, `ses_sustained`, `ses_thermal`, `ses_unreachable`, `ses_t_heavy`, `ses_t_gaming`, `ses_t_sustained`, `ses_avg_gap_p0`, `ses_max_gap_p0`, `ses_max_temp`, `ses_auto_degraded`, `ses_t2s`, `ses_t2thermal`, `ses_t2g`, `ses_efficiency`, `ses_recovery`.

**Battery telemetry** — `bat_deep_idle`, `bat_light_idle`, `bat_moderate`, `bat_wake_cycles`, `bat_screen_off`, `bat_ttd`. Seconds and counts.

**Persistent stats** (last N sessions, profile-wide) — `hist_sessions`, `hist_t2s`, `hist_temp`, `hist_gap`, `hist_eff`, `hist_deg`.

**Live derived**
- `sus_pct`, `idle_q`, `cap_eff` — same definitions as in session_history v9
- `intent` — `unknown`/`benchmark`/`idle`/`mixed`/`sleep_idle`
- `hot_fail`, `degrade_at_age`, `profile_deg` — failure counters

**Plan / scheduling**
- `plan_sensor`, `plan_hr`, `plan_ac`, `plan_deep`, `plan_thermal_div` — booleans/ints driving tick-loop work
- `plan_budget`, `plan_prearm`, `plan_used`, `plan_class` — AC budget tracking
- `plan_sensor_budget`, `plan_sensor_used` — sensor-read budget

**Quarantine / user safety**
- `quarantine` — 1 if config-stale detection active
- `user_id`, `quarantine_left` — quarantine status

---

## `/dev/.asb/auto_battery_state` — V42 persistence

Plain text, exactly two integers space-separated on one line: `<active> <restore_idx>`.

- `active` — `0` or `1`. 1 means auto-battery has switched profile and is waiting for capacity to recover.
- `restore_idx` — profile index to restore on recovery. `-1` if not active. `0`=battery (invalid for restore), `1`=balanced, `2`=performance.

File written by `fsm_auto_battery_persist()` after every state change. Read by `fsm_init()` at daemon start to survive daemon restart/crash without losing the "restore on charge" promise.

`/dev/.asb` is tmpfs, so the file is gone after reboot — that's intentional. After reboot, `restore_idx` would be meaningless anyway (yesterday's session is over).

---

## `perf_trace.txt` — logkit 1s telemetry (V41+)

Pipe-delimited CSV. First non-comment line is the header (also starts with `#`). One row per second during `asb_log_perf.sh` capture.

```
# epoch|date|socd_raw|cpu_prime_raw|cpu_perf_raw|cpullc_raw|shell_f|shell_fr|shell_b|sys_t6|board|battery_tz|p0_cur|p0_max|p6_cur|p6_max|gpu_busy|gpu_clk|gpu_max|gpu_min|gpu_gov|batt_curr|batt_volt|load1|load5|load15|temp|temp_valid|temp_age_s|temp_reason|cpu_type|cpu_zone|skin_zone|surface_zone|skin_temp|surface_hotspot|ses_max_temp|ses_max_surface_temp|board_temp|headroom_valid|headroom_invalid_reason|fallback_type
```

42 columns. Each row is captured by `lk_capture_perf_trace_row` in `_asb_logkit_common.sh`.

**Raw thermal columns** (millidegree-C from `/sys/class/thermal/thermal_zone*/temp`):
- `socd_raw` — SoC die temperature (the master input)
- `cpu_prime_raw`, `cpu_perf_raw`, `cpullc_raw` — per-cluster thermal zones (oryon-prime, oryon-perf, cpu-lc — names vary by SKU)
- `shell_f`, `shell_fr`, `shell_b` — shell/skin sensors front/front-right/back
- `sys_t6` — `sys-therm-6` exterior sensor (V41 surface_hotspot input)
- `board` — board temp from `battery` or `board_thermal` zone
- `battery_tz` — battery thermal zone

**Live cap state**:
- `p0_cur`, `p0_max` — policy0 (LITTLE) scaling_cur_freq / scaling_max_freq
- `p6_cur`, `p6_max` — policy6 (BIG/prime) same

**GPU**:
- `gpu_busy` — % busy from devfreq
- `gpu_clk` — current clock
- `gpu_max`, `gpu_min` — devfreq min/max
- `gpu_gov` — devfreq governor name

**Battery**:
- `batt_curr` (mA, negative=discharging), `batt_volt` (mV)

**Load**:
- `load1`, `load5`, `load15` — Linux load averages

**ASB-derived** (from `/dev/.asb/state` snapshot at row time):
- `temp` — `cap_temp` ASB uses
- `temp_valid` — 1 if last read was OK
- `temp_age_s` — seconds since last successful read
- `temp_reason` — `ok` or invalid reason string
- `cpu_type` — `g_thermal_cpu_type` resolved name (cpu-1-1-0 etc.)
- `cpu_zone`, `skin_zone`, `surface_zone` — zone IDs ASB picked
- `skin_temp`, `surface_hotspot` — derived combined sensors
- `ses_max_temp`, `ses_max_surface_temp` — running session maxes
- `board_temp` — same as `board` column but from ASB cache
- `headroom_valid`, `headroom_invalid_reason` — headroom path status
- `fallback_type` — `g_thermal_cpu_fallback_type` if SoC die was rejected

---

## `battery_trace.txt` — logkit 5s battery telemetry

Pipe-delimited CSV. 29 columns, sampled by `asb_log_battery_sleep.sh` and `asb_log_battery_mixed.sh`.

```
# epoch|date|state|profile|screen|bat_pct|bat_mA|bat_volt|bat_temp_10x|cpu_temp|skin|surface|board|idle_q|bat_deep|bat_light|bat_mod|bat_wake|headroom_pct|headroom_valid|headroom_invalid|thermal_cpu_type|fallback_type|wlan_rx|wlan_tx|rmnet_rx|rmnet_tx|load1|dwell_sec
```

Most columns are reads of /dev/.asb/state with explicit type. `bat_temp_10x` is battery temperature × 10 (147 = 14.7°C). `wlan_rx`/`wlan_tx`/`rmnet_rx`/`rmnet_tx` are total bytes from `/proc/net/dev`.

---

## `cap_verify.txt` — finalize-time report

Human-readable text report written by `lk_verify_caps()` at capture end. Per-policy line:

```
policy0 (LITTLE) cpus[first]=0 actual_max=1113600 hw_ceiling=3628800
                 profile_expected=614400 asb_declared=0
                 shell_source=shell_overridden_up gov_source=vendor_clamp
                 -> DESYNC_shell_overridden_up (...)
```

Two source verdicts:
- `shell_source` — shell-side independent classification (sees `scaling_max_freq` only)
- `gov_source` — pulled from `/dev/.asb/state`'s `cap_source_p0`/`cap_source_p6` (governor's own classifier)

When they disagree, one of them has a bug. When they agree, the verdict is high-confidence.

---

## `cap_source_summary.txt` — time-in-state aggregate

Written by `lk_emit_cap_source_summary()`. Counts ticks of each `cap_source_*` value across the capture's `status_watch.txt`:

```
===== cap_source summary (tick counts from status_watch) =====
policy0 (LITTLE)  total_ticks=1044
  shell_applied      896  (85.8%)
  vendor_clamp       102  ( 9.8%)
  asb_dynamic         46  ( 4.4%)
```

Designed for the question *"who really controls the CPU caps during this session?"* If `vendor_clamp` dominates BIG, vendor thermal HAL is the real authority; if `asb`/`shell_applied` dominates, ASB writes are sticking.

---

## When a schema changes

1. **Bump `v` in the JSON producer** (currently `session_history_append_ex` in `asb_governor.c`).
2. **Update this doc** in the same commit. Add a row to the version-history table. Document every new/removed/changed field.
3. **Update consumer scripts** in `tools/logkit/` and `tools/asb_analyze.py` to handle both old and new versions.
4. **CHANGELOG entry** under the release that introduces the new schema.

The state file (`/dev/.asb/state`) has no version field by design — it is always "current" and consumers must search by key, not position. Adding a new key is non-breaking. Removing a key is breaking and requires CHANGELOG mention.
