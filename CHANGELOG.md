# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V49-16a34a?style=for-the-badge" alt="V49">
  <img src="https://img.shields.io/badge/Previous-V48-6b7280?style=for-the-badge" alt="V48">
  <img src="https://img.shields.io/badge/versionCode-490-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

## V49

V48 made Smart Mode learn. V49 makes it learn the *right* things and act on them sooner — predicting heat before it arrives, defending the battery when it's genuinely low, and refusing to waste power on a paused game. The prop layer was cleaned and reorganized, ZRAM setup hardened, and the Live WebUI rebuilt to be symmetric and cache-proof.

### Low-battery override with hysteresis

Smart Mode adapted to comfort, but had no special handling for a genuinely low battery — it could keep chasing responsiveness while the phone was running out. And Android's own Battery Saver, once it kicked in, never handed control back.

V49 adds a dedicated low-battery guard inside Smart Mode:

| Battery | Behaviour |
|:--|:--|
| ≤ 20 %, not charging | force `alpha_battery ≥ 800` (strong battery-lean) |
| ≤ 10 %, not charging | force `alpha_battery ≥ 900` (critical lean) |
| ≥ 40 %, **or** charging | release — return to normal adaptive behaviour |

The 20 → 40 % hysteresis stops it flapping around a single cutoff, and because the state is recomputed every tick, it **restores automatically** as the phone charges back up — no manual profile toggle needed.

### Thermal trend prediction

Previously the only thermal response was a veto at 65 °C — a hard wall hit *after* the device was already hot.

V49 measures the **rate of temperature change** over a 30-second window and leans toward battery *before* the wall, proportional to how fast things are heating:

- Engages from 45 °C when the slope exceeds ~3 °C/min, ramping the bias up to +120 alpha as the slope steepens toward ~12 °C/min.
- A lower-temperature path (from 40 °C at ~2 °C/min) catches fast early ramps.
- Stale readings (> 180 s gap) reset the estimator so a screen-off gap never produces a phantom slope.

The result is a cooler, smoother thermal profile that heads off spikes instead of reacting to them. The existing hard veto remains as the backstop.

### Per-app heat learning

V49 learns which apps actually run the device hot. A compact 16-entry table (`smart_appheat.bin`) tracks a per-app heat score, bumped when an app is foreground during a sustained thermal ramp and decayed slowly over days so stale entries fade. Known-hot apps let Smart Mode pre-bias thermals the moment they come forward, rather than waiting to be burned again. Package identities are stored as hashes, consistent with the existing privacy-by-default design.

### Drain-rate awareness

Smart Mode now folds the observed screen-on drain rate into its bias. After at least 10 minutes of screen-on time, a heavy measured drain (≈ 15 %/h and above) nudges the learner harder toward battery, while a light drain relaxes it — so the same daypart bucket adapts to whether *today's* workload is actually expensive.

### Continuous learning during light daily use

V48 added periodic learning, but it only fired when a session contained at least 60 s of heavy/gaming activity. A user on permanent Smart Mode doing ordinary things — browsing, messaging, reading — could sit for a full day showing `trust_tier: unknown` and zero sessions, and reasonably conclude the learner was dead.

V49 fires a soft session after 20 minutes of any **meaningful** use — any sustained/heavy/gaming time *or* simply the screen having been on. The learner now advances through a normal day without a single profile switch, exactly as Smart Mode was meant to work.

### Smarter gaming classification

Two refinements cut wasted power and heat around games:

- **Paused-game decay** — when a game is foreground but the FSM has settled into idle with GPU below 15 % (a menu, lobby, or loading screen), the app hint drops one level so gaming frequencies aren't held on a static image. Real render load re-promotes it instantly.
- **Confirmation gate** — a new `gaming_confirm_ticks` (default 6) requires the gaming signal to persist before the heaviest tier engages, filtering brief spikes that aren't really gameplay.

### Vendor clamp anti-thrash — persistent tier

Some kernels don't fight in bursts; they clamp slowly and relentlessly. The two-tier hold (burst, slow) kept re-engaging against them and produced needless cap writes.

V49 adds a third tier: once slow clamps cross 20 within the window, the hold-down extends to 30 seconds (from 15), so ASB cleanly yields cap ownership to an aggressive vendor governor instead of trading writes with it. Quieter logs, less turbulence, steadier behaviour under sustained load.

### Wake & UI hold-down

Animations could stutter when frequencies dropped mid-transition on app open/close. V49 widens the UI hold: the activity threshold is lowered (GPU ≥ 5 % from ≥ 8 %) so brief inter-frame dips don't release the hold, and the hold window is extended, keeping clocks up through the whole animation. Screen-wake already promotes straight to MODERATE for an instant first frame.

### ZRAM setup hardened

ZRAM re-initialization is now idempotent and race-resistant: it skips the reset entirely when the size is already correct and swap is active, and if `swapoff` fails because the device is busy it retries up to five times before continuing. Reinstalls reliably restore the full 8 GB compressed swap instead of occasionally landing in a half-configured state.

### system.prop — borrowed tuning, cleaner structure

New, device-agnostic Qualcomm parameters were added where they earn their place:

- **TurboSched** (`persist.sys.turbosched.*`, render/sf boost) and `ro.vendor.qti.am.reschedule_service` for snappier UI scheduling.
- **MGLRU** native config (`core_and_nonleaf_young`) for cheaper memory reclaim.
- **Audio SSR** (`ro.qc.sdk.audio.ssr`, `ro.vendor.audio.sdk.ssr`) for cleaner mic capture, with no effect on the playback DSP chain.

Two parameters that worked *against* a cooler, longer-lasting device were removed: `turbosched.thermal_break.enable=false` (which stopped the scheduler backing off under heat) and `ro.audio.flinger_wakelock=true` (which kept the audio subsystem awake at idle).

The property file was also reorganized. The KERNEL section had accumulated ~87 properties that didn't belong to it; these were moved into the correct categories — a new **MEDIA** section (codecs, image quality, stagefright), a new **NFC** section, plus **DISPLAY** and **BT** — each now an independently toggleable feature. KERNEL shrank from 355 to 278 lines. No property values were changed in the move.

### Audio EQ compatibility

`AUDIO_EQ_COMPAT` now defaults to **on**, so ASB yields the audio DSP chain to an external equalizer (Flow Equalizer, Wavelet, Poweramp EQ) instead of competing with it. Users who don't run an external EQ can set it to `0`.

### Live WebUI rebuilt

The Live status overlay was reworked end to end:

- **Symmetric layout** — the page and the Live overlay now share an identical box model, so the header (top) and the Telegram link (bottom) sit at the same position on both views.
- **Centering** — the Live panel is centered with a transform anchor and a single inner wrapper; native scrollbars are hidden so their width never shifts the layout off-center.
- **Portrait fits one screen** — metric cells were compacted; scrolling is enabled only in landscape, where the content genuinely doesn't fit.
- **Cache-proof** — no-cache headers were added; the KSU WebView no longer serves a stale page after an update (fully close and reopen the WebUI once after installing).
- **New metrics** — GPU Load and Headroom rows were added; the LIVE indicator now reserves red for a genuine governor fault and shows vendor clamping in amber.

### Housekeeping

- Obsolete `session_history_migrated_v47` migration removed and its marker cleaned up on boot.
- New MEDIA and NFC feature categories registered across the installer, feature gates, and lint.
- Build flag consistency and logkit trace columns updated for the new fields.

