# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Current_Release-V38-16a34a?style=for-the-badge" alt="V38">
  <img src="https://img.shields.io/badge/Previous-V37-6b7280?style=for-the-badge" alt="V37">
  <img src="https://img.shields.io/badge/versionCode-380-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## 🚀 V38 — Thermal Source Correctness + Long-Gaming Cooling

> **V37 made thermal telemetry _honest_ at the read layer.**
> **V38 makes the thermal source _binding_ correct, cools the performance profile for long gaming sessions, fixes a silent CPU cap desync in the shell layer, and ships a full diagnostic logkit.**

V38 is the result of **9 real-device iteration cycles (RC1 → RC9)** driven entirely by observed behavior in on-device logs — extended COD Mobile 144 fps sessions, overnight battery sleep, and typical daytime mixed use on OnePlus 15 (SM8850 / Snapdragon 8 Elite Gen 5). Every change below is grounded in telemetry, not theory.

---

### 📊 Measured Impact — V37 → V38

<table align="center">
<tr><th colspan="4">🔥 Long Gaming (COD 144fps, sustained load)</th></tr>
<tr>
  <th>Metric</th>
  <th>V37 era</th>
  <th>V38 (RC9 validated)</th>
  <th>Change</th>
</tr>
<tr>
  <td><b>SUSTAINED % of session</b></td>
  <td align="center">~65.8 %</td>
  <td align="center"><b>8.9 %</b></td>
  <td align="center">🟢 <b>−7.4×</b></td>
</tr>
<tr>
  <td><b>Longest SUSTAINED lock</b></td>
  <td align="center">297 ticks (~15 min)</td>
  <td align="center"><b>&lt; 30 ticks</b></td>
  <td align="center">🟢 broken by FSM escape</td>
</tr>
<tr>
  <td><b>CPU max temp (cpu-prime)</b></td>
  <td align="center">93 °C (spikes)</td>
  <td align="center"><b>76 °C real</b></td>
  <td align="center">🟢 honest + cooler</td>
</tr>
<tr>
  <td><b>CPU avg temp</b></td>
  <td align="center">~59 °C</td>
  <td align="center"><b>43.7 °C</b></td>
  <td align="center">🟢 −15 °C</td>
</tr>
<tr>
  <td><b>Surface hotspot max</b></td>
  <td align="center">53 °C</td>
  <td align="center"><b>49 °C</b></td>
  <td align="center">🟢 −4 °C</td>
</tr>
<tr>
  <td><b>thermal_cpu_type drift to socd</b></td>
  <td align="center">Persistent (hours)</td>
  <td align="center"><b>Never</b></td>
  <td align="center">🟢 fixed</td>
</tr>
<tr>
  <td><b>raw_too_low streaks</b></td>
  <td align="center">442 ticks observed</td>
  <td align="center"><b>0 ticks</b></td>
  <td align="center">🟢 fixed</td>
</tr>
</table>

<table align="center">
<tr><th colspan="4">🌙 Overnight Battery Sleep</th></tr>
<tr>
  <th>Metric</th>
  <th>V37</th>
  <th>V38</th>
  <th>Status</th>
</tr>
<tr><td>Outcome</td><td align="center">clean_night</td><td align="center"><b>clean_night</b></td><td align="center">🟢 preserved</td></tr>
<tr><td>idle_q</td><td align="center">~95</td><td align="center"><b>98</b></td><td align="center">🟢 improved</td></tr>
<tr><td>Wake events / night</td><td align="center">1–2</td><td align="center"><b>0</b></td><td align="center">🟢 improved</td></tr>
<tr><td>Bat trust</td><td align="center">2 (CLEAN)</td><td align="center"><b>2 (CLEAN)</b></td><td align="center">🟢 preserved</td></tr>
</table>

---

## 🔬 What Actually Changed

### 🌡 Thermal Source Binding Correctness

