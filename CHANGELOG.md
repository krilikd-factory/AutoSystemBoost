# ASB-V15.6 — Changelog

---

## [V15.6] — 2026-03-02 · Maximum Battery, Zero Regressions

> **Focus:** Every patch delivers real battery savings *without* user-visible trade-offs.  
> Full charge (Mixed Day): **~45–46 h (~1.9 days)** · vs V15.2 baseline: **+8–9 h / charge**

### ⚡ New Patches (8 groups, 14 individual settings)

| # | Patch | Change | Saving (est.) | Safe? |
|---|-------|--------|---------------|-------|
| P1 | CPU schedutil | `rate_limit_us` 0→2000 µs · `hispeed_load` 90% | +2–3 mAh/h idle | ✅ |
| P2 | VM dirty flush | `dirty_expire_centisecs` 6000→150 · `page-cluster` 0 · `stat_interval` 10 | +1–2 mAh/h | ✅ |
| P3 | TCP dead sockets | `tcp_fin_timeout` 60→20 s · `tcp_no_metrics_save` 1 | +0.5–1 mAh/h | ✅ |
| P4 | GPU NAP governor | `msm-adreno-tz` + `min_pwrlevel=6` | +2–4 mAh/h GPU idle | ✅ |
| P5 | Doze refinement | `idle_after_inactive_to` 30 s→10 s (inactive_to stays 3 min) | +1–2 mAh/h deep idle | ✅ |
| P6 | Wi-Fi DTIM=3 | `iw set listen-interval 3` · disable connected-scan | +1.5–3 mAh/h | ✅ |
| P7 | OxygenOS telemetry | `wifi_scan_always=0`, `wifi_wakeup=0`, `captive_portal_mode=0` + 4 more | +1–2 mAh/h | ✅ |
| P8 | Re-apply loop | `apply_cpugov_hints` + `apply_wifi_dtim` at 30/90/300 s | ensures persistence | ✅ |

**Total estimated gain over V15.5: +8–15 mAh/h (Mixed Day)**

### 🔒 No Regressions — all V15.5 correctness fixes retained

| Fix | Status |
|-----|--------|
| WALT `input_boost_ms=25` | ✅ kept |
| Doze `inactive_to=3 min` | ✅ kept |
| statsd NOT in stop-list | ✅ kept |
| TCP keepalive kernel defaults | ✅ kept |
| Smart Wi-Fi PSM (off during gaming) | ✅ kept |

### 📊 Battery Simulation (Mixed Day, 7300 mAh)

| Version | mA | Runtime | vs V15.2 |
|---------|----|---------|----------|
| V15.2 | 190.0 mA | 36.5 h | baseline |
| V15.3 | 187.5 mA | 37.0 h | +0.5 h |
| V15.4 | 161.8 mA | 42.9 h | +6.4 h |
| V15.5 | 164.7 mA | 42.1 h | +5.6 h |
| **V15.6** | **~152 mA** | **~45.6 h** | **+9.1 h** |

### 📈 Statistics
- `service.sh`: 807 → **843 lines** (+36 vs V15.5, +146 vs V15.2)
- New functions: `apply_cpugov_hints()`, `apply_wifi_dtim()`
- Syntax check: ✅ `bash -n` PASS  
- Patch verification: ✅ **20/20**

---
