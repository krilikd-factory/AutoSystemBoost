# 🚀 AutoSystemBoost V30 — Changelog

---

## V30 — ⚡ Self-Describing Intelligence & Low-Overhead Runtime

> **V29 made ASB honest about vendor limits.**
> **V30 makes every session explain itself — and the module learn to be quiet when it should be.**

Three pillars: **self-describing sessions** · **runtime diet** · **semantic truth**

---

### 🔋 Adaptive Tick Interval — Governor Sleeps When You Sleep

The biggest real-world improvement in V30.

Previously, the governor woke up every 5 seconds even during deep sleep. Now it adapts:

| State | Tick interval | Change |
|:------|:------------:|:------:|
| Screen ON (any profile) | 2s | — |
| Screen OFF, active states | 5s | — |
| Battery + screen OFF + DEEP_IDLE | **10s** | **2x slower** |

**Impact:** During 8 hours of sleep, governor wakeups drop from **5,760 to 2,880** — a 50% reduction. Each wakeup means CPU exits deep sleep, reads sysfs, checks FSM, and goes back to sleep. Fewer wakeups = less battery drain from the module itself.

**Why it's safe:** FSM uses `clock_gettime(CLOCK_MONOTONIC)` for all timing. Dwell thresholds, state durations, session timestamps — all real seconds, never tick counts. Longer interval just means less frequent checking of a state that rarely changes.

---

### 🎯 Cost-Aware Sensor Scheduler

Not all metrics need to be read every tick. V30 introduces a three-tier polling strategy:

| Tier | Headroom | Thermal zones | GPU/CPU/Battery | When |
|:-----|:--------:|:------------:|:---------------:|:-----|
| **Full** | ✅ | ✅ | ✅ | Performance, Balanced, Battery active |
| **Reduced** | ❌ | ✅ | ✅ | Battery screen-on light states |
| **Sparse** | ❌ | **Every 3rd tick** | ✅ | Battery screen-off DEEP_IDLE |

Combined with adaptive tick: in the most common overnight state, the module reads thermal zones once every **30 seconds** instead of every 2 seconds.

`headroom_valid` flag ensures skipped headroom reads never pollute session telemetry with fake 100% samples.

---

### 📊 Self-Describing Sessions (schema v7)

Governor now classifies each session at close time. No Python needed to understand what happened.

**10 new fields** computed in C and written to `session_history.jsonl`:

| Field | Purpose | Example values |
|:------|:--------|:---------------|
| `limiter` | What limited the session | `reachable` · `vendor_clamp` · `thermal` · `mixed` |
| `reach` | Reachability score 0-100 | `(cap_eff + hr_avg) / 2` |
| `bat_reason` | Why battery session was bad | `wake_noise` · `screen_on` · `no_settle` |
| `conf` | Data confidence | `high` · `medium` · `low` |
| `sig` | Session signature | `clean_sleep` · `thermal_limited` · `vendor_clamped` · `stable_dominant` |
| `anomaly` | Anomaly flag | `extreme_temp` · `efficiency_collapse` · `failed_settle` · `wake_spike` |
| `mid_tune` | Mid-session tuning activity | `none` · `light` · `heavy` |
| `mid_n` | Number of mid-tune adjustments | 0-N |
| `mid_dir` | Tuning direction | -1 (down) / 0 / 1 (up) |
| `hr_avg` / `hr_min` / `hr_b70` / `hr_b50` / `hr_n` | Headroom telemetry | Per-session vendor clamp data |

**Example v7 record:**
```json
{"v":7, "profile":"performance", "limiter":"thermal", "reach":65,
 "sig":"thermal_limited", "anomaly":"extreme_temp", "conf":"high", ...}
```

---

### 🛡️ OTA Quarantine

After kernel update, OTA, or ASB version change — old learning data may be toxic.

**How it works:**
1. On governor startup: reads `/proc/version` + `ASB_VERSION` → fingerprint
2. Compares with stored `runtime/env_fingerprint`
3. If changed → `quarantine_remaining = 3` on all per-profile pstats
4. During quarantine: sessions recorded in history but pstats not updated
5. Only quality sessions (dur ≥ 120s, not benchmark) count down the quarantine

---

### 📈 Cause Streak Detection

One bad session is noise. Three consecutive same-cause sessions is a pattern.

**New pstats fields:** `cstrk` (streak count), `ctype` (cause type 0-5)

| Type | Cause | Triggered by |
|:----:|:------|:-------------|
| 0 | none | — |
| 1 | wake_noise | Battery with excessive wakeups |
| 2 | screen_on | Battery disrupted by screen activity |
| 3 | no_settle | Battery that never reached idle |
| 4 | vendor_clamp | Performance limited by vendor PowerHAL |
| 5 | thermal | Performance limited by temperature |

