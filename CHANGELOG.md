# 🚀 AutoSystemBoost V21 MAJOR RELEASE

Compared to V20  
Date: 2026-03-12

---

# 🌟 What Changed in V21

`ASB-V21` is not a small follow-up to V20.  
It is the release where AutoSystemBoost moves from a strong profile-based module into a **native adaptive runtime platform**.

While `V20` already introduced a smarter profile system with stronger runtime behavior, `V21` adds a much bigger leap:

- a built-in **native governor**
- adaptive runtime state handling
- socket-based profile control
- bundled governor binary inside the module
- better profile retention and stronger real-world separation between modes
- cleaner shell/runtime role split
- more advanced diagnostics and developer visibility

In simple terms:

**V20 = strong modern profile release**  
**V21 = first native adaptive governor release**

---

# 🧠 Native Adaptive Governor

| Area | V20 | V21 |
|------|------|------|
| Runtime brain | Shell-driven runtime logic | **Native governor daemon** |
| Control path | Shell profile apply + runtime logic | **Socket-controlled adaptive runtime** |
| Governor process | No | **Yes** |
| State tracking | Implicit / script-driven | **Explicit runtime states** |
| Adaptive FSM | No | **Yes** |
| Runtime logs / state files | Basic | **Much stronger** |

The biggest V21 change is the introduction of a **native governor**.

This means AutoSystemBoost no longer relies only on shell logic for runtime control.  
Instead, V21 introduces a dedicated binary runtime layer that can:

- stay alive as a daemon
- track runtime state
- receive profile commands
- manage adaptive transitions more intelligently
- expose status/state information for diagnostics

### Result
✅ runtime behavior becomes more coherent  
✅ profile switching is no longer just a file change  
✅ the module feels more like a real governor platform than a shell tweak pack

---

# ⚙️ Runtime State Engine

| Area | V20 | V21 |
|------|------|------|
| Runtime state visibility | Limited | **Visible / structured** |
| Adaptive state machine | No | **Yes** |
| Idle / active distinction | Profile logic only | **Native runtime states** |
| Heavy / gaming behavior | Indirect | **Explicitly modeled** |

V21 introduces an adaptive runtime state model with states such as:

- `DEEP_IDLE`
- `LIGHT_IDLE`
- `MODERATE`
- `HEAVY`
- `GAMING`

Instead of treating runtime behavior as only static profile values, V21 can now adjust behavior according to what the device is actually doing.

### Why this matters
This creates a much more natural separation between:
- idle behavior
- everyday use
- heavier activity
- gaming / high GPU load

### Result
✅ better real-world behavior  
✅ stronger runtime identity  
✅ less dependence on blunt static assumptions

---

# 🔄 Profile Switching Is More Real

| Area | V20 | V21 |
|------|------|------|
| Live profile switching | Yes | **Yes** |
| Runtime profile command path | Shell-heavy | **Governor-aware** |
| Internal profile state | Good | **Stronger** |
| Profile persistence / retention | Good | **Better** |

V20 already had runtime profiles.  
V21 makes them feel much more real.

The profile system in V21 is no longer just:
- write profile file
- hope shell logic applies it cleanly

Instead, V21 adds a stronger control path where profile changes can be communicated to the running governor.

### Result
✅ profile changes feel more coherent  
✅ Battery / Balanced / Performance are more clearly separated  
✅ runtime profile identity is stronger than in V20

---

# 🔋 Battery Profile Maturity

| Area | V20 | V21 |
|------|------|------|
| Battery profile identity | Strong | **More real and more reliable** |
| Battery mode separation | Good | **Better** |
| Runtime application confidence | Good | **Higher** |

Battery in V21 feels less like a decorative saver label and more like a genuinely distinct runtime mode.

Compared to V20, V21 improves:
- profile control consistency
- runtime ownership
- actual differentiation from Balanced and Performance

### Result
✅ Battery behaves more like a true saver profile  
✅ less chance of profile logic collapsing into a “balanced-only” feel  
✅ stronger day-to-day confidence in the Battery profile

---

# ⚖️ Balanced Profile Refinement

Balanced was already very strong in V20.  
V21 keeps that strength but places it inside a more advanced runtime system.

### In practical terms
Balanced in V21 becomes:
- a more stable default profile
- a cleaner middle ground between Battery and Performance
- a better anchor for the adaptive governor logic

### Result
✅ stronger default daily profile  
✅ cleaner interaction with runtime states  
✅ better overall consistency

---

# 🔥 Performance Profile Improvements

| Area | V20 | V21 |
|------|------|------|
| Performance identity | Strong | **Stronger** |
| Runtime handling | Profile-driven | **Governor-aware** |
| High-load behavior | Better than older builds | **More structured** |
| Gaming-oriented logic | Limited | **Improved** |

