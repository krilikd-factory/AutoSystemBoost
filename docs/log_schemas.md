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
| `/data/adb/asb/session_history.jsonl` | JSON Lines, one session per line | C governor | On session end / profile change |
| `/data/adb/modules/AutoSystemBoost/runtime/session_stats.json` and `pstats_*.json` | JSON aggregate outcomes | C governor | Profile change, daemon shutdown |
| `<logkit_dir>/perf_trace.txt` | pipe-delimited CSV | logkit shell | 1s sampling during capture |
| `<logkit_dir>/battery_trace.txt` | pipe-delimited CSV | logkit shell | 5s sampling during battery captures |
| `<logkit_dir>/status_watch.txt` | concatenated state JSON | logkit shell | 5s sampling |
| `<logkit_dir>/cap_verify.txt` | freeform text report | logkit shell | At capture finalize |
| `<logkit_dir>/cap_source_summary.txt` | text histogram | logkit shell | At capture finalize |
| `<logkit_dir>/phase_ledger.tsv` | tab-delimited phase intervals | full-day logkit shell | On phase transition and finalization |
| `<logkit_dir>/phase_summary.txt` | text table | full-day logkit shell | Hourly and final report |
| `<logkit_dir>/sampled_current_distribution.txt` | text table | full-day logkit shell | Hourly and final report |
| `<logkit_dir>/mobile_traffic_context.txt` | text table | full-day logkit shell | Hourly and final report |
| `<logkit_dir>/energy_model.txt` | `domain\|khz\|power\|cost`, or `unavailable` (fix179) | logkit shell, read-only from debugfs `energy_model` | Once at capture start |
| `<logkit_dir>/wake_sources.txt` → `# --- Wi-Fi multicast by app` | `uid (package): <batterystats line>` (fix179) | full-day logkit shell | Hourly with the batterystats snapshot |

---

## `session_history.jsonl` — current schema **v9**

One JSON object per line, appended on every session end (profile change, daemon restart, or session-ended event). File is capped at `SESSION_HISTORY_MAX` lines (oldest dropped first) and a 5 MiB hard limit.