At streak ≥ 3: logged as `cause_streak: vendor_clamp x4 consecutive`.

---

### 🏭 Vendor Clamp / Headroom Report Section

`session_report.py` now includes a dedicated headroom analysis section:

- Per-session classification: `reachable` / `vendor_clamp` / `thermal` / `mixed_limited`
- `early_collapse` flag when headroom drops fast
- Separate aggregates for Performance and Balanced profiles
- Duration-weighted (`hr_n`) dominant limiter verdict
- Python report prefers C-side `limiter` from v7 history, falls back for older records

---

### 🎭 Semantic Truth Fixes

**`thermal_limited` beats `stable_dominant`:**
Profile-aware thermal thresholds (≥90°C performance, ≥80°C balanced) ensure hot sessions are never labeled as merely "stable."

**`clean_sleep` made stricter:**
Requires `conf=high` + `idle_q ≥ 70` + zero heavy-load time. Short noisy sessions no longer pretend to be clean idle.

**`reach` capped under extreme temperature:**
`extreme_temp` anomaly → reach ≤ 75. If `t2s < 90` → reach ≤ 65. A 103°C session no longer claims reach=93.

**`efficiency_collapse` anomaly (NEW):**
Performance/balanced session with `cap_eff < 45` + (`efficiency < 60` or `degraded`) + `dur ≥ 600s` → honest anomaly tag instead of `none`.

**`failed_settle` anomaly relaxed:**
Battery session with `dur ≥ 900s` + `idle_q < 25` — no longer requires `wake ≥ 8`. Poor idle quality alone is diagnostic.

**`extreme_temp` profile-aware:**
Performance: ≥ 98°C. Others: ≥ 100°C. Aligns C-side truth with Python report.

---

### 🧹 Boundary Session Filter

Hot carry-over sessions from profile switches no longer pollute history:

- `dur ≤ 0` → skip for ALL profiles (no real session has zero duration)
- `dur < 60` + non-battery + non-benchmark → skip (short thermal tail from profile switch)

---

### 🔧 New Tool: `asb_stock_mode_probe.sh`

Captures system state snapshots for comparing OxygenOS power modes (Balance / Power Save / High Performance). Reads CPU/GPU policy, thermal zones, scheduler tunables, Android settings, OnePlus props, and framework state.

```
sh asb_stock_mode_probe.sh balance
sh asb_stock_mode_probe.sh highperf
sh asb_stock_mode_probe.sh diff balance highperf
```

---

### ✅ V30 Summary

| Category | Feature | Impact |
|:---------|:--------|:-------|
| ⚡ Runtime | Adaptive tick 5s→10s in deep idle | **50% fewer wakeups overnight** |
| ⚡ Runtime | Thermal sparse polling (every 3rd tick) | **~67% fewer thermal reads in idle** |
| ⚡ Runtime | Headroom skip in battery | **Zero msm_performance reads when idle** |
| 📊 Truth | 10 self-describing fields in history v7 | Sessions explain themselves |
| 📊 Truth | C-side limiter/reach/bat_reason | Single source of truth |
| 🛡️ Safety | OTA quarantine (3-session learning pause) | Protects against stale memory |
| 📈 Pattern | Cause streak detection | Identifies recurring problems |
| 🎭 Semantic | 6 classification fixes | Truth-layer no longer too kind |
| 🧹 Hygiene | Boundary session filter | No more thermal carry-over noise |
| 🔧 Tools | Stock mode probe script | Reverse-engineer OxygenOS modes |

**Zero changes to:** battery thresholds (10.0/15.0) · benchmark isolation · trust gate · profile caps · governor decision logic

---

> **V29 taught ASB to see. V30 taught it to speak honestly — and to be quiet when there's nothing to say.**

---

## Previous Releases

### V29 — 🏗️ Operational Maturity & PowerHAL-Aware Intelligence

Battery threshold fix for SM8850-AC (10.0/15.0), headroom telemetry (5 session fields), conditional headroom reads, vendor clamp report section, atomic writes, stale session sweeper, 4 startup guard functions, watchdog safe mode (3 strikes), build manifest with SHA256, 3 new tool scripts (doctor/lint/release_pack).

### V28 — 🛡️ Trust Architecture & Benchmark Intelligence

Battery trust gate (dirty/partial/clean), benchmark dual-world bypass (learn_exempt), intent classifier (6 intents), per-profile persistent stats, performance profile tuned (lower idle floors), BT audio top volume boost.

### V27 — 🔗 Consistency & Transparency

service.sh path fix, learner persistence (tmpfs→persistent), effective config in state/status JSON, startup diagnostics.

---
