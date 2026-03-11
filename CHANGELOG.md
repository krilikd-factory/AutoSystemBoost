# 🚀 AutoSystemBoost V19.1 BUGFIX RELEASE

Compared to V19.0  
Date: 2026-03-11

---

# 🛠 What Changed in V19.1

`ASB-V19.1` is a focused **bugfix and safety update** for the V19 branch.

This release does **not** try to reinvent the module.  
Instead, it fixes several real issues reported after `ASB-V19`:

- Dropbox app data being affected by overly broad cleanup paths
- Wi-Fi / Bluetooth scanning related breakage on some systems after reboot
- audio crackling / volume issues on some custom kernels
- higher Wi-Fi instability risk on non-standard vendor stacks such as ZeroMount / OverlayFS / SUSFS

In other words:

**V19 = major structural platform update**  
**V19.1 = stability + safety cleanup for real-world usage**

---

# 📦 ASB-V19.0 vs ASB-V19.1

| Area | V19.0 | V19.1 |
|------|------|------|
| Dropbox cleanup safety | Risky wildcard cleanup | **Safe targeted cleanup** |
| Wi-Fi / BT scan settings persistence | Could persist unwanted disabled scan state | **Removed problematic forced scan toggles** |
| Audio behavior on some custom kernels | Could trigger limiter-related crackling | **Audio hygiene block disabled** |
| ZeroMount / OverlayFS / SUSFS risk handling | More exposed | **Risk mitigation added** |
| Overall daily safety | Good | **Better** |
| Overall public release readiness | Strong | **Stronger** |

---

# ☁️ Dropbox Bug Fixed

## Problem
In older V19 builds, cleanup logic used wildcard paths broad enough to match Dropbox app data paths.

That could hit:

- `com.dropbox.android`

and lead to broken app data or the impression that Dropbox was being removed.

## Fix in V19.1
The old broad cleanup behavior was replaced with **targeted Android DropBoxManager log cleanup only**:

- `/data/system/dropbox`
- `/data/vendor/dropbox`

And instead of deleting everything, V19.1 keeps only the newest log files.

### Result
✅ Dropbox app data is no longer touched  
✅ only Android system DropBox logs are trimmed  
✅ much safer install behavior

---

# 📶 Wi-Fi / Bluetooth Scan Bug Fixed

## Problem
Some earlier V19 behavior could force these values to `0`:

- `wifi_scan_always_enabled`
- `wifi_wakeup_enabled`
- `ble_scan_always_enabled`

On some systems those values could persist inside global settings and survive reboots.

That could lead to ugly behavior such as:
- broken Wi-Fi state after reboot
- scan-related weirdness
- users thinking Wi-Fi itself was dead

This was especially suspicious on more unusual mount / overlay setups.

## Fix in V19.1
These forced scan-related settings were removed from the active module logic.

### Result
✅ no more persistent forced-off scan toggles  
✅ lower risk of Wi-Fi / BT state corruption after reboot  
✅ safer behavior on more customized systems

---

# 🔊 Audio Crackling / Volume Issue Fixed

## Problem
A kernel-related path in V19 could apply audio-effect hygiene that disabled limiter-related behavior.

On some custom kernels and audio stacks, such as WildKernels-style setups, this could lead to:

- crackling
- clipping
- unstable loudness behavior

## Fix in V19.1
The audio hygiene block is no longer applied through the kernel optimization path.

### Result
✅ lower chance of crackling on custom kernels  
✅ safer behavior for aggressive custom audio / kernel stacks  
✅ kernel optimizations no longer silently interfere with audio processing

---

# 🧩 ZeroMount / OverlayFS / SUSFS Risk Mitigation

## Problem
Users with more exotic vendor / meta-mount stacks may not behave like normal stock-style vendor overlay environments.

In those environments, some Wi-Fi related commands can become more risky than useful.

## Fix in V19.1
V19.1 adds detection for risky vendor stack environments such as:

- ZeroMount
- OverlayFS
- SUSFS

When such a setup is detected, certain Wi-Fi DTIM / listen-interval behavior is skipped instead of forced.

### Result
✅ lower chance of Wi-Fi instability on non-standard vendor stacks  
✅ safer behavior for users with advanced KSU / overlay setups  
✅ better defensive runtime logic

### Important note
This is **risk mitigation**, not a magical guarantee against every possible meta-mount configuration.  
But it is still a meaningful safety improvement over V19.0.

---

# 🧠 Runtime Safety Philosophy in V19.1

V19.1 keeps the strengths of V19:

- cleaner profile architecture
- centralized runtime profile handling
- feature-aware module logic
- improved compatibility structure
- stronger WebUI-based profile control

But improves the practical side by being less reckless in several sensitive areas.

### In short

| Goal | V19.0 | V19.1 |
|------|------|------|
| Strong tweak platform | ✅ | ✅ |
| Better real-world safety | ⚠️ good, but rough in places | **✅ better** |
| Bugfix maturity | Moderate | **Higher** |
| Safer public release quality | Good | **Better** |

---

# ✅ Summary

`ASB-V19.1` is a **real bugfix release**, not a cosmetic version bump.

Main fixes:

✔ Dropbox cleanup logic made safe  
✔ Wi-Fi / Bluetooth scan persistence bug fixed  
✔ audio crackling risk reduced on custom kernels  
✔ risky vendor stack mitigation added for Wi-Fi behavior  
✔ safer real-world behavior for public release use

### Final verdict

- **V19.0** = major structural release of the new ASB platform  
- **V19.1** = the safer, cleaner and more reliable bugfix follow-up

If you are already on V19, then **V19.1 is the recommended public release build**.