V37 caught broken `socd` readings at the **read layer**. V38 fixes the problem at the **binding layer** — the layer that chooses which sensor the governor trusts for the entire session.

#### 1️⃣ Rescan no longer clobbers a validated CPU zone

<details>
<summary><b>The bug</b> (click to expand)</summary>

OnePlus 15 (SM8850) has **no `shell_*` skin sensors**, so `g_thermal_skin_zone` stays `-1` forever. The rescan trigger in `metrics_read_thermal()` is:

```c
if (skin_zone < 0 || cpu_zone < 0 || surface_zone < 0) rescan();
```

Since `skin_zone` never became ≥ 0, `thermal_discover()` re-fired **every 60 seconds for the entire uptime**. Each re-run reset `g_thermal_cpu_zone = -1` at the top and re-ran discovery. If `socd` happened to be momentarily reading a plausible value during one of those rescans, it won priority-1 pick, the cross-check against peer sensors passed at that exact moment, and the governor stuck to `socd` for the rest of the session — even after `socd` returned to reporting `raw=0` for 400+ consecutive ticks.
</details>

**The fix:** `thermal_discover()` now preserves an already-validated CPU binding across rescans. Skin and surface zones can still be re-scanned freely; only CPU — which has the fail-alive-fail pattern — is protected.

```c
int preserve_cpu = (g_thermal_cpu_zone >= 0 && g_thermal_cpu_type[0] != '\0');
if (!preserve_cpu) { /* clear and re-discover */ }
else { best_cpu_prio = 0; /* lock in validated binding */ }
```

#### 2️⃣ Runtime `socd` rebind on persistent `raw_too_low`

If primary is `socd` **AND** `raw_too_low` streak reaches ≥ 5 consecutive ticks **AND** fallback zone is known **AND** fallback now reads plausibly (15–120 °C) → V38 **permanently rebinds** `g_thermal_cpu_zone` to the fallback zone. Unlike V37's per-tick workaround, this is a real binding change. No flapping — once on fallback the condition no longer matches.

```
[HH:MM:SS] socd runtime rebind (streak=5, old_zone=59 -> cpu-1-1-0 at zone26, fb_now=54C)
```

This specifically resolves the 442-tick raw_too_low streak observed in earlier RC logs.

#### 3️⃣ Cross-validated sensor spike guard

Real logs showed `socd` reporting single-tick spikes of 93 °C while adjacent sensors sat at 54 °C and the previous tick was also ~55 °C. That is physically impossible — CPU cores cannot rise 30+ °C in one read without the rest of the die moving too.

V38 rejects a reading when:
- Current read jumps ≥ 25 °C above last value, **AND**
- Fallback sensor reads ≥ 25 °C colder than current

The spike is held at last good value, `temp_invalid_reason="spike"` is reported, throttling is not advanced. Legitimate fast heating still passes because both sensors would rise together.

---

### 🎮 Performance Profile — Cooling Pass

Data-driven trim based on observed behavior under real 144 fps gaming. **Every value below is grounded in on-device measurements.**

