# 🚀 AutoSystemBoost — Changelog

---

## V29 — 🏗️ Operational Maturity & PowerHAL-Aware Intelligence

> **V28 = governor knows who to trust and when to step aside.**
> **V29 = the module becomes self-diagnosing, honest about its limits, and aware of vendor interference.**

---

### 🔋 Battery Threshold Fix for SM8850-AC

SD8 Elite Gen 5 (8x Oryon cores) reports `loadavg` 6-10 even at idle. Previous thresholds caused 56% HEAVY domination in battery screen-on.

| Parameter | V28 | V29 | Why |
|:----------|:---:|:---:|:----|
| `bat_moderate_load_enter` | 5.0 | **10.0** | loadavg 6-10 in idle |
| `bat_heavy_load_enter` | 6.0 | **15.0** | HEAVY only on real load |

**Self-tune bounds updated:**

| Direction | Parameter | V28 cap | V29 cap |
|:----------|:----------|:-------:|:-------:|
| Tighten | bat_moderate | 10.0 | **15.0** |
| Tighten | bat_heavy | 8.0 | **20.0** |
| Relax floor | bat_moderate | 3.0 | **8.0** |
| Relax floor | bat_heavy | 4.0 | **10.0** |

**Result from device testing:** battery idle_q jumped from 30 to **94**, wake/h dropped from 7.9 to **0.5**.

---

### 🏭 PowerHAL-Aware Headroom Telemetry

Governor now tracks vendor frequency clamping per-session, explaining **why** performance is limited.

**5 new FSM fields** accumulated every tick:
- `ses_headroom_sum` / `ses_headroom_samples` — for average
- `ses_headroom_min` — worst headroom in session
- `ses_headroom_below70` — ticks under throttle threshold
- `ses_headroom_below50` — ticks under severe clamp

**5 new session_history fields:** `hr_avg`, `hr_min`, `hr_b70`, `hr_b50`, `hr_n`

**Session report `🏭 Vendor Clamp / Headroom` section:**
- Per-session classification: `reachable` / `vendor_clamp` / `thermal` / `mixed_limited`
- `early_collapse` flag when headroom drops fast
- Separate aggregates for Performance and Balanced
- Duration-weighted (hr_n) dominant limiter verdict

---

### ⚡ Conditional Headroom Reads

Headroom sysfs read (`/sys/kernel/msm_performance/parameters/cpu_max_freq`) skipped when not useful:

| Profile | When headroom is read |
|:--------|:---------------------|
| Performance | Always |
| Balanced | Always |
| Battery | Only `screen_on && state >= MODERATE` |

`headroom_valid` flag ensures skipped reads don't pollute telemetry with fake 100% samples.

**Savings:** ~5760 fewer syscalls during 8h screen-off sleep.

---

### 🔧 Atomic File Writes

`atomic_write_file()` helper: write to `.tmp`, `fsync()`, `rename()`. Used by pstats and state files. Eliminates corrupted JSON after crashes.

---

### 🔍 Stale Session Sweeper

`sweep_stale_session()` runs at governor startup, detects improperly closed sessions from previous boot, logs warning.

---

### 🛡️ Service.sh Startup Guards (4 new functions)

| Function | What |
|:---------|:-----|
| `asb_device_guard()` | SoC tier detection (flagship/high/generic) |
| `asb_probe_paths()` | Verifies 5 sysfs paths writable |
| `asb_conflict_scan()` | Scans for conflicting modules |
| `asb_drift_check()` | Post-apply verification with 3 severity levels |

---

### 🚨 Watchdog Safe Mode

3 consecutive governor crashes → enters `balanced-safe`, writes `/dev/.asb/safe_mode`, stops governor. Prevents boot loops.

---

### 📦 Build Manifest

`install.sh` generates `runtime/build_manifest.json` at install time with:
- ASB version, build date
- SHA256 hashes of governor binary + profiles + governor.conf

---

### 🛠️ New Tool Scripts

| Tool | Lines | Purpose |
|:-----|:-----:|:--------|
| `tools/asb_doctor.sh` | 192 | One-shot module health check |
| `tools/asb_lint.sh` | 131 | Config sanity validation |
| `tools/asb_release_pack.sh` | 68 | Release hygiene automation |

---

