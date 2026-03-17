# 🚀 AutoSystemBoost -- V26 Changelog

---

## V26 -- 🧠 Intelligence & Battery Maturity

> **V25 = bugfixes after real device testing.**
> **V26 = governor learns in real time, battery finally catches up to performance.**

---

### 🧠 Runtime Self-Tuning (Type 3 Learning)

Governor now analyzes each completed session and adjusts its own config on the fly -- no restart needed. Fires at session boundaries (idle_boundary, profile_change, shutdown).

**⚡ Performance rules:**

| Condition | Action | Bounds |
|:----------|:-------|:-------|
| avg_gap > 1.5M kHz | sustained_level -0.02 | floor 0.75 |
| efficiency < 30% | force stable mode | until reboot |
| t2s < 60s | sustained_temp_enter +2 | max 72 |

**🔋 Battery rules:**

| Condition | Action | Bounds |
|:----------|:-------|:-------|
| wake_rate > 1/5min | bat_fast_idle_s -2 | floor 5s |
| HEAVY > 10% of battery session | bat_heavy_load_enter +0.5 | max 6.0 |
| MODERATE > 40% of idle time | bat_light_idle_gpu -2% | floor 5% |
| idle_q < 40 | bat_moderate_load_enter +1.0 | max 15.0 |

All adjustments logged: `self_tune: bat idle_q=26 <40 -> bat_moderate_load 12.0->13.0`

---

### 🔋 MODERATE Threshold Fix (SD8 Elite)

SD8 Elite reports loadavg 8-10 even at idle (8 cores). Previous threshold of 1.5 meant governor sat in MODERATE 100% of the time with screen on -- killing battery idle quality.

| Parameter | V25 | V26 |
|:----------|:---:|:---:|
| moderate_load_enter | 1.5 (hardcoded) | **10.0** (configurable) |
| bat_moderate_load_enter | -- | **12.0** (battery-specific) |

Real impact from logs: battery session idle_q jumped from 26 to 70+ after this fix.

---

### 🌡️ Thermal Trend Model

Governor now tracks temperature rate of change, not just absolute value. Prevents thermal wall hits by entering SUSTAINED preemptively when temperature is climbing fast.

| Feature | Detail |
|:--------|:-------|
| Circular buffer | Last 3 temperature deltas |
| Preemptive SUSTAINED | Fires when trend >= +6 AND temp within 5 of threshold |
| First-tick guard | Skips delta calculation when prev_temp is uninitialized |

---

### 📊 New Session Metrics

| Metric | Where | Description |
|:-------|:------|:------------|
| `idle_q` | session_history | Battery idle quality 0-100 (% DEEP_IDLE - wake penalty) |
| `cap_eff` | session_history | Cap efficiency 0-100 (% of requested caps delivered) |
| `dur` | session_history | Session duration in seconds |
| Schema | session_history | Bumped to `"v":2` |

---

### 🎮 Auto Degrade Fix (from Call of Duty data)

Call of Duty testing revealed auto mode never degraded despite 10 futile GAMING/SUSTAINED cycles with avg_gap=2.37 GHz.

| Change | V25 | V26 |
|:-------|:---:|:---:|
| auto_degrade_sus_ratio | 4 | **2** |
| auto_degrade_thermal_pct | 60% | **45%** |
| Path 3 (new) | -- | gap > 2M kHz + 3 gaming entries = instant degrade |

---

### 🔋 Battery FSM Improvements

| Behavior | V25 | V26 |
|:---------|:----|:----|
| LIGHT_IDLE to HEAVY (battery) | 2 ticks (4s) | **4 ticks (8s)** -- resists screen-wake spikes |
| HEAVY to LIGHT_IDLE (battery) | 5 ticks (10s) | **2-3 ticks (4-6s)** -- faster return to idle |

---

### 📝 Log System