<table>
<tr><th>Parameter</th><th align="center">V37</th><th align="center">V38</th><th>Δ / Reason</th></tr>
<tr><td><code>CPU_CAP_BIG</code></td>         <td align="center">3 264 000</td><td align="center"><b>2 976 000</b></td><td>🟦 −288 MHz — less long-session heat</td></tr>
<tr><td><code>CPU_MIN_BIG</code></td>         <td align="center">1 497 600</td><td align="center"><b>1 113 600</b></td><td>🟦 Lower idle-at-load floor</td></tr>
<tr><td><code>CPU_CAP_LITTLE</code></td>      <td align="center">2 995 200</td><td align="center"><b>3 072 000</b></td><td>🟩 Balance little cluster</td></tr>
<tr><td><code>CPU_MIN_LITTLE</code></td>      <td align="center">1 324 800</td><td align="center"><b>1 190 400</b></td><td>🟦 Proportional trim</td></tr>
<tr><td><code>GPU_MAX_PCT</code></td>         <td align="center">92 %</td>     <td align="center"><b>84 %</b></td>     <td>🟦 GPU = second biggest heat contributor</td></tr>
<tr><td><code>GPU_MIN_PCT</code></td>         <td align="center">5 %</td>      <td align="center"><b>10 %</b></td>     <td>🟩 Prevent 0↔max yo-yo</td></tr>
<tr><td><code>GPU_IDLE_TIMER</code></td>      <td align="center">64</td>       <td align="center"><b>48</b></td>       <td>🟦 Faster GPU idle entry</td></tr>
<tr><td><code>GPU_THERMAL_PWRLEVEL</code></td><td align="center">2</td>        <td align="center"><b>1</b></td>        <td>🟦 Earlier GPU thermal clamp</td></tr>
<tr><td><code>WALT_ED_BOOST</code></td>       <td align="center">35</td>       <td align="center"><b>30</b></td>       <td>🟦 Less scheduler start-aggression</td></tr>
<tr><td><code>WALT_TOPAPP_WEIGHT</code></td>  <td align="center">160</td>      <td align="center"><b>150</b></td>      <td>🟦 Calmer top-app boost</td></tr>
<tr><td><code>UCL_TOP_MIN</code></td>         <td align="center">95</td>       <td align="center"><b>88</b></td>       <td>🟦 Less greedy UCL top</td></tr>
<tr><td><code>SCHED_RATE</code></td>          <td align="center">1 000</td>    <td align="center"><b>800</b></td>      <td>🟩 Finer scheduling granularity</td></tr>
<tr><td><code>SCHED_UP_RATE</code></td>       <td align="center">400</td>      <td align="center"><b>300</b></td>      <td>🟩 Quicker ramp-up</td></tr>
<tr><td><code>VM_SWAPPINESS</code></td>       <td align="center">20</td>       <td align="center"><b>12</b></td>       <td>🟩 Less swap churn</td></tr>
<tr><td><code>VM_DIRTY_EXPIRE</code></td>     <td align="center">1 500</td>    <td align="center"><b>1 000</b></td>    <td>🟩 Sustained write rhythm</td></tr>
<tr><td><code>NET_BUDGET</code></td>          <td align="center">400</td>      <td align="center"><b>480</b></td>      <td>🟩 More consistent net throughput</td></tr>
</table>

🟦 = thermal change · 🟩 = scheduling/IO tuning

---

### 🧠 FSM — Time-Based `SUSTAINED` Escape

<details>
<summary><b>Why it was needed</b></summary>

With V37 logic, the device could settle into a steady-state where temperature floored at 55–67 °C under load. With `sustained_temp_exit = 55`, the exit condition was **literally unreachable** for the entire game session — FSM could stay locked in SUSTAINED for 15+ minutes even after thermal trend went flat.
</details>

V38 adds a time-based escape path in `asb_fsm.h`:

```
if in SUSTAINED ≥ 180 s
   AND temp ≤ sustained_temp_enter − 3
   AND thermal_trend ≤ 3 (not rising)
→ allow exit transition, sustained_reason = 2 (time_based_escape)
```

This preserves thermal safety (temp must still be meaningfully below the enter threshold) but breaks the lock so the device can try running at normal caps. If it gets hot again, the normal re-entry path re-clamps.

Also `perf_sustained_temp_exit` raised **55 → 56 °C**: with `enter=59` and `exit=56` (3 °C hysteresis), the device can leave SUSTAINED during brief cool-offs without flapping.

Visible in logs as:

```
exit_sustained: time_based_escape t=56degC (exit_thresh=56) -> HEAVY cooldown=20s efficiency=81/100
```

---

### 🔌 Shell-Layer CPU Cap Desync — Fixed

`service.sh :: apply_screen_aware_caps()` had a screen-on performance branch that **hardcoded** `CPU_CAP_BIG=3648000`, silently overriding whatever cooler value the profile specified. This was not theoretical — the governor would correctly throttle to the profile's cap, then the next screen transition would reassert the hardcoded higher cap.