### 📊 Python Report Upgrades

**`asb_session_report.py`:**
- 🏭 Vendor Clamp / Headroom section with `classify_headroom()`
- Battery Root Cause section (cause-aware: wake_noise / screen_on / no_settle)
- Data Quality with trust breakdown (clean/partial/dirty per profile)
- Duration-weighted `hr_n` aggregate with confidence levels
- `median()` and `p90()` in trends table

**`asb_analyze.py`:**
- Session-scoped parsing with explain confidence (high/medium/low)
- Incomplete timeline warning

---

### 🐛 Bug Fixes

| Bug | Fix |
|:----|:----|
| Unicode in C source (em-dash, arrows) | Replaced with ASCII equivalents |
| Skipped headroom polluting telemetry | `headroom_valid` flag gates accumulation |
| Battery HEAVY domination (56% of session) | Thresholds raised to 10.0/15.0 |

---

### ✅ Summary

| Feature | Status |
|:--------|:------:|
| Battery thresholds 10.0/15.0 for SM8850-AC | ✅ |
| Headroom telemetry (5 fields per session) | ✅ |
| Vendor Clamp report section with classifier | ✅ |
| Conditional headroom reads (battery skip) | ✅ |
| headroom_valid flag (honest telemetry) | ✅ |
| Atomic file writes | ✅ |
| Stale session sweeper | ✅ |
| 4 startup guard functions | ✅ |
| Watchdog safe mode (3 strikes) | ✅ |
| Build manifest with SHA256 | ✅ |
| 3 new tool scripts (doctor/lint/release) | ✅ |
| Python report: headroom + trust + root cause | ✅ |
| Unicode cleanup | ✅ |

**V29 makes ASB not just smarter, but honest — it knows what it can control, what vendor overrides, and tells you exactly which one limited your session.**

---
---

## V28 — 🛡️ Trust Architecture & Benchmark Intelligence

> **V27 = consistency and transparency.**
> **V28 = governor knows who to trust and when to step aside.**

---

### 🔋 Battery Trust Gate

- `battery_session_trust()` returns DIRTY/PARTIAL/CLEAN
- `battery_fail_cause()` returns NONE/WAKE_NOISE/SCREEN_ON/NO_SETTLE
- Dirty/partial sessions skip learning AND pstats update
- Anti-oscillation cooldown (2 sessions after tighten, 1 after relax)
- Reverse path: idle_q >= 70 relaxes thresholds back toward defaults

### 🎯 Benchmark Bypass (Dual-World)

- `intent=benchmark` → no auto-degrade, no self-tune, no pstats update
- Sessions recorded with `learn_exempt=1`
- Startup gate not poisoned by benchmark thermal data

### 🧠 Intent Classifier

- 6 intents: benchmark / long_game / idle / mixed / sleep_idle / unknown
- Classification window: 600s
- Benchmark detection: thermal + performance profile

### ⚡ Performance Profile Tuned

| Parameter | V27 | V28 |
|:----------|:---:|:---:|
| CPU_MIN_LITTLE | 2112000 | **1497600** |
| CPU_MIN_BIG | 2438400 | **1881600** |
| GPU_MIN_PCT | 25% | **10%** |

Lower floors = less idle power, same peak performance. AnTuTu: 3,969,550 (within noise of V27's 3,993,462).

### 📊 Per-Profile Persistent Stats

Separate pstats files: `pstats_battery.json`, `pstats_balanced.json`, `pstats_performance.json`.

### 🔊 BT Audio

BT A2DP top 3 volume points: +1dB each.

---
---

## V27 — 🔗 Consistency & Transparency

> **V26 = governor learns in real time.**
> **V27 = the module stops lying about what it actually does.**

---

### 🔧 service.sh Path Fix

`service.sh` now searches `runtime/profile_core.sh` first (was only `common/`).

### 🧠 Learner Persistence

`learn.bin` moved from `/dev/.asb/` (tmpfs, lost on reboot) to `/data/.../runtime/learn.bin` (persistent). One-time migration from old path.

### 📊 Effective Config in State + Status JSON

8 `eff_*` fields in state file + 5 in status JSON showing real runtime values after mode overrides and self-tune.

### 📝 Startup Diag

`diag: eff` log line at session start with all effective config values.

---
