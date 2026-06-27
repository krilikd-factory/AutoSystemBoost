# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V54-16a34a?style=for-the-badge" alt="V54">
  <img src="https://img.shields.io/badge/Previous-V53-6b7280?style=for-the-badge" alt="V53">
  <img src="https://img.shields.io/badge/versionCode-540-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## V54 — *boot, thermals, camera & audio*

The biggest release since V53. The headlines: every OnePlus on a flagship's chip now **boots** (not just the 15/13/12); a full round of **data-driven thermal and battery tuning** from real full-day logs runs the device cooler and longer; the camera tweak becomes a real **strength slider** that also affects photos; and a stack of field-report bugs — toggles resetting, quiet audio, Wi-Fi region — are fixed. Cumulative over V53 — nothing removed, all settings and learned data carry across.

### 🌡️ Data-driven thermal & battery tuning (runs cooler, lasts longer)
A full pass of tuning grounded in real full-day OP15 logs, aimed squarely at heat and battery — with responsiveness held intact (verified on-device across multiple capture cycles).
- **Enters thermal economy sooner.** Logs showed the phone's surface reaching ~48 °C while the SoC was only ~54 °C, but the governor didn't start easing back until 57 °C — a window where heat built up unchecked. The Smart/Balanced sustained-temperature threshold is lowered (`balanced_sustained_temp_enter` 57 → 54 °C, exit 49 → 48 °C), so caps engage a few degrees earlier and catch the heat before the surface climbs. It's a *reaction* threshold, not a hard cap, and the existing self-tune still raises it back if the device genuinely needs the clocks.
- **Lower battery-profile ceilings.** The battery profile (and Smart when it leans battery-ward) now caps the prime cluster lower for real heat savings under sustained load — prime ceiling **2208 → 1632 MHz**, little **1805 → 1670 MHz**, GPU ceiling **50 % → 44 %** (floor 45 → 40 %). Every value is a real hardware frequency step, and interactive bursts still ramp toward the balanced ceiling so taps and scrolls stay snappy — only sustained load is held lower.
- **Deeper GPU idle trim.** With logs showing the GPU at 0 % busy for ~77 % of screen-on time, the light-state GPU ceiling trim is increased from −8 % to **−12 %** — still floored at 55 % and still gated off during video, gaming and thermal capping (see the GPU-trim section below for how the detector works). More saved on the wasteful ramp, no responsiveness cost.
- **Stronger autonomy dial.** The **Smart Battery Bias** slider's range is raised from 0–300 to **0–600**. Logs revealed that at the old max the effective lean topped out before reaching battery-like behaviour during active use; the higher ceiling lets a confident Smart actually push active use into the deeper economies. Still confidence-scaled and hard-capped at pure-battery behaviour, so it can never over-shoot.

### 🔋 Video-aware GPU ceiling trim (cooler & longer battery, no perf loss)
- A full-day OP15 capture showed the GPU is the dominant power/heat driver — about 728 mA at >40% busy versus ~231 mA near idle — and that high-GPU moments are either video playback (high GPU, low CPU load) or gaming (high GPU, high CPU load). Cutting either would cause stutter or fps loss, so neither is touched. Outside both, the GPU ceiling sat far above what light UI ever needs, letting brief spikes ramp the GPU higher than necessary. The governor trims the GPU ceiling in the light LIGHT_IDLE/MODERATE states **only when it detects neither video nor gaming** (now −12%, never below 55%), saving the wasteful ramp. A short sustained-GPU+low-CPU detector gates it off the instant video starts. Disabled in the performance profile and whenever thermal capping is already active. Tunable: `gpu_idle_trim_pct`, `gpu_idle_trim_floor`, `gpu_video_busy_min`.

### 🔎 Wakelock attribution without debugfs (logkit)
- On OP15 the kernel `wakeup_sources` debugfs isn't readable, so the log collectors couldn't say what kept the device awake. They now also pull a full Android-side view from `dumpsys batterystats` — top partial-wakelock holders by time, alarm/wakeup counts, estimated per-app power, and background jobs — refreshed hourly and parsed into a ranked `_wakelock_report.txt` that names the actual offenders. The capture's own wakelock is excluded from every list. This is what enables real, targeted standby tuning next.

### 🛠️ Boot fix for SoC-siblings (Ace 6 & others)
- Per-device tuning was matching purely on the SoC, so any OnePlus on the same chip as the 15/13/12 was handed the flagship's vendor overlay. On a different device (e.g. **OnePlus Ace 6**, codename `ktm`, same SM8750 as the 13) that overlay mismatched the HALs and **bootlooped**.
- Detection is now an **allowlist**: only the real `canoe` / `sun` / `pineapple` families get a device overlay. Every other OnePlus on those chips (Ace 6, Ace 5/3 family, 13T/13s, 15R/15T…) falls through to the generic-safe path — full governor tuning, no overlay, so it **boots on any sibling**.