V38 removes the override. The shell reconcile path now honors the profile's `CPU_CAP_BIG` across all screen states. Verified by the new `cap_verify.txt` telemetry file in logkit runs.

**Bonus fix** (`action.sh`): `MODID="AutoSystemBoost"` is now declared explicitly, so intent extras like `-e id "$MODID"` no longer pass empty strings.

---

### 🩺 `last_sustained_reason` — Full Diagnostic Coverage

V37 reported only `thermal` or `gaming_unreachable`. V38 adds `time_based_escape` (the FSM path above) via a canonical helper used at **every** output surface:

```c
static inline const char *sustained_reason_name(int r) {
    switch (r) {
        case 0:  return "thermal";
        case 1:  return "gaming_unreachable";
        case 2:  return "time_based_escape";
        default: return "unknown";
    }
}
```

Applied at:
- `write_state()` — state file `last_sustained_reason=`
- `build_status_json()` — live JSON `"last_sustained_reason"`
- `exit_sustained` log line — prepended when reason=2 fires, then cleared so the next entry classifies cleanly

Previous inline ternaries silently mapped `reason=2` → `"thermal"`, hiding the entire mechanism from diagnostics.

---

### 📦 `tools/logkit/` — Scenario-Scoped Log Collection

Brand-new `tools/logkit/` directory with three scenario-specific capture scripts plus a shared common library.

<table>
<tr><th>Script</th><th>Scenario</th><th>Duration</th><th>Poll</th><th>Snapshot</th></tr>
<tr><td><code>asb_log_battery_sleep.sh</code></td><td>🌙 Overnight, screen OFF</td><td>up to 10 h</td><td align="center">60 s</td><td align="center">30 min</td></tr>
<tr><td><code>asb_log_battery_mixed.sh</code></td><td>☀️ Daytime mixed use</td><td>up to 8 h</td><td align="center">20 s</td><td align="center">10 min</td></tr>
<tr><td><code>asb_log_perf.sh</code></td><td>🎮 Long heavy gaming</td><td>up to 2 h</td><td align="center">3 s</td><td align="center">10 min</td></tr>
<tr><td><code>_asb_logkit_common.sh</code></td><td colspan="4">Shared module / zone discovery, event filters, packaging</td></tr>
<tr><td><code>README.md</code></td><td colspan="4">Usage guide + diagnostic checklist</td></tr>
</table>

Each run captures raw per-tick telemetry (`status_watch.txt`, `perf_trace.txt`, `battery_trace.txt`) **plus** pre-extracted event files:

| File | Answers |
|:--|:--|
| `events_sustained.txt` | When and why did FSM enter/exit SUSTAINED? |
| `events_thermal_source.txt` | Did the governor rebind a bad sensor at runtime? |
| `events_battery_trust.txt` | Is TRUST_PARTIAL catching daytime sessions? |
| `events_cap_apply.txt` | Does shell reconcile ever disagree with governor? |
| `events_headroom.txt` | Is stuck_100 firing correctly on SM8850? |
| `cap_verify.txt` | Actual `scaling_max_freq` vs profile `CPU_CAP_BIG` |
| `clean_start_gate.txt` | Did perf capture start from a clean state? |
| `state_transitions.txt` | Compact FSM state-change log |

**Key engineering features**:

- 🎯 **Clean-start gate** (`asb_log_perf.sh`): Before capture begins, waits up to 60 s for `profile=performance AND temp_valid=1 AND (temp>20 OR cpu_type != socd)`. Prevents capturing stale pre-switch tails.
- 🔎 **Module-relative binary lookup**: `lk_status_json()` checks `$MODDIR/bin/asb` before `$PATH`. Fixes the bug that made earlier captures write `{}` for every status snapshot.
- ⏱ **Session-time event slicing**: Event files filter `governor.log` by `LK_START_EPOCH` so prior sessions don't pollute current analysis.
- 📍 **Per-boot zone aliasing**: Emits `thermal_zones_aliases.sh` mapping named zones to their current IDs (OP15 renumbers zones every boot).

