# AutoSystemBoost — GitHub Changelog

> **Module:** AutoSystemBoost OP15  
> **Device:** OnePlus 15 (CPH2745) · SM8750 · Adreno 840 · Android 16 / OxygenOS 15 · Kernel 6.12  
> **Author:** [@DKomsomol](https://t.me/DKomsomol) · Channel: [@OnePlusMod](https://t.me/OnePlusMod)

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

## [V15.5] — 2026-03-02 · Stability & Responsiveness

> Correctness release over V15.4. Trades ~2.9 mA for stability.  
> Full charge (Mixed Day): **42.1 h (1.75 days)** · vs V15.2: **+5.6 h**

| Fix | Change |
|-----|--------|
| WALT `input_boost_ms` | 0 ms → 25 ms |
| Doze `inactive_to` | 30 s → 3 min |
| `statsd` stop-list | removed |
| TCP keepalive | reverted to defaults |
| Wi-Fi PSM | smart mode |

---

## [V15.4] — 2026-03-02 · Battery Optimization

> Full charge (Mixed Day): **42.9 h (1.79 days)** · vs V15.2: **+6.4 h**

- GPU idle_timer 80→250 ms · force flags = 0
- Wi-Fi PSM + Doze aggressive constants
- WALT input_boost = 0 (fixed in V15.5)
- Stop-list +11 services · OOM kill · EAS

---

## [V15.3] — 2026-03-02 · Stability & Memory

> Full charge: **37.0 h** · vs V15.2: **+0.5 h**

- uclamp multi-path (kernel 6.12+)
- ZRAM fixed 8192 MB, zstd
- vfs_cache_pressure 70→50
- network_recommendations re-apply

---

## [V15.2] — 2026-03-02 · Network & CPU

> Full charge: **36.5 h (1.52 days)**

- TCP BBR · tcp_slow_start=0 · tcp_fastopen=3
- swappiness=20 · sched_nr_migrate=4
- Dolby / IMS props · batterysecret stop

---

*Source: [github.com/krilikd/AutoSystemBoost](https://github.com/krilikd/AutoSystemBoost)*
