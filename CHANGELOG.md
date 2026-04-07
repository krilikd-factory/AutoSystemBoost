# AutoSystemBoost -- Changelog

---

## V34 -- Battery Brain + Performance Economy + Environment Awareness

> **V33 stopped the module from thinking room temperature is a fire.**
> **V34 teaches it to understand where it is, remember what happened, and spend its energy wisely -- not just react to what's in front of it.**

One principle: **a governor that knows the difference between a quiet night and a hostile radio storm doesn't need to guess -- it already knows what to do.**

---

### 🧠 Battery Intelligence

#### Environment Hostility Classification

Every battery session is now scored by environment quality:

| Environment | Condition | Behavior |
|:------------|:----------|:---------|
| `quiet` | iq >= 30, wph < 5 | Aggressive power saving |
| `noisy` | iq < 25 or wph > 5 or radio active | Standard battery |
| `hostile` | iq < 10 or wph > 12 or radio + low iq | Conservative, no optimism |

#### Radio-Aware v2

Scans `rmnet_data0/1/2` + `rmnet_ipa0` for active mobile data. Sessions with >30% radio-active ticks get `radio_noisy=1`.

#### Battery Memory Split (Night vs Day)

`pstats_battery.json` now tracks two separate worlds:

| Field | Night | Day |
|:------|:------|:----|
| avg_iq | `niq` | `diq` |
| avg_wph | `nwph` | `dwph` |
| count | `nc` | `dc` |

Night = session >= 2h, iq >= 30, no degradation. Clean nights no longer diluted by noisy daytime.

#### Wake Attribution

Wake cycles split into `wake_screen` (user) and `wake_bg` (background).

#### Start-of-Session Priming

Previous session `hostile` -> next idle starts as `IDLE_NOISY`. No false optimism after a bad night.

```
plan: primed as IDLE_NOISY (last session env=hostile)
```

---

### 🌙 Battery Energy Saving

#### Quiet Night Baseline

Battery + screen off + deep idle confirmed for 45 ticks:

| Parameter | Normal | Quiet Night |
|:----------|:------:|:-----------:|
| Tick interval | 5s | **20s** |
| Thermal reads | every tick | every 5th |
| Headroom reads | yes | **skipped** |

#### Quiet Lock Hysteresis

Exit from quiet requires **3 consecutive noise ticks** OR screen ON.

#### Clean-Night Reward

Previous `clean_night` -> next session enters quiet **2x faster** (30 ticks).

#### Exit-from-Quiet Brain

Screen ON after quiet -> sensor reads ramp gradually over 3 ticks.

---

### 🎮 Performance Economy

#### Burst Probation Window

First 60s of performance = probation. If p6_max < 2GHz + clamp_hold:

- Economy mode **immediately** (no timer wait)
- `ac_budget` halved

```
burst_probation: early collapse (p6_max=1017kHz < 2GHz at 32s), ac_budget=3
```

#### Ceiling-Adaptive Reshaping

Under confirmed clamp > 45s, tracks actual ceiling via EMA:

```
virtual_ceiling = (old * 7 + observed) / 8
```

Gap calculated against **virtual ceiling**, not ideal target.

#### Ceiling Lock

`virtual_ceiling_p1 < 1.5GHz` -> GAMING entry **blocked**, demoted to HEAVY.

#### Action Cost Economy

Useless anti-clamp writes increment `g_action_waste`. At threshold (4), module reduces aggression.

#### Action Waste Decay

| Environment | Decay | Logic |
|:------------|:-----:|:------|
| quiet + no clamp | -2 | Fast recovery |
| noisy | -1 | Normal |
| hostile / clamp | 0 | Frozen |

#### Action Waste Reward

Successful anti-clamp (delta >= 100kHz) -> waste **-2 instant**.

---

### 🌡️ Thermal & Sensor

#### Sensor Reliability Layer

At discovery, 3 consecutive reads. Rejects dead (<=0), out-of-range (>120C), and flat+extreme (3 identical at >90C or <5C).

#### Comfort-First Battery Brain

Battery + screen ON + device >= 39C: HEAVY **capped**.

---

### ⚙️ New Configuration (governor.conf)

| Parameter | V33 | V34 | Purpose |
|:----------|:---:|:---:|:--------|
| `bat_heavy_load_enter` | 15 | **18** | Less HEAVY in battery |
| `bat_moderate_load_enter` | 10 | **12** | More light states |
| `bat_fast_idle_s` | 8 | **10** | Faster idle return |
| `bat_comfort_temp` | -- | **39** | Comfort cap threshold |
| `clamp_economy_after_s` | -- | **45** | Faster economy in clamp |
| `action_waste_threshold` | -- | **4** | Waste sensitivity |
| `env_iq_quiet` | -- | **30** | Quiet env threshold |
| `env_wph_noisy` | -- | **5** | Noise wph boundary |
| `quiet_entry_ticks` | -- | **45** | Quiet confirmation |
| `quiet_tick_s` | -- | **20** | Extended quiet tick |
| `virtual_ceiling_alpha` | -- | **7** | Ceiling EMA smoothing |
| `clamp_thermal_every_n` | -- | **3** | Thermal skip in economy |

---

### 📈 By The Numbers

| Metric | V33 | V34 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 2,881 | 3,230 | **+349** |
| FSM header | 656 | 684 | +28 |
| Metrics header | 387 | 431 | +44 |
| Total C code | 3,924 | 4,345 | **+421** (+10.7%) |
| Battery env classes | 0 | 3 | New |
| Battery memory tracks | 1 | 2 (night + day) | Split |
| Config parameters | 33 | 45 | +12 |
| Quiet night tick | 5s | 20s | **-75% wakeups** |
| Session schema | v7 | v8 | +7 fields |

---

### 🏛️ Changed Files

| File | Delta | Content |
|:-----|:-----:|:--------|
| `src/asb_governor.c` | **+349** | Battery brain, env, priming, action economy, burst probation, quiet night, radio, memory split |
| `src/asb_fsm.h` | **+28** | Wake attribution, virtual ceiling, comfort cap, ceiling lock |
| `src/asb_metrics.h` | **+44** | Sensor reliability, rmnet multi-interface |
| `tools/asb_session_report.py` | **+17** | bat_trust, perf_outcome display |
| `config/governor.conf` | **+23** | 12 new parameters |

### Unchanged

Profiles, system.prop, audio/camera/GPS overlays, install scripts -- **all identical to V33**.

---

> **V33 taught the module to tell real heat from noise and remember bad neighborhoods.**
> **V34 gave it a brain that knows day from night, a memory that doesn't mix them up, and the discipline to stop wasting energy on walls it already lost.**