Final zip lands at `/sdcard/asb_<scenario>_<timestamp>.zip` — ready to upload for any future diagnostic work.

---

### ⚙️ Governor Configuration — Thresholds & Hysteresis

Refinements to `config/governor.conf`:

<table>
<tr><th>Parameter</th><th align="center">V37</th><th align="center">V38</th><th>Why</th></tr>
<tr><td><code>perf_sustained_temp_enter</code></td><td align="center">62</td><td align="center"><b>59</b></td><td>Earlier thermal discipline</td></tr>
<tr><td><code>perf_sustained_temp_exit</code></td><td align="center">54</td><td align="center"><b>56</b></td><td>Hysteresis shifted up (55 was unreachable)</td></tr>
<tr><td><code>perf_sustained_level</code></td><td align="center">0.75</td><td align="center"><b>0.70</b></td><td>Stronger SUSTAINED power reduction</td></tr>
<tr><td><code>perf_hot_guard_temp</code></td><td align="center">68</td><td align="center"><b>63</b></td><td>Earlier hot guard trigger</td></tr>
<tr><td><code>gaming_gap_thresh</code></td><td align="center">1 500 000</td><td align="center"><b>1 650 000</b></td><td>Less nervous gaming_unreachable</td></tr>
<tr><td><code>gaming_gap_ticks</code></td><td align="center">4</td><td align="center"><b>5</b></td><td>More patience before verdict</td></tr>
<tr><td><code>gaming_retry_cooldown_s</code></td><td align="center">20</td><td align="center"><b>18</b></td><td>Quicker retry after cool-off</td></tr>
<tr><td><code>gaming_retry_temp_max</code></td><td align="center">52</td><td align="center"><b>50</b></td><td>Require cooler state before retry</td></tr>
<tr><td><code>sustained_reentry_cooldown_s</code></td><td align="center">30</td><td align="center"><b>24</b></td><td>Less lingering after recent exit</td></tr>
<tr><td><code>balanced_sustained_temp_enter</code></td><td align="center">58</td><td align="center"><b>57</b></td><td>Match perf hysteresis philosophy</td></tr>
<tr><td><code>balanced_sustained_temp_exit</code></td><td align="center">50</td><td align="center"><b>49</b></td><td>Match perf hysteresis philosophy</td></tr>
<tr><td><code>balanced_heavy_load_enter</code></td><td align="center">5.5</td><td align="center"><b>6.2</b></td><td>Less aggressive balanced heavy detection</td></tr>
<tr><td><code>balanced_warmup_bypass_temp</code></td><td align="center">60</td><td align="center"><b>59</b></td><td>Earlier warmup bypass</td></tr>
<tr><td><code>balanced_warmup_grace_s</code></td><td align="center">45</td><td align="center"><b>50</b></td><td>Slightly longer warmup grace</td></tr>
<tr><td><code>bat_fast_idle_s</code></td><td align="center">10</td><td align="center"><b>8</b></td><td>Quicker battery idle entry</td></tr>
<tr><td><code>bat_heavy_load_enter</code></td><td align="center">18.0</td><td align="center"><b>18.5</b></td><td>Finer battery heavy threshold</td></tr>
<tr><td><code>bat_comfort_temp</code></td><td align="center">39</td><td align="center"><b>38</b></td><td>Stricter battery comfort</td></tr>
<tr><td><code>env_iq_quiet</code></td><td align="center">30</td><td align="center"><b>28</b></td><td>Quieter idle-quality classifier</td></tr>
<tr><td><code>quiet_entry_ticks</code></td><td align="center">45</td><td align="center"><b>36</b></td><td>Faster quiet entry</td></tr>
<tr><td><code>quiet_fast_ticks</code></td><td align="center">30</td><td align="center"><b>24</b></td><td>Faster quiet fast path</td></tr>
<tr><td><code>soft_clamp_headroom_pct</code></td><td align="center">70</td><td align="center"><b>72</b></td><td>Slightly wider soft clamp window</td></tr>
<tr><td><code>hard_clamp_headroom_pct</code></td><td align="center">45</td><td align="center"><b>48</b></td><td>Slightly earlier hard clamp</td></tr>
<tr><td><code>clamp_economy_after_s</code></td><td align="center">45</td><td align="center"><b>35</b></td><td>Quicker economy entry after clamp</td></tr>
<tr><td><code>action_waste_threshold</code></td><td align="center">4</td><td align="center"><b>3</b></td><td>Tighter waste accounting</td></tr>
</table>

