# AutoSystemBoost V33 -- Changelog

---

## V33 -- Thermal Sanity + Battery Intelligence + Performance Maturity

> **V32 taught ASB to stay calm under vendor clamp.**
> **V33 teaches it to tell real heat from PowerHAL noise, understand the quality of every session, and fight smarter -- not harder.**

One principle: **if 92% of your thermal entries are false alarms, you don't need a better throttle -- you need better sensors and smarter gates.**

---

### 🌡️ Thermal Source Discovery

The old sensor was `cpullc-0-0` (little core idle temp) -- jumps 25-65C depending on whether the core is sleeping. Governor entered SUSTAINED at room temperature.

V33 scans all thermal zones with priority ranking:

| Priority | Sensor type | Stability |
|:--------:|:------------|:----------|
| 1 | `cpu-1-1`, `cpuss-0` | Big core cluster -- best |
| 2 | `cpu-1-4`, `cpuss-1` | Prime core |
| 3 | `socd` | SoC die -- stable, slightly delayed |
| 8 | `cpullc` | Little core -- **last resort** |

Sparse zone numbering handled with `continue` (not `break`).

Startup log confirms selection:
```
diag: thermal_cpu=cpu-1-1-0 (zone26) thermal_skin=none (zone-1)
```

---

### 🚫 Thermal Minimum Temperature Floor

**The data:** 24 out of 26 SUSTAINED entries in V32 were at 26-38C (room temperature). `headroom < 70%` set `throttling=1`, but that was PowerHAL being conservative -- not thermal danger.

**Profile-aware floor:**

| Profile | Floor | Rationale |
|:--------|:-----:|:----------|
| Performance | **50C** | 42-47C is PowerHAL conservative |
| Balanced | 40C | Filters room-temp noise |
| Battery | 40C | Filters room-temp noise |

**Verified on COD Mobile logs:**

| Entry | Temp | V32 | V33 |
|:------|:----:|:---:|:---:|
| thermal_cap=1 | 26C | SUSTAINED | **Blocked** |
| thermal_cap=1 | 38C | SUSTAINED | **Blocked** |
| thermal_cap=1 | 42C | SUSTAINED | **Blocked** (perf floor 50C) |
| thermal_cap=1 | 47C | SUSTAINED | **Blocked** (perf floor 50C) |
| thermal_cap=1 | 54C | SUSTAINED | Debounced (needs 2nd tick) |
| thermal_cap=1 | 66C | SUSTAINED | SUSTAINED |
| thermal_cap=1 | 70C | SUSTAINED | SUSTAINED |

**Result: -92% false SUSTAINED entries.**

---

### ⏱️ Debounced Thermal Cap (Performance)

Single-tick `thermal_cap=1` spikes at 50-64C are common PowerHAL transients. For performance, V33 requires confirmation:

- **1 tick at 54C** -- wait, don't enter SUSTAINED yet
- **2 consecutive ticks at 54C** -- confirmed, enter SUSTAINED
- **1 tick at 66C+** -- enter immediately (temp already above threshold)

Battery/balanced: no debounce (instant entry as before).

---

### 🔒 Clamp-Aware Sustained Gate

When `clamp_hold=1` (vendor already confirmed winning), throttling-based SUSTAINED requires temp above `sustained_temp_enter`. Vendor clamp naturally reduces headroom -- that's expected, not thermal danger.

---

### ⏳ Layered Cooldown

After SUSTAINED exit, reentry cooldown adapts to context:

| Situation | Multiplier | Cooldown (base=30s) |
|:----------|:----------:|:-------------------:|
| Normal | x1 | 30s |
| Recovery cautious | x1.5 | **45s** |
| Clamp hold active | x2 | **60s** |

---

### 🛡️ Recovery Cautious Window

After clamp_hold is lifted by recovery probe, module stays cautious for **5 minutes**:

- Sustained reentry cooldown extended (x1.5)
- No immediate return to full aggressive mode
- Prevents "wall disappeared for 1 second, module ran into it again"

---

### 🎯 Benchmark False-Positive Fix

32-minute performance session was classified as `benchmark` at age=35s and stayed that way forever. The downgrade block was dead code (nested inside `!ses_intent_locked`).

**Fix:** Downgrade runs every tick, outside the locked check. After 900s (15min), benchmark demotes to `mixed` or `long_game`. Performance learning re-enabled.

---

### 📊 Clamp Debt

If previous performance session was `vendor_clamped` (futility + clamp_hold) and new session starts within 5 minutes, `ac_budget` is **halved**. Module doesn't charge into the same wall twice.

```
plan: clamp_debt active (prev session vendor_clamped 45s ago), ac_budget=3
```

---

### 🔋 Battery Trust Quarantine

