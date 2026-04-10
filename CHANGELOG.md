# AutoSystemBoost -- Changelog

---

## V36 -- Long Gaming + Deeper Battery + Honest Status

> **V35 fixed the thermometer and calmed balanced down.**
> **V36 rebuilds the performance profile around sustainable 1-2 hour gaming sessions, pushes battery into deeper energy savings, exposes honest telemetry in status, and fixes a silent install error that was hiding since V27.**

---

### 🎮 Performance Profile -- Built for Long Gaming

V35 performance was optimized for peak 60-second bursts. Logs showed this caused early vendor ceiling collapse around 30s → low actual sustained performance over a 1-2 hour session.

V36 rebuilds performance around a **sustainable ceiling** philosophy: don't chase peaks, ride a stable plateau at 40-55C shell temperature that the vendor clamp never bites.

| Parameter | V35 | V36 | Why |
|:----------|:---:|:---:|:----|
| `CPU_CAP_BIG` | 3,456,000 | **3,264,000** | Soft cap -200 MHz keeps vendor clamp quiet |
| `CPU_CAP_LITTLE` | 3,072,000 | **2,995,200** | Matched ratio |
| `CPU_MIN_LITTLE` | 1,497,600 | **1,324,800** | Lower floor = heat bleed between frames |
| `WALT_ED_BOOST` | 55 → 40 | **35** | Less thermal spike, frames still hit 144fps |
| `WALT_TOPAPP_WEIGHT` | 190 → 170 | **160** | Calmer boost, game still prioritized |
| `WALT_BUSY_HYST` | 12 ms | **8 ms** | Faster downscale when frame is done |
| `SCHED_RATE` | 800 | **1,000** | Fewer unnecessary boost events mid-frame |
| `SCHED_UP_RATE` | 300 | **400** | Slightly slower up-scaling |
| `SCHED_HISPEED_LOAD` | 55 | **60** | Higher bar for hispeed entry |
| `GPU_IDLE_TIMER` | 48 | **64** | Less aggressive GPU nap transitions |
| `GPU_MAX_PCT` | 100 | **92** | Reserve 8% GPU headroom |
| `GPU_THERMAL_PWRLEVEL` | 1 | **2** | One step back from absolute max |
| `VM_DIRTY_EXPIRE` | 1000 | **1500** | Less kswapd pressure mid-session |
| `UCL_FG_MAX` | 100 | **95** | Foreground gets 95%, top-app 100% |

**Philosophy:** Don't cut sustained after the fire — don't start the fire. Lower opening punch → vendor clamp stays asleep → higher actual sustained frequencies over 1-2 hours of COD Mobile at 144fps.

Expected result: shell temperature 40-55C instead of 60-70C spikes, fewer SUSTAINED entries, stable frame pacing over 60+ minute sessions.

---

### 🔋 Battery Profile -- Deeper Energy Saving

V35 battery was already good for sleep (clean 8h nights). V36 goes further on screen-off and mixed-day energy drain.

| Parameter | V35 | V36 | Why |
|:----------|:---:|:---:|:----|
| `CPU_MIN_LITTLE` | 384,000 | **307,200** | Absolute minimum idle floor |
| `CPU_MIN_BIG` | 768,000 | **614,400** | Lower big-cluster floor |
| `CPU_MAX_BIG` | 1,132,800 | **998,400** | Cap big-cluster ceiling even harder |
| `CPU_CAP_LITTLE` | 729,600 | **614,400** | Soft cap matches min floor |
| `CPU_CAP_BIG` | 1,075,200 | **921,600** | No unnecessary big-cluster activity |
| `WALT_TOPAPP_WEIGHT` | 60 | **40** | Even foreground gets less priority |
| `WALT_BOOST_MIN_UTIL` | 150 | **200** | Harder to justify frequency boost |
| `SCHED_RATE` | 12,000 | **16,000** | Slower scheduler = fewer wake events |
| `UCL_FG_MAX` | 10 | **8** | Foreground apps capped at 8% utilization |
| `UCL_TOP_MAX` | 15 | **12** | Top-app capped at 12% |
| `GPU_IDLE_TIMER` | 16 | **12** | Faster GPU sleep |
| `GPU_MAX_PCT` | 18 | **15** | Minimal GPU ceiling |
| `GPU_THERMAL_PWRLEVEL` | 6 | **7** | One step lower than before |
| `VM_SWAPPINESS` | 180 | **200** | Maximum swap preference |
| `VM_DIRTY_EXPIRE` | 180,000 | **240,000** | Even lazier writeback |
| `NET_TCP_RMEM/WMEM` | 4M | **2M** | Smaller network buffers |
| `WIFI_TXQLEN` | 64 | **32** | Smallest viable TX queue |
| `NET_TCP_KEEPIDLE` | 14,400 | **18,000** | Longer keepalive = fewer radio wakes |
| `NET_TCP_FIN` | 45 | **30** | Faster connection cleanup |

**Expected result:** lower idle drain during mixed day use, unchanged clean sleep behavior (V35 was already near-optimal there).

---

### 🌡️ Balanced Thermal Ceiling (New)

V35 logs showed a real issue: under a 9-hour heavy workload, balanced hit **max_temp=81C** with 251s in SUSTAINED. Balanced was still using the global `sustained_temp_enter=65C`, which is too hot for a "daily use" profile.