---

### 🔕 Speaker Hardware Protection Bypass — Removed

`vendor.audio.feature.spkr_prot.enable=false` unconditionally removed from `system.prop`. If the vendor audio stack honored this flag, it could let the amp over-drive speakers under sustained high volume. Removed without replacement.

---

### 🎨 Vendor Config Tuning

Minor refinements to bundled vendor configs (tracks OEM updates since V37):

- 🎯 `system/vendor/etc/perf/perfboostsconfig.xml`, `perfconfigstore.xml` — Rebalanced for sustained throughput
- 📶 `system/vendor/etc/wifi/*/WCNSS_qcom_cfg.ini` — WiFi 6 GHz / VHT160 tuning for TIM Italy regulatory domain
- 🛰 `system/vendor/etc/gps.conf`, `system/vendor/odm/etc/gps.conf` — XTRA / NTP server tuning for EU region

---

### 📋 Honesty Correction

`persist.sys.mqs.gps.rtk=OFF` is now marked **speculative / unproven** in both the `system.prop` inline comment and the docs. OnePlus MQS as a telemetry framework is publicly documented, but the exact semantics of this individual key aren't. V38 keeps it but flags the uncertainty explicitly. Candidate for evidence-based review in V39.

---

## 📁 File Change Summary

### Modified from V37

| Path | What changed |
|:--|:--|
| `src/asb_metrics.h` | 🆕 CPU zone preservation across rescans, runtime socd rebind, cross-validated spike guard |
| `src/asb_fsm.h` | 🆕 Time-based SUSTAINED escape |
| `src/asb_governor.c` | 🆕 `sustained_reason_name()` helper + exit-time classification |
| `service.sh` | 🐛 Removed hardcoded CPU_CAP_BIG override in screen-aware caps path |
| `action.sh` | 🐛 `MODID` declared (fixes empty intent extras) |
| `profiles/performance.sh` | 🧊 Cooling trim across 16 parameters |
| `config/governor.conf` | 🧊 24 threshold refinements |
| `system.prop` | 🔕 Removed speaker hardware protection bypass, added honesty markers |
| `runtime/asb_reconcile.sh`, `asb_utils.sh`, `asb_watchdog.sh` | 🧹 Housekeeping |
| `common/install.sh` | 🧹 Schema + installer refinements |
| `tools/asb_doctor.sh`, `asb_lint.sh` | 🧹 Minor polish |
| `uninstall.sh` | 🧹 Symmetry with install |
| `module.prop`, `update.json` | 📦 V37 → V38 / 370 → 380 |

### New in V38

| Path | Purpose |
|:--|:--|
| `tools/logkit/_asb_logkit_common.sh` | Shared logkit library |
| `tools/logkit/asb_log_battery_sleep.sh` | Overnight sleep capture |
| `tools/logkit/asb_log_battery_mixed.sh` | Daytime mixed use capture |
| `tools/logkit/asb_log_perf.sh` | Heavy gaming capture with clean-start gate |
| `tools/logkit/README.md` | Usage guide |

---

<p align="center">
  <b>🚀 V38 is a data-driven release. Every number came from a real session on a real device.</b>
</p>