Sessions with `idle_q < 20` or `wakes/hour > 10` are `BAT_TRUST_DIRTY`. No longer contaminate `pstats_battery.json`.

Log shows specific rejection reason:
```
pstats: battery trust=0 (iq=8 wph=7.2 wake=5), skipping per-profile memory update
```

---

### ⚖️ Battery Learning Weights

Instead of binary skip/learn:

| Trust | Alpha weight | Effect |
|:------|:-----------:|:-------|
| CLEAN | 100% | Full learning |
| PARTIAL | **25%** | Reduced influence |
| DIRTY | 0% | Skip entirely |

---

### 🏷️ Battery Outcome Classes

Each battery session classified in `session_history.jsonl`:

| Outcome | Condition |
|:--------|:----------|
| `clean_night` | iq>=40, wph<2, dur>=2h, clean trust |
| `clean_day` | iq>=20, clean trust |
| `wake_noisy` | wph>10 |
| `no_settle` | iq<20, dur>=5min |
| `thermal_warm` | max_temp>=45 |
| `hostile` | dirty trust |
| `mixed` | everything else |

---

### 🔥 Performance Outcome Classes

Each performance session classified:

| Outcome | Condition |
|:--------|:----------|
| `vendor_clamped` | futility + clamp_hold + cap_eff<40 |
| `recovered_clamp` | futility was, but clamp lifted |
| `thermal_limited` | max_temp>=90 or thermal>=3 + sus>=30% |
| `degraded` | auto degraded burst->stable |
| `clean` | no sustained, temp<70 |
| `mixed` | everything else |

---

### 📦 Battery Save Gate + Bootstrap

Battery-aware save gate: `bat_total >= 120` or `dur >= 180`. First meaningful noisy session creates `pstats_battery.json` with neutral values (no learning contamination, doctor stops warning).

---

### 🌙 Smart Night Lock

Battery + screen off reconcile interval adapts to governor state:

| Governor state | Reconcile interval |
|:---------------|:------------------:|
| DEEP_IDLE | **10 min** |
| LIGHT_IDLE | **5 min** |
| Active | 3 min |

---

### 📈 Heartbeat Flush + Boundary Fix

`bat_deep` no longer freezes during long DEEP_IDLE (was stuck at 26s for 9 hours). Session boundary uses session age instead of `fsm_elapsed_sec`.

---

### 🔄 Drift Economy

3+ consecutive PowerHAL drift reconciles (walt-topapp, walt-edboost, walt-ravg, uclamp) trigger extra 120s sleep. Only drift-related reasons count.

---

### 🔧 Shell Fixes

- `action.sh`: MODDIR fallback for KSU Next + profile description sync
- Workflow: dynamic version from `module.prop` (no more hardcoded zip names)

---

### 📊 By The Numbers

| Metric | V32 | V33 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 2,744 | 2,881 | +137 (+5.0%) |
| FSM header lines | 627 | 656 | +29 |
| Metrics header lines | 359 | 387 | +28 |
| False SUSTAINED at room temp | 24/26 | 0/26 | **-100%** |
| Thermal sensor | cpullc (unstable) | cpu-1-1 (stable) | Fixed |
| Battery trust filters | dur only | iq + wph + dur | 3 gates |
| Battery outcomes | 0 | 7 classes | New |
| Performance outcomes | 0 | 6 classes | New |
| Learning model | binary | weighted (3 levels) | Smarter |
| Reconcile battery night | 3 min | 5-10 min | **-70%** |
| Cooldown model | fixed | layered (x1/x1.5/x2) | 3 levels |
| Thermal cap gate | instant | debounced (perf) | Calmer |

---

### 🏛️ Changed Files

| File | What changed |
|:-----|:-------------|
| `src/asb_governor.c` | +137 lines: benchmark fix, battery trust, learning weights, outcome classes, clamp debt, heartbeat flush, boundary fix, thermal diagnostics |
| `src/asb_fsm.h` | +29 lines: thermal floor, debounced cap, clamp-aware gate, layered cooldown, recovery cautious, new FSM fields |
| `src/asb_metrics.h` | +28 lines: priority-based thermal discovery |
| `tools/asb_session_report.py` | Battery + Performance outcome sections |
| `runtime/asb_reconcile.sh` | Smart night lock, drift economy |
| `action.sh` | MODDIR fallback, description sync |
| `.github/workflows` | Dynamic versioning |
| `update.json` | V33/330 |

### Unchanged

Profiles, thresholds, governor.conf, system.prop, overlay files -- **all identical to V32**.

---

> **V32 stopped the module from punching the wall.**
> **V33 stopped it from thinking room temperature is a fire, taught it to remember bad neighborhoods, and gave it the patience to not rush back into trouble.**