It is not only an exported diagnostic: at governor startup, bounded battery-session history is read to derive conservative `bat_fast_idle_s` feedback. Schema-3 named profile backups therefore include it, together with `session_stats.json` and the per-profile `pstats_*.json` aggregate outcomes. Older schema-1/2 backups remain valid; they simply lack these optional files.

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
- Smart records (fix184): `rec_enabled` (smart_records), `rec_counter` (charge counter: 1 ok, -1 unreadable, -2 did not move over 10 min, 0 not tried yet), `rec_on_offset` (the economy lean x1000 the records put on Smart with the screen on, 0 = none), `rec_off_scale` (x1000 on the screen-off deep-idle ceilings, 1000 = as before), `rec_block` / `rec_block_arm` (the situation being measured and the setting it runs on), `rec_blocks_ok` / `rec_blocks_rejected`; `microwake_active` (this screen-on is treated as a night check), `microwake_holds` (screen-ons kept in the night radio mode since the governor started), `microwake_learned`.
- `/dev/.asb/smart_records.txt` (fix184; Smart V5 layout since fix185, rewritten on every save) — `counter=ok|unavailable|not_moving|waiting blocks_ok= blocks_rejected=`, `rejected|meter=|charge=|radio=|busy=|climate=|other=` (why blocks were set aside: charge = charging or charge came in, climate = the battery warmed or cooled by 3 C in the block - in from the cold, out into it, or cooling in use), then one line per situation `ctx|status|best|record_mW|record_mA|record_n|gain_pct|testing|pairs|pair_diff_pct|trials|wins|blocks|first_mW`: ctx `off_night`, `off_day`, `on_light_dim`, `on_light_bright`, `on_medium_dim`, `on_medium_bright`; status `measuring` (no figure yet), `testing` (a neighbour is being alternated with the best), `holding`, `plateau` (neither neighbour beat it - re-checked after 21 days); best/testing `x0.750`..`x1.500` screen off, `-200`..`+200` screen on; record_mW = power of the best setting's blocks (charge counter x mean battery voltage, suspend included; record_mA the same blocks in mA); gain_pct = how much cheaper than the original setting, as the product of the side-by-side wins; pairs / pair_diff_pct = the paired comparisons of the trial running now (challenger block against the champion block next to it, within 4 h, 2.5 C and 25 points of charge) and their mean difference; first_mW = the original setting as first measured (information only). Blocks are not started while charging, in the 20 minutes after it or under 10 %. Then `microwake|learned=|nights=|per_night=|typical_s=|usual=HH:MM-HH:MM`, `smooth|watching=|testing=|helped=|not_helped=` (apps in the smoothness check), `last=` (the latest records decision) and `last_smooth=` (the latest smoothness decision; the app is named by its hash `app <16 hex>` unless the build is a debug build or `smart_pkg_plaintext=1`). The learning itself is `/data/adb/asb/smart_records.bin` (binary, cleared by the Smart learning reset; a fix184 store keeps its night checks and re-measures the situations).
- `/dev/.asb/gfx.txt` (fix185) — written by `runtime/asb_gfx_probe.sh <package>` for the governor's smoothness check: one line `package frames janky`, the app's rendered and janky frame totals summed over the entries `dumpsys graphicsstats` lists for it (the live buffer and the last days' files), or empty when the app has none. Asked at most every 3 minutes of screen-on time, Smart only, for the app in front (not games, the camera or the system UI); the difference between two answers is one window.
- Records situation now (fix186, the WebUI's Basis tile) in `/dev/.asb/state`: `rec_ctx` (the situation in force, `-` none), `rec_ctx_status` (`measuring`/`testing`/`holding`/`plateau`), `rec_ctx_best` / `rec_ctx_test` (champion / challenger setting: x1000 ceiling scale screen off, lean x1000 screen on; equal when no trial), `rec_ctx_trial` (1 = the block running now measures the challenger), `rec_ctx_pairs` / `rec_ctx_need` / `rec_ctx_max` (pairs done, minimum, maximum), `rec_ctx_n` (champion blocks in this trial), `rec_ctx_gain_x10` (cheaper than the original setting, tenths of a percent, side by side).
- Smoothness / climate (fix185) in `/dev/.asb/state`: `smooth_lean` (x1000 on Smart's lean for the app in front, -150 = more headroom: a test window or a kept verdict), `smooth_testing` (the app in front is in a test - the records leave that time out), `smooth_probes` / `smooth_windows` (frame reads and complete windows since the governor started), `smart_cold_guard` (1 = battery under 5 C and under 40 %: Smart's lean held at 0.8 or more), `ses_climate` (last banked session: 0 normal, 1 battery under 5 C, 2 a cold battery warming or cooling by 3 C, 3 the battery cooled 3 C below its start, 4 right after the charger - 1..4 = its drain was not learned from), `unplug_age_s` (seconds since the charger came off; 1000000 = not seen). `smart_engine_ver` is 5 since fix185.
- `sustained_repeat` — 0-3: quick SUSTAINED re-entries (within 5 min of the last exit) the current SUSTAINED dwell is doubled for (24/48/96/180 s); `sustained_reentry_left_s` — seconds re-entry is still blocked after the last exit (fix181)
- `profile` — current profile name
- `mA` — current battery draw (positive=discharging)
- `gpu_pct` — GPU load %
- `load1` — 1-min CPU load average
- `cpu_max=a,b,c` — FSM-desired cpu_max for policy0, policy6, policy_2 (third often 0)
- `thermal` — thermal cap kHz applied if any (0 if no thermal clamp)
- `cap_temp` — current `cpu_max_c` from active thermal source
- `headroom_pct` — current headroom 0-100 or -1 if invalid
- `offdrain_pctph_x100`, `offdrain_windows` — screen-off drain (%/h x100) over windows of 60+ min on battery that lost 2+ %, all profiles together, smoothed 3:1 (file `/data/adb/asb/offdrain_pctph_x100`: `rate windows 2`); `offdrain_by_profile` (fix189) — the same per profile, `name:rate:windows,...` for battery, balanced, performance, smart (rate -1 = none yet), counting only a window one profile held from screen-off to screen-on (file `/data/adb/asb/offdrain_profiles`: `name rate windows` per line). The profile cards show only the per-profile figures; the phone-wide one feeds time-to-empty estimates, marked "~".
- `/data/adb/asb/drain_meter` (fix253) — per-profile `on_s on_x off_s off_x off_n off_last off_last_s off_last_at`; the first six fields keep the older aggregate format, while the last three are the just-finished qualifying screen-off window's rate (%/h x100), duration and end time. Six-field files remain valid. `/data/adb/asb/drain_meter.rej` (fix189) — windows not counted: `media short charge last` (sustained playback of 10+ min, windows under an hour, windows ended on the charger; `last` = `profile:reason:minutes`).
- `runtime/asb_rom_telemetry.sh` prints `cpus_online` (fix189), the online CPU count, for the Monitor's load share.
- `msm_asb_hold`, `msm_asb` (fix188) — 1 while ASB holds a HEAVY/GAMING registration in `/sys/kernel/msm_performance/parameters/cpu_max_freq`, and the per-slot kHz it last wrote there (`slot0,slot1,slot2`; the hardware maximum after a release, 0 = never written). asbdiag uses them to tell ASB's values in that node from the vendor's.
- `headroom_real_pct` (fix186) — the Monitor's "Headroom": the most limited cluster's live `scaling_max_freq` against its hardware maximum, 0-100, -1 unreadable (the action screen prints this one)
- `perf_cap_p0`, `perf_cap_p6` — what governor declared via msm_performance interface (0 if no_iface)
- `predict` — next-state prediction string
- `screen` — 1 if screen on, 0 off
- `capacity` — battery percentage 0-100
- `dwell_sec` — seconds in current state
- `boost` — 1 if msm_performance boost active

**Cap-source diagnostics** (V39 r2+)
- `cap_gap_p0`, `cap_gap_p1` — `desired - actual` per policy. Positive=vendor clamped down.
- `desired_cpu_max0`, `desired_cpu_maxp` / `effective_cpu_max0`, `effective_cpu_maxp` — the
  rail (snapped, floored, before the thermal budget) and the live ceiling for slot 0 and
  slot 1. Slot 1 is the prime on a two-cluster SoC but a middle cluster on 1+3+2+1 parts.
- `prime_slot`, `prime_policy_id`, `desired_cpu_max_prime`, `effective_cpu_max_prime` — the
  same for the prime itself, whatever the topology (fix126).
- `requested_cpu_max0`, `requested_cpu_max_prime` — what the writer last sent and kept, after
  the thermal budget and the race-to-idle floor; 0 until ASB has written (fix126). Live below
  this = a ceiling ASB did not write; live equal to it but below `desired_*` = ASB's own trim.
- `cap_writer` — `shell` in battery/balanced with no thermal cap and no screen-off cooldown
  (service.sh writes the CPU ceilings), `asb` otherwise - Smart, Performance, or the governor
  overriding a manual profile (fix183: then never above the shell's own ceilings); `shell_cpu_max0`,
  `shell_cpu_max_prime` — the ceilings the shell recorded for slot 0 and the prime, 0 when not
  the owner or no record yet. In `shell` mode `desired_*` is a rail the writer does not send:
  compare live ceilings with `shell_cpu_max*` (fix182).
- `/dev/.asb/shell_cpu_caps` (fix182) — written by service.sh `apply_cpufreq_caps` with mv:
  `profile=`, `screen_on=` (the rung used), `ts=`, then `policyN=kHz` per policy written (the
  request, or the read-back when the kernel rounded it up). The governor trusts it only for
  the running profile while it is the cap owner; `cap_source_*` there is `shell_applied`
  (live == record), `vendor_clamp` (below) or `shell_overridden_up` (above).
- `/dev/.asb/shell_cpu_caps.battery`, `.balanced` (fix183) — the screen-on rung of each manual
  profile, computed by `apply_screen_aware_caps` on every pass whatever profile runs (Smart
  included) without writing a ceiling: `profile=`, `screen_on=1`, `ts=`, `precomputed=1`,
  `policyN=kHz`. The governor uses it when `shell_cpu_caps` names another profile: on a switch
  into Battery/Balanced it writes these values itself, and it hands back what it wrote under a
  thermal cap, the cooldown or the anti-clamp. The full-day logkit copies all three files.
- `prime_escape_skip_warm`, `prime_escape_skip_foreign` — prime bursts not opened: the die
  within 3 C of the sustained-exit mark that would end the burst, or the cores pinned at a
  lower ceiling ASB does not hold (fix126).
- `main_parity_khz`, `main_parity_lifts`, `main_parity_capacity="MAIN,PRIME"` — the main-core
  ceiling Smart raised to the prime's capacity in light idle / moderate on a two-cluster SoC
  (0 = not raised now), how many raises started this session, and the `cpu_capacity` values
  it used (-2 not read yet, -1 unreadable). `desired_cpu_max0` includes the raise (fix130).
- `main_parity_near`, `main_parity_over_khz` — 1 when the raise is the highest main step
  inside the 60% limit because the level step sat over it (taken only when it reaches 90% of
  the prime's capacity); the level step that was over the limit, 0 when none (fix132).
- `writer_hold_bypass` — CPU ceilings/floors sent while their node was backed off after a
  vendor hold: the held value waits out the five minutes, a NEW request is written at once
  (fix133). `writer_node_*` keeps the per-node status (`kernel_floor_higher` = a boost read
  back above ASB's request).

**Screen detection**
- `screen_on_detect="uevent:N,recheck:N,tick:N,display:N"` — which path noticed each wake.
- `screen_off_detect="uevent:N,display:N,tick:N"` — the same for screen-off (fix126).
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

**P0 control provenance **
- `thermal_control_source` — quoted resolved CPU thermal-zone type currently controlling the governor. It is a source label, not a temperature.
- `thermal_control_zone` — selected CPU thermal-zone number; `-1` means no usable CPU zone has been selected yet.
- `thermal_source_confidence` — integer `0..2`: `0` uninitialized/unavailable, `1` derived CPU fallback or otherwise unvalidated source, `2` primary source cross-checked against CPU peers.
- `thermal_rejected_type` — quoted type label of a rejected candidate such as `socd`; empty when no candidate was rejected.
- `thermal_rejected_raw` — raw integer from the rejected zone. It **must not** be interpreted as °C: Android thermal zones can use different scales. It is evidence for diagnosis only.
- `startup_quarantined` — cumulative number of early boot samples excluded from Smart learning during the settle window. It is a counter, not a current-mode boolean.

The concurrent native status JSON uses the corresponding fields `thermal_cpu_type`, `thermal_cpu_zone`, `thermal_src_conf`, `thermal_rejected_type`, and `thermal_rejected_raw`. The shorter `thermal_src_conf` spelling is retained for status JSON compatibility; consumers must not assume that the two files share every key name.

**Battery measurement confidence **
- `battery_window_confidence` — `0` no usable window, `1` one SOC step or less, `2` short but usable window, `3` settled window with material SOC movement.
- `battery_window_reason` — human-readable reason for the current confidence. A live charging sample always has confidence `0` and is excluded from a discharge estimate.
- `battery_current_source` — source name selected for the current/battery estimator.

**Quarantine / user safety**
- `quarantine` — 1 if config-stale detection active
- `user_id`, `quarantine_left` — quarantine status

**Charge-aware (V50)**
- `charging` — 1 while the pack reports Charging
- `smart_charge_assist` — 1 when Smart leans toward performance because plugged + cool
- `smart_charge_cool` — 1 when the cool-charge guard is leaning toward battery (pack warm or screen off while plugged)
- `smart_charge_class` — 0 none, 1 slow (<12W), 2 fast (12–33W), 3 super (≥33W)
- `smart_charge_w_x10` — estimated charge power, W×10, observability only

**Night window learner (V50)**
- `night_auto` — config `night_quiet_auto` mirror
- `night_auto_ready` — 1 once enough nights observed and the learned window is in control
- `night_window_active` — 1 while current time is inside the learned window
- `night_sleep_min`, `night_wake_min` — learned minutes-of-day (-1 until first sample)
- `night_samples` — number of complete nights observed

---

## `/data/adb/asb/config_last_txn` — config writer provenance 

Plain `key=value` sidecar written atomically by `runtime/asb_config_safe.sh` after every attempted config transaction. Its default directory follows `ASB_CONFIG_STATE`; production resolves that variable to `/data/adb/asb`, while host/staged tests can isolate it. The record is intentionally compact and never contains a config dump, shell stderr or arbitrary path.

| Field | Meaning |
|:--|:--|
| `timestamp` | Unix seconds when the outcome was recorded. |
| `result_class` | Stable outcome class: `success` for a completed transaction, or failure classes such as `validation`, `lock_live`, `lock_stale`, `permission`, `duplicate`, `snapshot`, and `reload`. |
| `reason` | Short human-readable outcome reason; a successful transaction records `applied`. |
| `key` | Optional config key for a single-key transaction. |
| `pre_epoch`, `post_epoch` | `governor.conf` mtime epochs immediately before script startup and at record write; they show that a transaction crossed the expected file-change boundary, but are not a daemon reload acknowledgement. |
| `reload_accepted` | `not_requested` for this writer. The writer is deliberately atomic-only; the governor runtime owns reload acknowledgement. |
| `recovery` | Optional stable label. `legacy_thermal_ceiling` means an unrelated transaction found an inherited, in-range inversion where `sustained_temp_ceiling < sustained_temp_enter`; writer raised the ceiling exactly to the existing `enter` value before normal full validation. It is absent for ordinary transactions and never authorizes an explicit invalid thermal edit. |

`tools/asb_effective_policy.sh`, `asbdiag`, and logkit snapshots expose this record read-only. Absence means no writer transaction was captured yet; it is not an error by itself.

---

## `runtime/asb_lsposed.sh status` and `/data/adb/asb/lsposed_verbose_prev` — LSPosed's verbose log (fix187)

Read by the WebUI card *LSPosed Verbose Log* (`lsposed_verbose=keep|off`) and by asbdiag section 0f. `status` prints `key=value` lines:

| Field | Meaning |
|:--|:--|
| `present` | 1 when `/data/adb/lspd` and its `config/modules_config.db` exist. |
| `setting` | The card's value in `governor.conf`. |
| `verbose` | LSPosed's own setting, read from its database by `asb --lspd verbose-get`: `on`, `off`, `default_on` (no row - LSPosed's default, on) or `unknown` (then `reason=no_database|no_sqlite|open_failed|unexpected_schema`). |
| `log_kib`, `verbose_kib` | Size of LSPosed's log files on disk, all / `verbose_*.log` only. |
| `modules_kib`, `oldlog_kib` | (fix189) `modules_*.log` - what LSPosed modules write themselves (tag LSPosed-Bridge), with no switch in LSPosed - and the previous boot's logs in `log.old`. |
| `pending_reboot` | 1 when ASB wrote the setting after this boot began: the LSPosed daemon reads it only when it starts. |
| `asb_changed` | `asb_changed=1 prev=<value>` while ASB has switched the log off; `prev` is what LSPosed had before. |

On off, older `verbose_*.log` files of this boot are emptied in place (LSPosed deletes the eldest of its current list itself, and a file already gone stalls that until the next boot) and `log.old/verbose_*.log` is deleted. `apply` prints `result=off_after_reboot freed_kib=N`, `already_off freed_kib=N`, `restored prev=<value>`, `untouched`, `absent`, `unsupported reason=...` or `write_failed`. `restore` (uninstall) puts `prev` back whatever the card says.

fix197: off also empties the modules log, which has no switch in LSPosed - every `modules_*.log`, the newest included (truncated in place, like LSPosed's own "clear log"; the daemon appends, so the log grows again from empty), and `log.old/modules_*.log` deleted. `sweep` does only that emptying - no setting write, no record - printing `result=swept freed_kib=N`, `skip` (the card is not off) or `absent`; a loop in service.sh runs it every ten minutes while the card says off. The verbose files of this boot are ordered by the timestamp in their names, not by mtime: truncation sets mtime to now, which would dethrone the file the daemon holds open on the next pass.

`/data/adb/asb/lsposed_verbose_prev` holds LSPosed's value from before ASB's first change (`on` or `default_on`), written only when ASB actually switches the log off and removed when it is put back (a fix187 build also wrote `off` when the log was already off; that record is discarded); `/data/adb/asb/lsposed_verbose_prev_at` is the epoch second of ASB's last write, for `pending_reboot`. The write is the row (`lspd`, 0, `config`, `enable_verbose_log`) of LSPosed's `configs` table, a Java-serialised `java.lang.Boolean`; any other layout is reported as `unexpected_schema` and left alone. Nothing here runs at boot.

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

## Full-day derived report artifacts

`phase_ledger.tsv` columns, in order:

```
1  phase        phase label (sleep, idle, gap, active, gaming, audio_*, charging_*)
2  start_epoch  phase start, seconds
3  end_epoch    phase end, seconds
4  start_pct    battery percentage at start
5  end_pct      battery percentage at end
6  max_cpu_c    highest CPU temperature seen in the phase
7  max_surf_c   highest surface temperature seen
8  max_p6_khz   prime-cluster ceiling, duration-weighted mean (not the peak - see below)
9  gpu_avg_pct  mean GPU load
10 throttle     throttle events counted
11 wake_peak    peak wakeup rate
12 awake_pct    share of the phase the SoC was not suspended
13 ma_avg       mean of sampled current; biased high, see the caveats below
14 rmnet_rx     mobile bytes received during the phase
15 rmnet_tx     mobile bytes sent
16 cooldown     ticks the screen-off cooldown clamp was engaged
```

Column 16 is appended rather than inserted for a reason: readers index this file
positionally, so a new field in the middle shifts every column after it and the shift is
silent - the file still parses, the numbers just mean something else.

`asb_log_full_day.sh` writes a tab-delimited `phase_ledger.tsv` with one concrete time interval per detected phase. Its phase summary is **not** a causal energy split: temperature and current fields are sampled observations, Android capacity is integer-quantised, and repeated phase labels may represent disjoint intervals.

`sampled_current_distribution.txt` maps each positive raw `battery_trace.txt` discharge-current sample to a concrete ledger interval, then groups the mapped samples by phase. It reports the number of samples, the mean sampled mA, and the **median sampled mA**. The median is intentionally resistant to brief outliers; neither figure is a physical whole-phase current average because suspend and gaps between recorder wake-ups are under-sampled. Charging/zero/invalid samples are excluded, and `current_now` values at or above 100000 are normalized from µA to mA for this derived report.

`jank_trace.tsv` (fix121) - UI smoothness, one row per interval between two consecutive
screen-on polls (a screen-off poll or a gap over 180 s starts a new baseline):

```
1  epoch            end of the interval
2  iso_time
3  phase            recorder phase at the end
4  fsm_state        ASB state at both ends, or "mixed" when it changed inside the interval
5  interval_s
6  main_at_cap      lowest policy within 2% of its scaling_max_freq at the end (1/0/-)
7  prime_at_cap     highest policy, same test ("-" on a single-policy SoC)
8  touches          touch_starts delta from the governor's touch watch (fix117), "-" if absent
9  frames           HWUI frames rendered by every app (dumpsys graphicsstats, summed)
10 janky            frames that missed their deadline ("Janky frames", not the legacy count)
11 deadline_missed  "Number Frame deadline missed"
12 slow_ui          "Number Slow UI thread"
13 high_input       "Number High input latency" - a COUNT of input events (it can exceed
                    frames); the report shows it per screen-on minute, never as a share
14 main_cap_pct     share of the interval the lowest policy sat at its ceiling, from
                    cpufreq stats/time_in_state ("-" without kernel stats) - fix125
15 prime_cap_pct    the same for the highest policy
16 fg_pkg           the app in front (top-app cgroup, as the governor reads it since
                    fix124); "-" nothing app-like, "multi" for split screen - fix125
```

The counters are cumulative per package and day, so a delta is what was rendered in the
interval; a negative step (an old day pruned) writes no row. Games drawing on their own
GL/Vulkan surface are not HWUI frames. The report section "UI SMOOTHNESS" aggregates janky%
by phase, by ASB state and by whether a cluster sat at the ASB ceiling.

`throttle_trace.txt` - one row per recorder poll where a ceiling sat below ASB's profile
rail (`desired_*`):

```
epoch|phase|p0_max=LIVE/HWMAX|p6_max=LIVE/HWMAX|cpu_temp=C|surface=C|cap_owner=WORD|main_by=CAUSE|prime_by=CAUSE|writer=asb|shell
```

`writer=shell` (fix182): a manual profile - the reference was `shell_cpu_max*`, the ceiling
the shell wrote, so the row is a live ceiling under the profile's own cap. In the ownership
verdict `shell` counts as ASB's own, not as a foreign owner.

`p6_max` is the last (prime) policy, compared with `desired_cpu_max_prime` since fix126 (it
was slot 1, a middle cluster on 1+3+2+1 parts). `main_by` / `prime_by` (fix126): `-` at or
above the rail, `asb_trim` the live ceiling is ASB's own trimmed request, `vendor` it is
below what ASB wrote (PowerHAL or kernel thermal), `asb_msm` (fix186) it equals ASB's own
HEAVY/GAMING registration with msm_performance (the governor's headroom reason `own_cap`) - before
fix186 that registration carried the ceiling before the race-to-idle floor - `?` no request
published. They are appended, so readers that split on `cap_owner=` keep working.

`_full_day_report.txt` (fix130): **SCREEN-ON WORK BY CLUSTER** (two-cluster phones) - the
share of screen-on samples with each cluster above a quarter of its top clock, split by whether
the main ceiling's capacity (`cpu_capacity` x ceiling / hardware max) is at least the prime's.
**LIVE WAKELOCK HOLDERS** - partial wakelocks from the `wake_live.txt` power-manager samples
with the screen off: share of samples and the longest single hold, package from `uid_map.txt`
(system uids are named as such). Unlike batterystats it also works while charging.

`wifi_leave_events.log` (fix152) - the leave-bad-Wi-Fi watcher's own lines
(`/data/adb/asb/wifi_fallback.log`, which keeps only 80), copied on every poll from the start
of the capture, each line once: `YYYY-MM-DD HH:MM:SS wifi_fallback: <event>`. The report section
**WI-FI LEAVE** counts releases by reason (out of range, no internet), Wi-Fi given back after
the window and failed disables, the time from the first failing reading of a streak
(`pass 1/N`) to its release (median and longest), and streaks that recovered on their own.

`tools/asb_capture_compare.py` (fix152, host) reads captures and asbdiag reports from folders
or zips and prints these figures per phone model; `--json` saves them, `--baseline` compares a
new set with a saved one. `docs/field_baseline/fix150.json` is the set from the fix150 field
logs.

`mobile_traffic_context.txt` aggregates the existing ledger's selected-rmnet RX+TX counters by phase and lists only phases with at least **32 MiB**. It keeps the phase duration and screen context so a reviewer can identify a potentially material transfer window. It is a report-only context flag: observed bytes may contribute to radio energy in that phase, but they do not prove cause or assign a battery percentage.

---

## `asb_fullday_digest.sh` — the WebUI log-report feed (fix194, extended fix200)

`tools/logkit/asb_fullday_digest.sh [capture_dir]` prints the capture as TAB-separated
`tag\tkey=value\t…` lines on stdout; the WebUI "Log report" page is its only consumer.
With no argument it resolves the running capture from the logkit lock, else the newest
`asb_log_full_day_*` folder under the usual roots. Everything is awk/sed over files the
recorder already wrote - no dumpsys, so it costs nothing and works the same in every
profile, on running and saved captures alike. A missing input only means its line is
absent; consumers must treat every line as optional. Tags in emission order:

```
meta     elapsed_min, target_h, running (1 = capture live), started (YYYY-MM-DD HH:MM
         from the ledger's first phase, may be empty), profile (env.txt current_profile)
cover    on_min, off_min, on_pct          (only with >= 10 min of battery_trace)
drain    pctph, total_drop, hours, ma     (discharging phases only)
night    dur_min, drop, pctph, awake      (longest idle/sleep chain >= 15 min)
idlemax  awake, phase, dur_min            (worst screen-off awake share)
thermal  cpu, surf                        (peak temperatures)
radio    mib                              (ledger rx+tx, >= 0.1 MiB)
wl       pkg, sec                         (top app wakelocks) or "wl  none=1"
crash    count, asb, latest               (tombstones inside the capture window)
sysui    count                            (SystemUI restarts)
throttle clamps, owner
jank     pct, jps, frames                 (screen-on jank headline, from the report)
japp     pkg, frames, pct                 (top four apps; the split-screen "multi"
                                           pseudo-row is dropped)
hz       mode, share, ma                  (per-refresh-rate rows)
asbcost  cpu_msh, writes_h, wakes_h       (ASB's own bill)
audio    spk_min, pctph, ma               (speaker playback, from the phase table whose
                                           header carries pct/h - never the sampled-
                                           current table, which reuses the column for mA)
charge   types                            (e.g. "Fast(17) N/A(197)")
smart    watching, testing, helped, nothelped, ctxlearn   (smooth| line of
                                           smart_records.txt plus learned contexts)
cfg      key, value                       (seven advice-relevant switches, read from the
                                           CURRENT config, one line per key)
error    no_capture                       (nothing found - the only failure line)
```

The WebUI parser keys on the tag; unknown tags are kept in `sections` and unknown keys
are preserved, so older WebUIs tolerate newer digests and vice versa.

---

## `audio_trace.txt`, `network_trace.txt`, `kernel_params.txt` — provenance snapshots

These are human-readable snapshot streams, not positional CSV schemas. Each block begins with a UTC timestamp and a scenario tag. A missing property, route, sysfs node or PSI endpoint means **unavailable**, not a failed ASB write.

`audio_trace.txt` records the observed playback state and route, then the ASB-requested `bt_a2dp_offload` value, published `persist.asb.dsp.*` state, platform/vendor A2DP-offload blocks, codec hints, active players and AudioFlinger effects. It is evidence for a future offload A/B experiment; it does not enable or disable offload itself.

`offload.state` is deliberately conservative. It reports `offload thread present on an active BT route` only when three signals agree: AudioFlinger names an Offload or Compress thread, the active route is Bluetooth, and playback is running. A thread on its own is **not** treated as proof — it may serve a different output or outlive playback — so that case reports `unknown (thread seen, but route or playback did not corroborate)`. Where the platform or vendor property blocks offload outright the state is `off`. Anything else is `unknown`.

### Bluetooth lifecycle recorder

Every `asb_log_full_day.sh` capture now enables a **bounded, read-only** Bluetooth lifecycle recorder by default. It does not change a Bluetooth setting, profile, codec, route, power state, or audio policy. A tester may explicitly disable it with `ASB_BT_RECONNECT_TRACE=0`, but no extra flag is required for ordinary full-day logging.

The recorder writes two complementary artifacts:

| File | Meaning |
|---|---|
| `bt_lifecycle_events.tsv` | Timestamped lifecycle evidence from a narrow Bluetooth stack-tag allowlist: `connect`, `disconnect`, or `reconnect_literal`. The latter is emitted only when the stack log literally says reconnect; a connection event is never promoted to a guessed reconnect. |
| `bt_lifecycle_context.tsv` | Timestamped capture/phase/hourly/end context with `audio_playing` and `audio_route`. It helps correlate the nearest route/playback state, but is **not** itself an event. |

Event kinds (fix131/fix178): `hfp_audio_connect` / `hfp_audio_disconnect` (the call link, SCO - not a device loss), `a2dp_profile_connect` / `a2dp_profile_disconnect` (including the one-step `2->0` of a lost link and the `A2dpStateMachine` transition), `hfp_profile_disconnect`, `acl_connect` / `acl_disconnect` (the radio link itself; the source column carries only the HCI reason, `ACL reason=<n>` - 8 lost link/timeout, 19 ended by the headset, 22 ended by this phone), `reconnect_literal`, and the generic fallbacks. The report prints the ACL drops by reason.

`bt_lifecycle_snapshots.txt` (fix178): hourly and phase snapshots of the Bluetooth service, at most 200 lines of 360 characters each, addresses and AVRCP device names redacted (`<BT_ADDR> : <name> : <volume> : <state>`). Each carries the last 20 state changes of every profile state machine on the phone's clock; the report reads them back as "media-profile drops in the Bluetooth service history" - deduplicated across snapshots, devices named A, B... in order of appearance, `what=101` (stack-reported: the headset or the radio link) told apart from `what=2` (asked for on the phone), and the call profile judged dropped / kept only where its own rows bracket the moment within 10 min in an unchanged state.

Addresses and device names are not written to either file. The event log has a conservative default cap of 240 records (`ASB_BT_RECONNECT_MAX_EVENTS` may lower it). The narrow logcat tag list is intentional: an all-day unfiltered dump would be expensive and privacy-hostile, while the diagnostic question only needs Bluetooth lifecycle evidence. Absence of an event remains inconclusive because vendor builds may use unobserved tags.

Lifecycle: `lk_bt_reconnect_start` at capture start, `lk_bt_reconnect_snapshot` at `before`, at audio-phase entry, hourly, and at `end`, then `lk_bt_reconnect_stop`. `_full_day_report.txt` summarizes the three evidence counts and points to both files. `donor_telemetry_contract` in `tests/asb_system.sh` asserts the functions and call sites so this recorder cannot silently disappear in a merge.


The same rule runs in `tools/asb_diag.sh` and in `tools/logkit/_asb_logkit_common.sh`, and `donor_telemetry_contract` in `tests/asb_system.sh` asserts both. The two copies once diverged — the manual report was tightened while every full-day archive kept the weaker single-signal logic — which is why the assertions test for the *shape* of the verdict rather than its wording.

`network_trace.txt` records live route and TCP state followed by ASB network provenance. For every `net_congestion` and `net_qdisc` global/per-link key the snapshot reports the requested config and the last result from `net_apply_result` (`ok`, `pending`, `failed`, `unavailable` or `not_applied`). The current kernel qdisc/congestion values remain the live authority. Its `# wifi link` block (fix178) is one `link:` line - frequency and band, RSSI, link speed, Wi-Fi standard - from `cmd wifi status` or the wifi dump; the SSID and BSSID are not recorded.

`kernel_params.txt` records ZRAM compression/size/stats where exported and `/proc/pressure/memory` lines. Memory PSI is read-only and must not be interpreted as a request to rebuild ZRAM or alter VM policy. This is specifically designed to distinguish a genuine memory-pressure hypothesis from an unrelated night-drain cause.

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

## `state_transitions.txt` — P0 source transition trace

Written by `lk_emit_state_transitions()` from `status_watch.txt`. A line is emitted for an FSM-state change **or** for a change in thermal CPU source, confidence, rejected type, or rejected raw value. The trace includes `cpu_src`, `conf`, and `rejected=<type>(raw=<raw>)`. Raw values retain their native scale and are not degrees Celsius. This makes a rejected `socd` scale mismatch visible even where the FSM remains in the same state.

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
