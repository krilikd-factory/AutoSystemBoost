# 🚀 AutoSystemBoost V17 STABLE RELEASE

Compared to V16.6  
Date: 2026-03-08

---

# 🧠 Core Scheduler Evolution

| Area | V16.6 | V17 |
|-----|-----|-----|
| WALT idle threshold | Baseline refined | More battery-aware |
| Cluster util threshold | Conservative | Better light-load packing |
| Busy hysteresis | Not fully optimized | **sched_busy_hyst_ns=0** |
| RAVG window | Stock-like behavior | **sched_ravg_window_nr_ticks=3** |
| Task colocation | Standard | **sched_min_task_util_for_colocation=40** |

✔ Faster drop back to efficient CPU behaviour after short spikes  
✔ Lower scheduler noise during light usage  
✔ Better task packing on efficient cores  
✔ Cleaner balance between responsiveness and power efficiency  

Result: V17 improves scheduler behaviour not by chasing peak boosts, but by reducing unnecessary CPU wakeups, hysteresis and migration noise.

---

# ⚡ CPU Floor & Idle Behaviour

| Area | V16.6 | V17 |
|-----|-----|-----|
| CPU min frequencies | Improved | Retained and stabilized |
| policy0 minimum | Lowered | **384000** |
| policy6 minimum | Lowered | **768000** |
| Screen-off efficiency | Good | Better |
| Idle consistency | Good | More stable |

✔ Keeps efficient low CPU floors in place  
✔ Helps the device return to idle states faster  
✔ Reduces wasted power during light background activity  
✔ Better standby behaviour without harming foreground performance  

Result: V17 delivers a cleaner idle profile with more consistent low-power behaviour during standby and normal everyday use.

---

# 🔧 WALT + Pipeline Refinement

| Area | V16.6 | V17 |
|-----|-----|-----|
| Pipeline thresholds | Not tuned | **20 / 20** |
| Scheduler reaction window | Standard | Smoothed |
| Light task behaviour | Good | More controlled |
| Frame pacing | Stable | Smoother |

Applied scheduler refinements:

- `sched_pipeline_util_thres=20`
- `sched_pipeline_non_special_task_util_thres=20`
- `sched_ravg_window_nr_ticks=3`
- `sched_busy_hyst_ns=0`

✔ Less aggressive reaction to tiny load spikes  
✔ Better behaviour during UI transitions and light multitasking  
✔ More stable task placement during everyday use  
✔ Lower chance of pointless scheduler oscillation  

Result: smoother UI behaviour and cleaner frequency scaling, especially outside of heavy gaming.

---

# 🔵 Bluetooth / LE Audio Power Safety

| Area | V16.6 | V17 |
|-----|-----|-----|
| LE Audio allow-list bypass | Removed | Retained |
| Idle call notifications | Removed | Retained safe state |
| BLE background scan risk | Reduced | Reduced |

Important retained safety properties:

- `persist.bluetooth.leaudio.bypass_allow_list=false`
- `persist.bluetooth.leaudio.notify.idle.during.call=false`

✔ Lower chance of background BLE wakeups  
✔ Cleaner LE Audio behaviour during idle  
✔ Better protection from Bluetooth-related standby drain  

Result: V17 preserves the most important Bluetooth battery fixes introduced after V16.6.

---

# 🌐 Network Stack Refinement

| Area | V16.6 | V17 |
|-----|-----|-----|
| Congestion control | Improved | **BBR retained** |
| Fast Open | Enabled | **tcp_fastopen=3** |
| MTU probing | Active | **tcp_mtu_probing=1** |
| Retransmission recovery | Improved | **tcp_retrans_collapse=0** |
| Slow start after idle | Disabled | **tcp_slow_start_after_idle=0** |

✔ Better mobile data recovery on unstable LTE / 5G  
✔ Faster TCP session startup  
✔ Cleaner behaviour after idle periods  
✔ More modern network tuning without aggressive gimmicks  

Result: V17 keeps the strongest network improvements from the V16.x series while pairing them with a cleaner scheduler stack.

---

# 🔋 Battery, Heat & Real-World Behaviour

V17 is not a peak-performance update.  
It is a **refinement release focused on better efficiency, lower heat spikes and smoother everyday behaviour**.

Expected improvements vs V16.6:

| Scenario | V16.6 | V17 |
|------|------|------|
| Night drain | Good | Better |
| Screen-off idle | Good | More efficient |
| Light usage heat | Reduced | Lower |
| UI smoothness | Good | Smoother |
| Frame pacing | Stable | More stable |

✔ Better standby efficiency  
✔ Lower scheduler-induced heat spikes  
✔ More stable light-load CPU behaviour  
✔ Cleaner balance between responsiveness and battery life  

Result: V17 is the most balanced AutoSystemBoost release so far.

---

# 📊 Summary

V17 is a **major scheduler refinement release** built on top of the stable V16.x foundation.

Main improvements:

✔ `sched_busy_hyst_ns=0` for faster post-burst recovery  
✔ `sched_ravg_window_nr_ticks=3` now correctly applied  
✔ tuned WALT pipeline thresholds for smoother behaviour  
✔ retained low CPU floors for stronger idle efficiency  
✔ retained Bluetooth anti-drain protection  
✔ retained modern TCP / BBR network tuning  

V17 focuses on:

- cleaner scheduler logic  
- better battery efficiency  
- lower light-load heat  
- smoother real-world responsiveness  
- stable audio / Bluetooth / network behaviour
