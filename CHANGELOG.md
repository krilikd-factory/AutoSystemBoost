# ASB-V15.5 — Changelog

---

## [V15.5] — 2026-03-02 · Stability & Responsiveness

> **Focus:** Correctness fixes over V15.4 — trades ~2.9 mA for stability and touch responsiveness.  
> Full charge (Mixed Day): **42.1 h (1.75 days)** · vs V15.2 baseline: **+5.6 h / charge**

### 🔧 Fixes

| Patch | Before (V15.4) | After (V15.5) | Reason |
|-------|----------------|---------------|--------|
| WALT `input_boost_ms` | `0 ms` | **`25 ms`** | Restore touch latency (+10–20 ms responsiveness) |
| Doze `inactive_to` | `30 s` | **`3 min`** | Prevent FCM/push delays in background |
| `statsd` in stop-list | stopped | **removed** | Fix cyclic restart loop on OxygenOS / GMS |
| TCP keepalive | `time=1800 intvl=30 probes=3` | **kernel defaults** `7200/75/9` | Restore stability of long-lived connections |
| Wi-Fi PSM | always on | **smart mode** (off during gaming/streaming) | Fix V15.4 gaming latency regression |

### 📊 Battery Impact (simulation, ±20% accuracy)

| Scenario | V15.4 | V15.5 | Δ |
|----------|-------|-------|---|
| 🌙 Deep Idle | 66.7 mA · 104 h | 68.8 mA · 101 h | −2.1 mA |
| 🎵 Music BT | 61.6 mA · 113 h | 63.4 mA · 109 h | −1.8 mA |
| 📱 Active Use | 245 mA · 28.3 h | 250 mA · 27.7 h | −5.2 mA |
| 🎮 Gaming CODM | 705 mA · 9.8 h | 709 mA · 9.8 h | −4.1 mA (+smart PSM fix) |
| 🔋 Mixed Day | 161.8 mA · 42.9 h | 164.7 mA · 42.1 h | **−2.9 mA** |

### 📈 Statistics
- `service.sh`: 790 → **808 lines** (+18 vs V15.4)
- Syntax check: ✅ `bash -n` PASS
- Patches: 5 correctness fixes

---

## [V15.4] — 2026-03-02 · Battery Optimization

> **Focus:** Deep battery saving — ~+6.4 h / charge vs V15.2.  
> Full charge (Mixed Day): **42.9 h (1.79 days)**

### ⚡ Battery Patches (9 total)

| Patch | Change | Saving (Mixed Day) |
|-------|--------|--------------------|
| GPU `idle_timer` | `80 ms` → `250 ms` | +4.8 mA |
| GPU `force_rail/clk/bus_on` | → `0` | included above |
| Wi-Fi PSM (`apply_wifi_pm`) | enabled + `wlan_pm=1` | +7.5 mA |
| Doze constants (`apply_doze`) | `inactive_to=30 s` + aggressive timers | +4.5 mA |
| WALT input boost | `input_boost_freq=0`, `input_boost_ms=0` | +5.5 mA |
| Stop-list +11 services | mdnsd, statsd, oplus_sensor_fb, mlipay… | +2.0 mA |
| TCP keepalive | `7200→1800 s` | +0.4 mA |
| `vm.oom_kill_allocating_task` | `0→1` | +0.4 mA |
| `sched_energy_aware` | `→1` (EAS) | +0.6 mA |

### 📈 Statistics
- `service.sh`: 715 → **790 lines** (+75 vs V15.3)
- Syntax check: ✅ PASS

---
