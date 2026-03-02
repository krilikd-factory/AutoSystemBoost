# AutoSystemBoost — GitHub Changelog

> **Module:** AutoSystemBoost OP15  
> **Device:** OnePlus 15 (CPH2745) · SM8750 · Adreno 840 · Android 16 / OxygenOS 15 · Kernel 6.12  
> **Author:** [@DKomsomol](https://t.me/DKomsomol) · Channel: [@OnePlusMod](https://t.me/OnePlusMod)

---

## [V15.7] — 2026-03-02 · Hotfix: V15.6 regressions

> **5 regressions from V15.6 corrected. All V15.6 battery features retained.**

### 🐛 Fixes

| # | Parameter | V15.6 | V15.7 | Why it matters |
|---|-----------|-------|-------|----------------|
| 1 | `kgsl/kgsl-3d0/min_pwrlevel` | `= 6` | **removed** | Level 6 blocks GPU deep-idle states 7–8. Device diag shows idle at level 9/17 — this was the original V15.1 regression, silently re-introduced in V15.6 |
| 2 | `vm.stat_interval` | `10` s | **`15`** s | stat_interval is a **period**: smaller = more frequent vmstat wakeups. 10 < 15 means more wakeups, not fewer. Comment in V15.6 was inverted. |
| 3 | `vm.dirty_expire_centisecs` | `150` cs | **`6000`** cs | 1.5 s expire = kernel marks pages dirty every 1.5 s → writeback thread wakes every ~5 s constantly. 60 s expire = rare bulk flushes, much better for standby. |
| 4 | 5 duplicate settings | present | **removed** | `tcp_fin_timeout` set twice (30 then 20), `tcp_no_metrics_save` ×2, `wifi_scan_always_enabled` ×2, `activity_starts_logging_enabled` ×2, `phantom_procs` ×2 |
| 5 | `captive_portal_mode=0` | present | **removed** | Disables Android captive portal detection — breaks Wi-Fi login pages in hotels, airports, cafes |

### ✅ All V15.6 battery features retained

| Feature | Value |
|---------|-------|
| CPU schedutil | `rate_limit_us=2000`, `hispeed_load=90%` (small/mid clusters) |
| GPU idle timer | `idle_timer=250 ms` + `msm-adreno-tz` governor |
| GPU force flags | `force_rail/clk/bus_on=0` |
| Wi-Fi | Smart PSM + DTIM `listen-interval=3` + connected-scan disabled |
| Doze | `inactive_to=180 s` (3 min), `idle_after_inactive_to=10 s` |
| OxygenOS telemetry | `wifi_scan_always=0`, `wifi_wakeup=0`, `send_action_app_error=0`, +4 more |
| TCP | `fin_timeout=20 s`, `no_metrics_save=1` (single instance each) |
| VM | `page-cluster=0`, `swappiness=20`, `vfs_cache_pressure=50` |
| ZRAM | Fixed 8192 MB, `zstd` compression |
| WALT | `input_boost_ms=25`, `input_boost_freq=0` |
| Stop-list | `mdnsd`, `oplus_sensor_fb`, `oplus_crash_report`, `mlipay` +8 more |

### 📈 Statistics

- `service.sh`: 843 (V15.6) → **835 lines** (−8)
- Syntax check: ✅ `bash -n` PASS
- Regression fixes: **5/5**

---

## [V15.6] — 2026-03-02 · Maximum Battery, Zero Regressions (patched in V15.7)

> Full charge (Mixed Day): **~45–46 h** · vs V15.2: **+8–9 h**  
> ⚠️ Contains 5 regressions fixed in V15.7 — use V15.7 instead.

New in V15.6: CPU schedutil hints · VM dirty/page-cluster · TCP fin_timeout · GPU NAP governor · Doze refinement · Wi-Fi DTIM=3 · OxygenOS telemetry kill · re-apply loop

---

## [V15.5] — 2026-03-02 · Stability & Responsiveness

> Full charge (Mixed Day): **42.1 h (1.75 days)** · vs V15.2: **+5.6 h**

- WALT `input_boost_ms` 0 → 25 ms · Doze `inactive_to` 30 s → 3 min
- `statsd` removed from stop-list · TCP keepalive reverted to defaults
- Wi-Fi PSM smart mode (off during gaming/streaming)

---

## [V15.4] — 2026-03-02 · Battery Optimization

> Full charge (Mixed Day): **42.9 h (1.79 days)** · vs V15.2: **+6.4 h**

- GPU idle_timer 80→250 ms · Wi-Fi PSM · aggressive Doze
- WALT input_boost=0 · Stop-list +11 · EAS · OOM kill

---

## [V15.3] — 2026-03-02 · Stability & Memory

> Full charge: **37.0 h**

- uclamp multi-path (kernel 6.12+) · ZRAM 8192 MB zstd
- vfs_cache_pressure 70→50 · network_recommendations re-apply

---

## [V15.2] — 2026-03-02 · Network & CPU

> Full charge: **36.5 h (1.52 days)**

- TCP BBR · swappiness=20 · Dolby/IMS props · batterysecret stop

---

*Source: [github.com/krilikd/AutoSystemBoost](https://github.com/krilikd/AutoSystemBoost)*
