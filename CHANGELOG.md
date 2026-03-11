# 🚀 AutoSystemBoost V19 STABLE RELEASE

Compared to V18  
Date: 2026-03-11

---

# 🌟 What Changed in V19

V19 is not just a continuation of V18 with a few tweaked numbers.  
It turns AutoSystemBoost into a more structured and more mature platform with:

- a cleaner **profile architecture**
- dedicated profile files for **Performance / Balanced / Battery**
- a new **profile core** for runtime application
- stronger **device detection and compatibility logic**
- improved **feature-aware install/runtime behavior**
- a cleaner, more publish-ready module structure

V18 introduced the idea of live runtime profiles and a built-in WebUI.  
V19 keeps that foundation, then rebuilds the internal structure to make the module more modular, more scalable and more future-proof.

---

# 🧠 Profile System & Runtime Logic

| Area | V18 | V19 |
|------|------|------|
| Profile storage | Embedded more directly in runtime logic | **Dedicated `profiles/*.sh` files** |
| Runtime profile engine | Simpler / more monolithic | **Centralized through `profile_core.sh`** |
| Profile switching model | Functional but less structured | **Cleaner worker-based switching** |
| Per-profile CPU / GPU / VM / NET values | Present | **Better organized** |
| Future maintainability | Good | **Much better** |

V19 introduces a much cleaner internal profile model:

### 🔥 Performance
Designed for stronger gaming, faster app launch and more aggressive runtime behaviour.

Typical V19 Performance direction:
- much more aggressive scheduler behavior
- stronger CPU / GPU policy separation
- lower latency VM / NET behaviour
- clearer high-performance profile identity

### ⚖️ Balanced
Default profile and the most practical everyday mode.

Typical V19 Balanced direction:
- smoother daily behaviour
- balanced CPU / VM / network policy
- cleaner profile definition than in V18
- better long-term maintainability

### 🔋 Battery
Designed for deeper power saving, lower heat and stricter background control.

Typical V19 Battery direction:
- harder CPU / scheduler limits
- more aggressive VM savings
- lower runtime overhead under saver behavior
- clearer separation from Balanced than before

✔ V19 keeps live profile switching  
✔ V19 makes the profiles structurally cleaner internally  
✔ V19 is easier to tune further without turning the module into spaghetti

---

# 🧩 Feature-Aware Module Structure

| Area | V18 | V19 |
|------|------|------|
| Feature category storage | Mostly implicit through pruning / script layout | **Explicit `features.conf`** |
| Category-aware runtime logic | More limited | **Much stronger** |
| Install / runtime consistency | Good | **Better** |
| Expandability | Moderate | **Higher** |

One of the biggest internal changes in V19 is the move to a cleaner feature-driven structure.

V19 now introduces:

- `features.conf`
- more category-aware logic in boot/runtime scripts
- cleaner separation between install-time pruning and runtime behavior
- a stronger base for enabling or disabling tweak groups consistently

This improves areas such as:
- CPU-related runtime logic
- VM / NET handling
- Wi-Fi / GPS / kernel category awareness
- log-related behavior
- cleaner future expansion of tweak groups

Result: V19 is much better structured internally than V18.

---

# 📱 OnePlus Device Compatibility

| Area | V18 | V19 |
|------|------|------|
| Main target | OnePlus 15 first | **Still OnePlus 15 first** |
| Compatibility mode | Present | **Improved** |
| Device detection depth | Good | **Much stronger** |
| Handling spoofed / modified props | Basic-good | **Better and more resilient** |
| Publish-ready non-OP15 safety | Improved over older releases | **Further improved** |

V18 already introduced compatibility logic for other OnePlus devices.  
V19 expands and strengthens that logic significantly.

This includes broader detection through:
- more product model sources
- more device/name fallbacks
- better fingerprint / boot project checks
- better tolerance for integrity-fix or spoof-heavy environments

### Important note
V19 is still **best tuned for OnePlus 15**.  
Compatibility mode for other OnePlus devices remains a **safety improvement**, not a claim of identical optimization quality everywhere.

Result:
- lower chance of dangerous OP15-specific overlay misuse
- better install behavior on non-OP15 OnePlus devices
- a much more release-ready compatibility layer than V18

---

# 🖥 WebUI & Daily Usability

| Area | V18 | V19 |
|------|------|------|
| WebUI | Yes | **Improved** |
| Live profile switching | Yes | **Retained and refined** |
| Current profile visibility | Yes | **Retained** |
| UX polish | Good | **Better** |
| User-facing structure | Strong step forward | **More mature** |

V18 was the first release that made AutoSystemBoost feel like a real user-facing module instead of a static flash package.

V19 improves that user-facing layer by keeping the same core idea but building it on top of a cleaner internal system.

That means you still get:
- profile cards for **Performance / Balanced / Battery**
- visible active profile state
- live switching without reflashing
- a cleaner daily workflow

But now also:
- a more structured backend
- better profile organization behind the UI
- a stronger foundation for future UI/runtime consistency

Result: V19 keeps the convenience of V18, but stands on a more mature backend.

---

# ⚙️ Installation, Structure & Maintainability

| Area | V18 | V19 |
|------|------|------|
| Install logic | Good | **Better** |
| Script permission handling | More basic | **Improved** |
| Internal file organization | Solid | **Cleaner** |
| `system.prop` structure | Large and effective | **Cleaner grouped layout** |
| Long-term maintainability | Good | **Much better** |

V19 is not mainly about adding one flashy visible feature.  
Its real strength is that the module becomes cleaner internally:

- profile values are separated from profile application logic
- script roles are more clearly split
- runtime logic is more organized
- prop grouping is cleaner than before
- category behavior is more explicit

This matters because V19 is easier to continue developing without piling everything into one giant script.

Result: V19 is the first version that feels less like an evolved tweak pack and more like a real structured platform.

---

# 🌐 Runtime Behaviour Philosophy Shift

V18 was the better choice if you wanted:
- live profiles
- WebUI control
- broader OnePlus compatibility
- a major jump from older static releases

V19 is the better choice if you want:
- the same user-facing convenience
- a cleaner internal profile system
- better modularity
- stronger compatibility logic
- a more future-proof branch for continued development

### In practical terms

| Scenario | V18 | V19 |
|------|------|------|
| First full user-facing release feeling | Excellent | **Excellent** |
| Internal profile cleanliness | Good | **Much better** |
| Runtime architecture maturity | Good | **Better** |
| Future tuning flexibility | Good | **Much better** |
| Public GitHub release structure | Strong | **Stronger** |

---

# 📊 Summary

V19 is a **major structural upgrade** over V18.

Main V19 improvements:

✔ dedicated **`profiles/*.sh`** profile files  
✔ new centralized **`profile_core.sh`** runtime profile layer  
✔ stronger **feature-aware module behavior** through `features.conf`  
✔ improved **OnePlus compatibility and device detection**  
✔ cleaner **install/runtime separation**  
✔ improved **WebUI backend structure**  
✔ better **maintainability and future scalability**  
✔ a more polished **GitHub-ready release base**

### Final verdict

- **V18** = strong user-facing release with WebUI, live profiles and improved OnePlus compatibility  
- **V19** = cleaner, more modular and more mature evolution of that platform

V18 was the release that made AutoSystemBoost feel like a complete product.  
V19 is the release that makes it feel like a **proper long-term platform**, not just a powerful module.