Performance in V21 benefits from the new governor architecture more than any other profile.

### Why
Because Performance is the profile most sensitive to:
- runtime state changes
- high-load response
- profile drift
- real ceiling retention

With V21, the module is much better positioned to behave like a real performance mode instead of only a set of static values.

### Result
✅ stronger high-load identity  
✅ better platform for gaming-oriented behavior  
✅ more mature direction for future runtime tuning

---

# 📦 Bundled Governor Binary

| Area | V20 | V21 |
|------|------|------|
| Native binary included | No | **Yes** |
| Runtime binary deployment | No | **Yes** |
| Native source tree | No | **Yes** |

V21 introduces a bundled native governor binary together with its source code.

This is a major structural shift.

The module is no longer only:
- shell scripts
- props
- profile files
- WebUI

It now also contains:
- native governor source
- native build flow
- packaged runtime binary

### Result
✅ stronger technical foundation  
✅ better path for future growth  
✅ clearer separation between runtime engine and shell helper layer

---

# 🧩 Shell Layer vs Governor Layer

One of the most important V21 improvements is architectural, not cosmetic.

V20 still relied heavily on shell logic as the main runtime owner.  
V21 begins to split responsibilities more cleanly:

### Governor handles
- adaptive runtime state
- live governor logic
- runtime profile ownership
- state / log / socket control

### Shell remains responsible for
- module bootstrap
- profile safety net
- fallback behavior
- supporting one-shot tasks

### Result
✅ cleaner runtime architecture  
✅ less “everything in service.sh” pressure  
✅ better long-term maintainability

---

# 🔍 Better Diagnostics & Debugging

| Area | V20 | V21 |
|------|------|------|
| Runtime visibility | Limited | **Much better** |
| Explicit state file | No | **Yes** |
| Governor log | No | **Yes** |
| Runtime status reporting | Limited | **Yes** |

V21 introduces a much stronger diagnostic layer through:

- runtime state files
- governor logging
- explicit status reporting
- better visibility into what the runtime layer is actually doing

This matters not only for development, but also for trust:
V21 is easier to verify and easier to debug than V20.

### Result
✅ better transparency  
✅ better troubleshooting  
✅ more confidence when validating Battery / Balanced / Performance behavior

---

# 🎨 WebUI & Presentation

| Area | V20 | V21 |
|------|------|------|
| WebUI baseline | Good | **Cleaner / more polished** |
| Version presentation | Good | **Updated** |
| Encoding / display handling | Good | **Improved** |
| General product feel | Strong | **More mature** |

V21 continues polishing the visual and user-facing layer with:
- cleaner presentation
- better handling of display details
- a more product-like feel

This is not the main reason to upgrade, but it contributes to the overall maturity of the release.

---

# 🛠 Codebase Scope of the Upgrade

Compared to V20, V21 adds or changes meaningful code in areas such as:

- `service.sh`
- `action.sh`
- `module.prop`
- `common/install.sh`
- `common/functions.sh`
- `webroot/index.html`
- `src/asb_governor.c`
- `src/asb_fsm.h`
- `src/asb_metrics.h`
- `src/asb_learner.h`
- `src/asb_writer.h`
- `src/asb_socket.h`
- native build scripts / native Makefile
- bundled governor binary

This is a true platform-level change, not a cosmetic version bump.

---

# 📊 Real Philosophy Shift

V20 was the release where AutoSystemBoost became a strong profile platform.

V21 is the release where AutoSystemBoost begins to behave like an **adaptive runtime system**.

### In practical terms

| Scenario | V20 | V21 |
|------|------|------|
| Strong profile-based tuning | Excellent | Excellent |
| Native adaptive runtime | No | **Yes** |
| Distinct profile identity | Good | **Better** |
| Runtime introspection | Good | **Much better** |
| Long-term governor foundation | Limited | **Strong** |

---

# ✅ Summary

`ASB-V21` is a **major architectural release** over `ASB-V20`.

Main V21 additions:

✔ built-in **native adaptive governor**  
✔ explicit runtime state engine  
✔ socket-based profile control  
✔ bundled governor binary and source tree  
✔ stronger Battery / Balanced / Performance separation  
✔ cleaner shell vs runtime role split  
✔ much better runtime diagnostics  
✔ more mature WebUI and product polish  

### Final verdict

- **V20** = strong profile-based major release  
- **V21** = first true native adaptive governor release

If V20 moved ASB forward as a better runtime profile platform, then **V21 is the release that turns ASB into a real adaptive runtime system**.
