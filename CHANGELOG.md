# AutoSystemBoost -- Changelog

---

## V35 -- Thermal Honesty + Balanced Calm

> **V34 gave the module a brain that knows day from night.**
> **V35 teaches it to tell real heat from vendor noise, and stops balanced from panicking at every shadow.**

One principle: **if your thermometer is stale and your clamp detector can't tell advisory from emergency, you don't need lower thresholds -- you need better eyes.**

---

### 🌡️ Thermal Signal Split

V34 mixed two different realities into one `throttling` flag:

| Signal | V34 | V35 |
|:-------|:----|:----|
| Real temp >= 65C | `throttling=1` | `throttling=1` |
| Headroom < 70% | `throttling=1` | **`soft_clamp=1`** (advisory) |
| Headroom < 45% | `throttling=1` | **`hard_clamp=1`** (actionable) |

**soft_clamp** reduces anti-clamp aggression but **never triggers SUSTAINED**.
**hard_clamp** can lead to SUSTAINED only after 2 confirmed ticks + temp >= 48C.

**Result:** balanced no longer enters SUSTAINED at 41C just because vendor dropped headroom to 65%.

---

### 👻 Stale Temperature Detection

V34 Quiet Night / Deep Idle Economy skips thermal reads to save power. But heartbeat kept printing the last cached value as if it were fresh -- phantom 45C readings all night.

V35 tracks `temp_valid` and `temp_age_s`. After `thermal_stale_after_s` (default 60s) without a fresh read, temperature is marked stale:

```
heartbeat: temp=45(stale) headroom=100% ...   # honest -- value is old
heartbeat: temp=33 headroom=67% sc=1 hc=0 ... # fresh + clamp status visible
```

**Measured:** 8.2h clean sleep, temp=31C (real), no phantom readings.

---

### ⚖️ Balanced-Specific Load Thresholds

V34 balanced used the global `heavy_load_enter=2.0`. On SM8850 any normal Android activity exceeds loadavg 2.0, so balanced lived almost entirely in HEAVY, skipping MODERATE entirely.

V35 adds per-profile thresholds:

| Profile | MODERATE threshold | HEAVY threshold |
|:--------|:------------------:|:---------------:|
| Battery | 12.0 | 18.0 |
| **Balanced** | **3.0** | **5.5** |
| Performance | 10.0 (global) | 2.0 (global) |

Balanced gets a real ladder again: LIGHT_IDLE → MODERATE → HEAVY → SUSTAINED.

---

### 🛡️ Balanced Sustained Entry Gates

Three new layers prevent false SUSTAINED entries in balanced:

#### Warmup Grace

First `balanced_warmup_grace_s` (default 45s) after session start: **no SUSTAINED entry** from headroom/clamp.
Exceptions: temp >= 60C or headroom < 40%.

#### Hard Clamp Confirmation

When SUSTAINED entry is from `hard_clamp` only (not real thermal):
- Thermal floor raised to **48C** (from 40C)
- Requires **2 consecutive ticks**

#### Soft Clamp is Advisory

`soft_clamp` (headroom 50-70%) reduces anti-clamp aggression and cuts gaming eligibility, but **never presses the SUSTAINED button**.

---

### 📊 Measured Results (V34 vs V35)

| Metric | V34 balanced | V35 balanced |
|:-------|:------------:|:------------:|
| Thermal entries | 15 | **0** |
| Time in SUSTAINED | 206s | **0s** |
| False SUSTAINED at 41C | Yes | **No** |
| max_temp | 62C | 62C |
| t_heavy | 1064s | 1064s |

| Metric | V34 sleep | V35 sleep |
|:-------|:---------:|:---------:|
| Duration | -- | 8.2h |
| idle_quality | -- | **100** |
| env | -- | quiet |
| max_temp | 45C (stale!) | **31C** (real) |
| bat_deep | -- | 1000 |
| Phantom temp readings | Yes (hours) | **No** |

---

### 🔍 Honest Diagnostics

#### Heartbeat v2

```
heartbeat: state=HEAVY profile=1 temp=41 headroom=67% ... sc=1 hc=0
```

New fields: `sc` (soft clamp), `hc` (hard clamp). Stale temp marked with `(stale)`.

#### enter_sustained Reason

```
enter_sustained: thermal actual_t=67degC ...     # real heat
enter_sustained: hard_clamp actual_t=48degC ...  # vendor clamp confirmed
enter_sustained: headroom=42% ...                # kernel cap
```

---

### ⚙️ New Configuration (governor.conf)

| Parameter | Default | Purpose |
|:----------|:-------:|:--------|
| `balanced_heavy_load_enter` | **5.5** | HEAVY threshold for balanced |
| `balanced_moderate_load_enter` | **3.0** | MODERATE threshold for balanced |
| `balanced_warmup_grace_s` | **45** | Seconds to suppress SUSTAINED after start |
| `thermal_stale_after_s` | **60** | Temp older than this marked stale |

---

### 📈 By The Numbers

| Metric | V34 | V35 | Change |
|:-------|:---:|:---:|:------:|
| Governor C lines | 3,230 | 3,243 | +13 |
| FSM header | 684 | 725 | **+41** |
| Metrics header | 431 | 456 | **+25** |
| Config header | 272 | 288 | +16 |
| Total C code | 4,345 | 4,712 | **+367** |
| Config parameters | 46 | **50** | +4 |
| Thermal signals | 1 (throttling) | **3** (thermal / soft / hard) | Split |
| Balanced load tiers | 0 (used global) | **2** (MODERATE + HEAVY) | New |
| Stale temp tracking | None | **temp_valid + temp_age_s** | New |
| Balanced sustained gates | 1 (floor only) | **3** (floor + confirm + warmup) | +2 |

---

### 🏛️ Changed Files (from V34)

| File | Delta | What |
|:-----|:-----:|:-----|
| `src/asb_metrics.h` | **+25** | soft_clamp, hard_clamp, temp_valid, temp_age_s, stale cache, thermal signal split |
| `src/asb_fsm.h` | **+41** | balanced thresholds, warmup grace, hard_clamp confirm, thermal_cap split, ceiling lock gate |
| `src/asb_config.h` | **+16** | balanced_heavy/moderate_load_enter, balanced_warmup_grace_s, thermal_stale_after_s |
| `src/asb_governor.c` | **+13** | honest heartbeat (stale marker, sc/hc), enter_sustained reason logging, fsm_profile_is_balanced |
| `config/governor.conf` | **+4** | 4 new balanced/thermal parameters |

### Unchanged

Profiles, system.prop, audio/camera/GPS/WiFi/BT overlays, battery thresholds, install scripts -- **all identical to V34**.

---

> **V34 gave it a brain that knows day from night, a memory that doesn't mix them up, and the discipline to stop wasting energy on walls it already lost.**
> **V35 fixed its thermometer, taught it to tell real heat from vendor noise, and stopped balanced from treating every headroom dip as a five-alarm fire.**
