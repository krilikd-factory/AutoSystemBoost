# 🚀 AutoSystemBoost V18 STABLE RELEASE

Compared to V17  
Date: 2026-03-10

---

# 🌟 What Changed in V18

V18 is not just a scheduler refinement update.  
It turns AutoSystemBoost from a **single tuned profile for OnePlus 15** into a more complete platform with:

- a built-in **WebUI**
- **live profile switching**
- a new **Performance / Balanced / Battery** profile system
- **safer compatibility logic** for other OnePlus devices
- a cleaner, more user-friendly daily workflow

V17 focused on stabilizing WALT behaviour and improving light-load efficiency.  
V18 keeps that foundation, then adds **control, flexibility and broader device support** on top of it.

---

# 🧠 Scheduler & Runtime Profiles

| Area | V17 | V18 |
|------|------|------|
| Main scheduler philosophy | Single balanced tuning | **3 runtime profiles** |
| Profile switching | Not available | **Live switch via WebUI** |
| RAVG / idle / cluster tuning | Fixed | **Per-profile** |
| CPU floors | Fixed | **Per-profile** |
| VM dirty timings | Fixed | **Per-profile** |
| GPU idle behaviour | Fixed | **Per-profile** |

V18 introduces a dedicated runtime profile layer:

### 🔥 Performance
Designed for gaming, fast app launch and more aggressive boost behaviour.

Typical V18 Performance values:
- `sched_ravg_window_nr_ticks=2`
- lower WALT idle / util thresholds
- higher CPU minimum floors
- faster VM writeback cadence
- lower GPU idle timer

### ⚖️ Balanced
Default profile and the closest continuation of the V17 idea.

Typical V18 Balanced values:
- `sched_ravg_window_nr_ticks=3`
- `sched_idle_enough=45`
- `sched_cluster_util_thres_pct=45`
- CPU floors `384000 / 768000`
- `vm.swappiness=20`

### 🔋 Battery
Designed for deeper idle, fewer wakeups and lower background activity.

Typical V18 Battery values:
- larger scheduler reaction window
- softer task packing thresholds
- lower CPU floors retained
- slower dirty writeback behaviour
- longer GPU idle timer

✔ V18 no longer forces one static compromise for every scenario  
✔ The user can now choose between speed, balance and standby efficiency  
✔ Profile changes are applied live, without reflashing the module

---

# 🖥 WebUI Integration

| Area | V17 | V18 |
|------|------|------|
| WebUI | No | **Yes** |
| Profile selection from UI | No | **Yes** |
| Live profile state display | No | **Yes** |
| User-facing tuning layer | No | **Yes** |

V18 introduces a dedicated WebUI with:

- profile cards for **Performance / Balanced / Battery**
- current profile status display
- live profile application through `apply_profile.sh`
- built-in profile parameter overview
- direct Telegram support link from the interface

Result: V18 is much easier to use day to day than V17.  
You no longer need to treat the module like a static flash-and-forget package.

---

# 📱 OnePlus Device Compatibility

| Area | V17 | V18 |
|------|------|------|
| Main target | OnePlus 15 only | **OnePlus 15 + compatibility mode for other OnePlus devices** |
| Risky OP15 vendor overlays | Always bundled | **Conditionally filtered** |
| Camera / audio safety on non-OP15 | Limited | **Improved** |
| Device-aware install logic | No | **Yes** |

V18 adds compatibility logic so the module can detect the target device during installation and avoid applying the most dangerous OP15-specific overlays everywhere.

This mainly affects:
- camera configs
- media profiles
- audio policy / mixer / resourcemanager overlays
- selected vendor / ODM files that are strongly device-specific

### Important note
V18 is still **best tuned for OnePlus 15**.  
Compatibility mode for other OnePlus models is a **safety improvement**, not a claim of perfect one-to-one optimization on every device.

Result:
- much lower chance of breaking camera or audio on non-OP15 devices
- far better publish-ready behaviour than V17 for a wider OnePlus audience

---

# ⚙️ Installation & Daily Use

| Area | V17 | V18 |
|------|------|------|
| Installation style | Traditional category-based flash | Retained |
| Runtime control after install | None | **WebUI profile switching** |
| Module status visibility | Minimal | **Clear current profile status** |
| User interaction model | Static | **Interactive** |

V18 keeps the familiar category-based installer from earlier releases, but adds a much more modern runtime layer on top of it.

That means you still get:
- category-based install choices
- the same modular approach to audio / camera / CPU / VM / network / Wi-Fi / GPS / kernel / logs

But now also:
- a visible active profile
- fast switching between usage modes
- a cleaner workflow for real-world daily use

---

# 🌐 Network, VM & General Runtime Behaviour

V17 already retained strong network and scheduler-side improvements from the V16.x line.  
V18 builds on that base by making several behaviours profile-dependent instead of fixed.

This affects areas such as:
- TCP / network pacing behaviour
- swappiness strategy
- dirty writeback timing
- GPU idle reaction
- CPU minimum frequency floors
- WALT packing sensitivity

Result: V18 is more flexible than V17 and can behave more aggressively or more efficiently depending on the selected mode.

---

# 🔋 Real-World Philosophy Shift

V17 was the better choice if you wanted a **single clean balanced tuning** with no extra user interaction.

V18 is the better choice if you want:
- one module for different usage scenarios
- a visible WebUI
- live profile changes
- broader OnePlus compatibility
- a more polished, GitHub-ready release structure

### In practical terms

| Scenario | V17 | V18 |
|------|------|------|
| Set-and-forget balanced use | Excellent | Excellent |
| Gaming profile on demand | No | **Yes** |
| Deep battery mode on demand | No | **Yes** |
| Broader OnePlus safety | Limited | **Better** |
| User-facing polish | Good | **Much better** |

---

# 📊 Summary

V18 is a **major platform upgrade** over V17.

Main V18 additions:

✔ built-in **WebUI**  
✔ **Performance / Balanced / Battery** live profiles  
✔ runtime switching through `apply_profile.sh`  
✔ improved install logic for **other OnePlus models**  
✔ safer handling of OP15-specific overlays  
✔ more polished day-to-day usability  
✔ better publish-ready structure for a public GitHub release

### Final verdict

- **V17** = refined, stable, single-profile scheduler release  
- **V18** = full-featured release with WebUI, runtime profiles and broader device strategy

V18 is the first AutoSystemBoost release that feels like a **complete user-facing product**, not just a tuned optimization package.
