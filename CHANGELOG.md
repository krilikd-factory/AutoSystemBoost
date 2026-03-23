# 🚀 AutoSystemBoost — Changelog

---

## V28 — 🛡️ Trust Architecture & Benchmark Intelligence

> **V27 = governor understands what it's doing and starts smarter.**
> **V28 = governor knows who to trust, how to heal, and when to step aside.**

**Benchmark impact:** 3,969,550 AnTuTu (thermal-limited by Snapdragon 8 Elite Gen 5)
**Battery impact:** stability 72–78/100, idle_q avg 100, wake/h 0.0 on clean screen-off sessions

---

### 🔋 Battery Self-Tune Architecture (Complete Rewrite)

V27 battery self-tune had no quality filter — dirty 30-second sessions and screen-on noise trained the learner with garbage data. V28 introduces a full trust gate system.

**Trust classification:**

| Trust Level | Condition | Learning | Pstats |
|:------------|:----------|:---------|:-------|
| `DIRTY` (0) | Duration < 120s | ❌ Skip | ❌ Skip |
| `PARTIAL` (1) | sleep_idle intent OR long session with insufficient battery signal | ❌ Skip | ❌ Skip |
| `CLEAN` (2) | Everything else | ✅ Tune | ✅ Update |

**Cause-aware self-tune:**

| Cause | Detection | Fix |
|:------|:----------|:----|
| `WAKE_NOISE` | wakes/hour > threshold | Tighten `bat_fast_idle_s` |
| `SCREEN_ON` | screen-on during battery session | Tighten moderate + heavy thresholds |
| `NO_SETTLE` | bat_ttd too low, idle_q too low | Tighten `bat_fast_idle_s` + moderate |
| `NONE` | Good session | No change (or relax if idle_q ≥ 70) |

**Anti-oscillation cooldown:**

| Event | Cooldown |
|:------|:---------|
| After tighten | 2 clean sessions before next tune |
| After relax | 1 clean session before next tune |
| Dirty/partial sessions | Do not consume cooldown |

**Threshold changes:**

| Parameter | V27 | V28 | Why |
|:----------|:---:|:---:|:----|
| `bat_heavy_load_enter` (default) | 4.0 | **6.0** | HEAVY trigger was too sensitive |
| `bat_moderate_load_enter` (default) | 3.0 | **5.0** | MODERATE trigger was too sensitive |
| HEAVY ceiling | 6 | **8** | More headroom before HEAVY |
| HEAVY trigger percent | 10% | **30%** | Avoids false HEAVY on brief spikes |
| Moderate ceiling | 15 | **10** | Tighter moderate band |

**Reverse path (relax):** When idle_q ≥ 70, thresholds relax back toward defaults — prevents over-tightening from locking battery into paranoid mode.

---

### 🏁 Performance Startup Gate (5 Paths)

V27 had 3 startup paths. V28 adds 2 more and introduces `avg_degrade_age` tracking:

| Path | Condition | Action |
|:-----|:----------|:-------|
| 1 | avg_temp ≥ 95°C AND avg_eff < 60% (3+ sessions) | → stable |
| 2 | degrade_count > 50% of sessions | → stable |
| 3 | hot_fail_count ≥ 2 | → stable |
| **4 (new)** | avg_t2s < 90s (3+ sessions) | → stable |
| **5 (new)** | avg_degrade_age > 0 AND < 120s (2+ degrades) | → stable |

**New pstats fields:**

| Field | Type | Description |
|:------|:-----|:------------|
| `avg_degrade_age` | float | EMA of seconds from session start to auto-degrade |
| `bat_tune_cooldown` | int | Anti-oscillation counter for battery self-tune |

**Soft rehabilitation:** Good performance session → `avg_degrade_age += 15s` (cap 300s). Over time, a device that stabilizes earns back burst eligibility.

**Startup history scan filters:** Both `bat_ttd` and `bat_mod` scans skip sessions with `intent:sleep_idle` and `dur < 120s`.

---

### 🎯 Benchmark Bypass — Dual-World Architecture

The most important architectural change in V28. Benchmark and daily performance now live in completely separate policy worlds.

**Problem:** V27's safety mechanisms (auto-degrade, immediate_stable, self-tune) were designed for daily use but catastrophically degraded benchmark scores. A benchmark that hits thermal wall is *expected* — the kernel thermal driver handles hardware protection. ASB adding software degrade on top just cuts burst early and kills score.

**Solution:** When `intent=benchmark`, ASB sets up the aggressive profile and steps aside:

