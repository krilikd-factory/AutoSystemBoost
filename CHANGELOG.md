# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V60-16a34a?style=for-the-badge" alt="V60">
  <img src="https://img.shields.io/badge/Previous-V59-6b7280?style=for-the-badge" alt="V59">
  <img src="https://img.shields.io/badge/versionCode-600-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OP12">
  <br>
  <img src="https://img.shields.io/badge/OnePlus%20Ace%206-SM8750-06b6d4?style=flat-square" alt="Ace 6">
  <img src="https://img.shields.io/badge/OnePlus%20Ace%205-SM8650-14b8a6?style=flat-square" alt="Ace 5">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

## V60 — *the DSP release*

The headline is an audio engine that did not exist before: ASB now ships its own
effect, built from scratch, registered into the device's own effects config and
attached to the global mix. Around it, the audio settings were rebuilt into three
clear choices instead of a pile of flags. Everything else in this release came from
full-day field logs on real phones — a 4K60 recording that stuttered, a prime core
capped at 48 % of its own hardware, and three settings that reported success while
doing nothing at all.

### 🎚 ASB DSP — a real audio engine
Loudness that the volume curves cannot give you: real gain **above** unity, with a
soft-knee compressor, automatic make-up and a true-peak limiter so nothing clips on
the way out. `dsp_loudness` takes any value from 1 to 20 dB; `dsp_bass` adds a 90 Hz
low shelf at the head of the chain, so the compressor and limiter both see the
boosted low end rather than letting it escape every safeguard.

The engine is shipped twice from one shared core: a legacy effect and an **AIDL**
port, because Android 13+ binds effects through the `android.hardware.audio.effect`
AIDL contract and a legacy `.so` is simply never attached to the stream. A companion
daemon creates the effect programmatically on the global mix — OxygenOS never applies
config-declared post-processing, which is why every session-attached effect stays
silent until you open an EQ app. Moving a slider is handed to the live effect over
binder: no `audioserver` restart, no drop-out.

### 🎵 Audio, rebuilt around three clear choices
`AUDIO_AGGRESSIVE` and `AUDIO_EQ_COMPAT` are gone. In their place:
- **`audio_profile`** — `stock`, `hifi`, or `eq_compat` (hands the stream to ViPER
  and friends; the ASB DSP steps aside there rather than fighting for the output).
- **`audio_dac_hifi`** — the mixer half on its own switch: Class-H DAC, flat EQ,
  companders off.
- **`media_loudness`** — reshapes the music volume curves themselves, position-
  weighted so the boost lands where people actually listen (40–80 % of travel) and
  the quietest steps stay exactly where stock put them. 100 % is never raised — that
  is unity, and past it you only clip.

### 📷 Camera hold — 4K60 recording gets its clocks back
The load classifier reads GPU busy and the one-minute loadavg, and a camera capture
lights up neither: the ISP and the hardware encoder carry the work. So the state
machine sat in MODERATE through an entire recording while the pipeline missed its
16.6 ms frame deadline — on one device against a prime cluster declared at 48 % of
its ceiling. ASB now holds interactive caps for as long as the camera streams,
restores the `foreground`/`top-app` cpuset to every core, lifts the `uclamp.max`
ceilings the camera HAL sits under (`foreground` was never managed at all — and
neither the camera HAL nor the media codec is top-app), and eases swappiness.

Every value is read back before it is touched and restored to exactly what was
found. Thermal protection is untouched: only the *soft* battery lean is overridden,
the junction hard-limit and the thermal cap still throttle. Set
`camera_hold_enable=0` for the old behaviour.

### ⚡ The prime core is no longer the slowest thing on the phone
On 3- and 4-cluster SoCs the balanced and performance ceilings were capping slot 2 —
the single strongest core. Measured side by side on one device, same profile and
screen state, the prime ran at **48 % of its hardware ceiling instead of 100 %**: it
felt sluggish and saved no battery, because the little and mid clusters simply spent
longer at their own caps. Both profiles leave the prime alone again. Battery still
caps it — that profile exists to trade speed away.

### 🔎 An action screen that says what did *not* apply
The report was rewritten around one idea: a setting that silently does nothing is
invisible everywhere else. A new **NOT APPLIED** section checks the system for
evidence that each configured tweak actually landed and lists only what did not —
and it names *where* things landed, so a report answers its own questions. Alongside
it: live battery lean, learning confidence, thermal veto and night-safe state,
screen-on and idle runtime estimates, and per-section detail for audio, camera,
memory, network, Wi-Fi and GPS.

### 🧩 Overlay delivery — three settings that reported success and did nothing
- **The DSP effect was registered on the reference device only.** Registration now
  runs on every model, covers per-SKU layouts under both `audio_effects_config.xml`
  and `audio_effects.xml`, clones the config the framework will actually read when
  the overlay has none, and delivers odm-side files through the fuse-guarded runtime
  bind. `persist.asb.dsp.enable` is now published on a first install instead of
  waiting for someone to touch the WebUI.
- **`media_loudness` could only ever be applied by flashing.** The curve reshape
  lived in the installer and nowhere else, so changing it in the WebUI wrote the
  config, promised a reboot, and rebuilt nothing. It is now shared code, called at
  runtime, and boot self-heals a table that does not match the setting.
- **The camera configs under `/odm` were never delivered** on a root manager that
  does not magic-mount the odm tree. They now use the same runtime bind the audio
  configs already did.

### 🎨 WebUI
Every setting card carries its category colour — audio, camera, battery,
performance, UX, display, memory, system — and the confirmation that slides up from
the bottom now echoes the colour of the card you touched instead of the profile
palette. New cards for the audio rework, the DSP sliders, and `disable_blur`.

### 🧹 Smaller things
- Wi-Fi diagnostics no longer assert a regulatory domain ASB stopped forcing long
  ago — that check fired on every device that has ever had a SIM in it.
- `overlay: 0 mounts` was never a fault: Magisk mounts in a private namespace, so
  the count reads zero even when the overlay is live. The screen now probes a file
  the overlay actually delivers.
- Bluetooth adaptive bitrate (SBC/AAC ABR) enabled — steadier links on weak signal.
- The camera guard's saved state survives a governor restart, so a session that ends
  the hard way cannot leave ceilings raised.

---