| Feature | Detail |
|:--------|:-------|
| `log_level=0` (default) | Only important: self_tune, feedback, profile changes, sustained, session boundaries |
| `log_level=1` | Adds FSM ticks, reassert, boost, screen events, cmd echo |
| Rotation | 200KB max, auto-rotate to `governor.log.1` |

---

### 🎯 end-session Command

```
asb end-session
```

Cleanly closes current session: save history, run self_tune, save persistent stats, reset telemetry.

---

### 🛡️ Profile Change Session Hygiene

Session history is now saved **before** profile switch (correct label), then telemetry is reset. New end reason: `"profile_change"`.

Previously switching performance->battery via WebUI contaminated battery history with performance GAMING/SUSTAINED counters.

---

### 🔊 Bluetooth Audio

6 new props -- fixed bitrate instead of ABR for stable quality:

| Property | Value | Effect |
|:---------|:------|:-------|
| `persist.vendor.bt.a2dp.hw_cdc` | true | Hardware A2DP codec |
| `persist.vendor.bt.aac_vbr_frm_ctl.enabled` | true | AAC VBR framing |
| `persist.bluetooth.a2dp_sbc_abr.enable` | false | Fixed SBC bitrate |
| `persist.bluetooth.a2dp_aac_abr.enable` | false | Fixed AAC bitrate |
| `persist.bluetooth.a2dp_ldac_abr.enable` | false | Fixed LDAC bitrate |
| `persist.bluetooth.a2dp_lhdc_abr.enable` | false | Fixed LHDC bitrate |

A2DP volume curve boosted +2.5 dB at top 3 steps in `default_volume_tables.xml`.

---

### 📡 GPS & Network

- 🛰️ RTK disabled (`persist.sys.mqs.gps.rtk=OFF`) -- saves battery
- 🌐 TCP buffers upgraded: 5G/WiFi/LTE max 10 MB -> **16 MB**

---

### 🛠️ Python Tools

Session Report now includes:

- 🔋 **Battery score** 0-100 with verdict (healthy / noisy / moderate-heavy / failed to settle)
- ⚠️ **Anomaly detection** with severity (warning / CRITICAL)
- 📈 **Normalized metrics** table (sustained/10min, thermal/10min, wake/hour)
- 📋 **Executive summary** -- one-line per category (battery / high-load / auto)

---

### 🐛 Bug Fixes

| Bug | Impact | Fix |
|:----|:-------|:----|
| Thermal trend false SUSTAINED on boot | prev_temp=0 caused delta=35 on first tick | Skip delta when prev_temp uninitialized |
| Profile label wrong in history | profile_idx changed before history save | Save history first, then switch |
| MODERATE dominated battery idle | load >= 1.5, SD8 Elite idle loadavg=8+ | Configurable threshold 10.0 / 12.0 |
| `profile_core.sh` missing after install | MMT deletes `common/` | Copied to `runtime/` before cleanup |

---

### ✅ Summary

| Feature | Status |
|:--------|:------:|
| Runtime self-tuning (7 rules, bounded) | ✅ |
| MODERATE threshold configurable + battery-aware | ✅ |
| Thermal trend model with first-tick guard | ✅ |
| idle_q / cap_eff / dur in session history (v2) | ✅ |
| Auto degrade Path 3 + lowered thresholds | ✅ |
| Battery FSM: slower up, faster down | ✅ |
| log_level system (0=clean, 1=verbose) | ✅ |
| end-session command | ✅ |
| Profile change session hygiene | ✅ |
| BT: 6 fixed-bitrate props + volume boost | ✅ |
| GPS: RTK off | ✅ |
| TCP: 16MB buffers for 5G/WiFi | ✅ |
| Python: score + verdict + anomaly + normalized + summary | ✅ |
| Thermal trend first-tick bug fix | ✅ |

**V26 is where ASB stops being just a governor and becomes a system that observes, learns, and adapts -- in real time, on every session boundary, with bounded and explainable corrections.**

---