| Layer | Benchmark | Daily (gaming/mixed) |
|:------|:---------:|:--------------------:|
| Auto-degrade (3 paths) | ❌ Skipped | ✅ Active (45%, 120s gate) |
| Immediate_stable | ❌ Burst preserved | ✅ Active |
| Self-tune | ❌ Skipped | ✅ Active |
| Pstats memory update | ❌ Isolated | ✅ Updated |
| Session history | ✅ Recorded | ✅ Recorded |
| Startup gate | ✅ Not poisoned | ✅ Learns from history |
| Kernel thermal protection | ✅ Always active | ✅ Always active |

**Benchmark intent detection:** Requires `have_thermal + performance profile + total_act > 30s + session_age < 600s`. False positive on normal mixed workload is very unlikely.

---

### ⚡ Auto-Degrade Threshold Tuning

| Parameter | V27 | V28 | Why |
|:----------|:---:|:---:|:----|
| `auto_degrade_thermal_pct` | 35% | **45%** | 35% was too aggressive — killed legitimate burst phases |
| Path 2 time gate | 90s | **120s** | 90s was too early for sustained workloads |

These values apply only to non-benchmark sessions. Benchmark sessions bypass auto-degrade entirely.

---

### 🎮 Intent Classifier Improvements

| Change | V27 | V28 |
|:-------|:----|:----|
| Benchmark detection | Required GAMING entries | **have_thermal + performance profile** |
| Classification window | 300s | **600s** |
| Intent-based degrade | Only when highload_mode != 2 | **Works when highload_mode already 2** |

---

### 🔊 Bluetooth Audio Enhancement

BT A2DP volume curve — top 3 points boosted for better headphone/speaker experience:

| Volume Point | V27 | V28 |
|:-------------|:---:|:---:|
| 75 | +2 dB | **+3 dB** |
| 78 | +3.5 dB | **+4.5 dB** |
| 80 | +5 dB | **+6 dB** |

---

### 🐍 Python Tools Upgrade

**`asb_session_report.py`:**

| Feature | Description |
|:--------|:------------|
| **🔬 Battery Root Cause** | Aggregates fail reasons, shows dominant cause |
| **🔥 Performance Heat Analysis** | Classifies: early_thermal_spike / early_sustained_entry / efficiency_collapse |
| **🔍 Data Quality** | Per-profile trust breakdown: clean / partial / dirty |
| **Degrade buckets** | fast (<120s) / normal (120–300s) / late (>300s) |
| **Balanced sanity** | Warns if avg_temp > 95°C or avg_sus_pct > 75% |
| **Battery table** | Trust + Reason columns added |

**`asb_analyze.py`:**

| Feature | Description |
|:--------|:------------|
| **Session-scoped parsing** | Events collected only from current session |
| **Deduplicated explain** | Uses set() to avoid repeated lines |
| **Explain section** | Shows auto-degrade bucket, intent, self-tune, startup feedback |

**`asb_compare_sessions.py`:**

| Feature | Description |
|:--------|:------------|
| `deg_age` field | Added to JSONL loader |
| Intent column | Added to session detail table |

---

### 🐛 Bug Fixes

| Bug | Impact | Fix |
|:----|:-------|:----|
| **Battery learner poisoned by dirty sessions** | Short screen-on sessions trained with noise | Trust gate: dirty/partial skip learning AND pstats |
| **Battery self-tune ping-pong** | Tighten→relax every session | Anti-oscillation cooldown |
| **Benchmark kills daily performance** | Benchmark degrade poisoned pstats | Benchmark pstats isolation |
| **Startup gate too aggressive** | Few bad runs permanently locked stable | avg_degrade_age soft rehab |
| **Forward declarations missing** | Compilation failed on some toolchains | Forward declarations added |
| **History scan counted sleep_idle** | Sleep sessions inflated averages | Filter: skip sleep_idle and dur < 120 |

---

### ✅ V28 Summary

| Feature | Status |
|:--------|:------:|
| Battery trust gate (dirty / partial / clean) | ✅ |
| Cause-aware battery self-tune (4 causes) | ✅ |
| Anti-oscillation cooldown | ✅ |
| Battery reverse path (relax toward defaults) | ✅ |
| Performance startup gate — 5 paths | ✅ |
| avg_degrade_age tracking + soft rehab | ✅ |
| Benchmark bypass (degrade + stable + tune + pstats) | ✅ |
| Benchmark/daily memory isolation | ✅ |
| Auto-degrade thermal_pct 35→45% | ✅ |
| Path 2 time gate 90→120s | ✅ |
| Intent classifier: wider window, no gaming requirement | ✅ |
| BT A2DP volume boost | ✅ |
| Python tools: root cause, heat analysis, data quality | ✅ |
| Session-scoped explain in analyzer | ✅ |
| 6 bug fixes | ✅ |

**V28 is where ASB stops treating all sessions equally. Battery sessions earn trust before they teach. Benchmark sessions run free without poisoning daily memory. The governor finally knows when to learn, when to protect, and when to step aside.**

---