### 📷 Camera grade slider (replaces the on/off aggressive toggle)
- The single "Aggressive Camera Tweaks" switch is now a **Camera Grade** slider with five steps: **0 stock (off) · 1 Safe · 2 Moderate · 3 Strong · 4 Max**. Each step scales a coherent set of tone, colour, sky and shadow-contrast keys so the difference is actually visible, building from a gentle lift to a punchy max (the top levels push saturation/contrast hard and can band in deep shadows — by design).
- The grade now affects **photo as well as video** — it drives the global colour and local-contrast keys in `TMCParamsSet`, which both pipelines honour, not just the video-only tone keys.
- **Per-device tuned:** OP15 (canoe) is the reference; OP13 (sun) runs one notch softer at each level since it banded earlier in testing. OP12 (pineapple) keeps its camera stock — its SM8650 stack doesn't use this tuning file, so the slider is a no-op there and its camera path stays untouched on APatch.
- The chosen level **survives reinstall and update**, and the old `CAMERA_AGGRESSIVE=1` maps to level 3 automatically.

### 🔊 OP15 playback volume fix (every boot, not just reinstall)
- On OP15, audio could be noticeably quiet (e.g. YouTube) until ViPER4Android was opened. The shipped `audio_effects_config.xml` (sku_canoe / sku_alor) still **applied** the `music_helper` effect to the music stream but had **dropped its definition and the `volume_listener` library** — and `volume_listener` is exactly the effect that scales digital gain with the volume slider. Without it, output sat at a fixed low gain until ViPER attached its own session.
- Because that config is a static system overlay mounted on **every boot**, the quiet sound happened on every reboot, not only after a reinstall. Restored the missing `volume_listener` / `audio_pre_processing` libraries and the helper effect definitions to match stock, so volume scales correctly out of the box. (OP13/OP12 were never affected — they clone the device's own stock config.)

### 🔧 Field-report fixes
- **WebUI toggles no longer reset or flip back on their own.** Two parts to this. (1) Saved switches are mirrored to an external snapshot at `/data/adb/asb/governor.conf.snapshot` and restored on the next install even when the old module directory has already been swapped out by the root manager — that fixes resets across a *version jump*, and the installer prints how many settings it restored. (2) The snapshot is now refreshed the instant you change a toggle in the WebUI, not only at install time — previously a switch changed after install was missing from the snapshot, so a later re-trigger by the root manager quietly reverted it to the shipped default. That's the "switches flip back by themselves after a while" report, now closed.
- **Wi-Fi region no longer forced to Italy.** The profiles shipped a hard-coded `WIFI_COUNTRY=IT`, which overrode the SIM/operator-derived country on every device. It's now empty by default, so the correct regulatory domain is taken from your SIM/operator as intended; setting a 2-letter code remains available as an explicit manual override.
- **RAM Expansion "off" now actually works.** Root-caused with on-device data: when the OP13 owner turns the feature off in Settings, OxygenOS stores `ram_expand_size=0` / `ram_expand_size_list=0`, so `0` is the correct "off" value. The reason an earlier build re-enabled it was that the module also wrote several *guessed* companion keys (`ram_expand_switch_state`, `oplus_customize_ram_expand_size`, …) that OOS reacted to by switching expansion back on. Those guessed keys are removed — ASB now writes only the two real keys to `0`, at boot and re-asserted ~60 s later. A diagnostic log and a logkit key-probe were added to confirm the values per device.
- **No more `.AutoSystemBoost-files` / `CLEAR` litter.** The Magisk install template writes a per-file restore index (`/data/adb/modules/.AutoSystemBoost-files`) during install and keeps it whenever it's non-empty. ASB ships its own uninstall.sh and never uses that list, so it's pure litter — it's now removed unconditionally as the very last install step (after every permission pass that could recreate it), along with the stray `CLEAR` dir, across every modules root. Uninstall clears them too.

### 🎙️ HD microphone recording
- Added 24/32-bit microphone capture so recordings are made at higher bit depth instead of the default 16-bit, with compressed (AAC) capture turned off so the path stays linear PCM, plus simultaneous record + playback. All vendor-side — works in any recording app, nothing to toggle.

### 🔉 Audio voice-processing effects restored
- Re-added the AEC (echo cancellation) and NS (noise suppression) pre-processing effects to the OP15 (canoe/alor) effects config, alongside the volume-listener restoration above, matching the stock voice pipeline.

> Cumulative — nothing removed. All settings and learned data carry across the update.

---

## V53

- **LSPosed compatibility.** Removed the USAP app-process-pool properties (`dalvik.vm.usap_pool_enabled`, `persist.sys.dynamic_usap_enabled`, `persist.sys.usap_pool_enabled`). Force-enabling the unspecialized app-process pool made processes fork past the zygote hook point, which sent **LSPosed into safe mode**. Confirmed on OnePlus 13: with them gone, LSPosed and ASB run together cleanly.
- **WebUI learner readout.** The learner no longer shows "learning 0%" after a reboot. Session history was already restored on boot, but the displayed confidence was only written on a live session commit, so it sat at 0 until the next session. It's now also seeded on load from the highest-confidence persisted bucket, so the readout stays continuous across reboots.