V36 adds per-profile sustained thermal thresholds for balanced:

| Profile | sustained_temp_enter | sustained_temp_exit |
|:--------|:--------------------:|:-------------------:|
| Battery | 65C (global) | 52C (global) |
| **Balanced** | **58C** | **50C** |
| Performance | 62C | 54C |

**Expected:** balanced enters SUSTAINED earlier under prolonged heavy load, keeping surface temperatures more comfortable during long sessions.

---

### 🔧 Install Fix

`asb_install_prebuilt_governor` was called on line 12 of `common/install.sh` — **before the function was defined** (line 109). Shell executes sequentially → `not found` error on every install.

**Fix:** Removed premature call. Added proper call after all function definitions, right before `asb_big_banner`.

---

### 🏚️ Removed Legacy Headroom<50 Shortcut

V35 introduced the unified sustained entry path:

```
throttle_signal -> throttle_confirmed -> warmup_grace -> debounce -> SUSTAINED
```

But a legacy block from V29 remained in `asb_fsm.h`:

```c
if (headroom_pct > 0 && headroom_pct < 50) {
    desired = SUSTAINED;  // bypasses V35 logic entirely
}
```

This was a **second secret entrance** to SUSTAINED that skipped:
- soft_clamp / hard_clamp classification
- debounce (2-tick confirmation)
- warmup grace (45s protection)
- balanced thermal floor (48C)

**Fix:** Block removed. All SUSTAINED entries now go through the single V35 path.

---

### ⚙️ Fixed Global Load Thresholds

V35 had `heavy_load_enter=2.0` and `moderate_load_enter=10.0` — **inverted**. The safety guard silently clamped at runtime, but the config was logically wrong.

| Threshold | V35 (config) | V35 (runtime) | V36 |
|:----------|:------------:|:-------------:|:---:|
| `moderate_load_enter` | 10.0 | 10.0 | **3.0** |
| `heavy_load_enter` | 2.0 | 10.5 (clamped) | **5.0** |

Now performance has a proper ladder: MODERATE from load 3.0, HEAVY from load 5.0.

---

### 🔍 Honest Status JSON

In V35 heartbeat showed `temp=45(stale)` and `sc=1 hc=0`, but these fields were **only in heartbeat** (printed once every 15 minutes). A short diagnostic window never saw them.

V36 exposes the full thermal signal split in the status socket JSON:

```json
{
  "state": "HEAVY", "profile": "performance",
  "temp": 45, "temp_valid": 0, "temp_age_s": 912,
  "soft_clamp": 1, "hard_clamp": 0,
  "thermal": 0, "headroom_pct": 67,
  ...
}
```

Four new fields: `temp_valid`, `temp_age_s`, `soft_clamp`, `hard_clamp`. Now every `status` query sees the complete picture.

---

### 🛠️ Reload Path History Bug

The socket `reload` command silently discarded running sessions when a profile change was detected — `fsm_session_reset()` was called without first writing history. Sessions that crossed a reload boundary were lost.

**V36 fix:** If a profile change is detected on reload, `session_history_append_ex()` is called **before** the reset, preserving the outgoing session with correct profile attribution.

---

### 📈 By The Numbers

| Metric | V35 | V36 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 3,243 | 3,261 | +18 |
| FSM header | 725 | 752 | +27 |
| Metrics header | 456 | 472 | +16 |
| Config header | 288 | 342 | +54 |
| Total C code | 4,712 | 4,827 | +115 |
| Config parameters | 50 | **57** | +7 |
| Status JSON fields | 31 | **35** | +4 |
| Per-profile thermal tiers | 2 | **3** | +balanced |
| Performance CPU_CAP_BIG | 3,456 MHz | **3,264 MHz** | -200 MHz soft cap |
| Battery CPU_MAX_BIG | 1,132 MHz | **998 MHz** | -134 MHz hard cap |
| install.sh | broken | **fixed** | Error gone |

---

### 🏛️ Changed Files (from V35)

| File | What |
|:-----|:-----|
| `common/install.sh` | Moved `asb_install_prebuilt_governor` call after definitions |
| `profiles/performance.sh` | Rebuilt for sustainable 1-2h gaming (14 tuning changes) |
| `profiles/battery.sh` | Deeper energy saving (16 tuning changes) |
| `src/asb_fsm.h` | Removed legacy headroom<50 shortcut |
| `src/asb_config.h` | Added balanced_sustained_temp_enter/exit |
| `src/asb_governor.c` | Status JSON fields, reload history fix |
| `src/asb_metrics.h` | Thermal signal split (V35 carried forward) |
| `config/governor.conf` | moderate=3.0, heavy=5.0, balanced ceiling 58/50 |

### Unchanged

system.prop, audio/camera/GPS overlays, balanced profile shell (already optimal per V35 logs), install scripts structure.

---

> **V35 fixed the thermometer and stopped balanced from treating every headroom dip as a five-alarm fire.**
> **V36 rebuilt the gaming profile around 1-2h sustainable plateaus, pushed battery deeper into energy saving, gave balanced its own thermal ceiling, exposed honest telemetry everywhere, and fixed an install error that was hiding in plain sight since V27.**
