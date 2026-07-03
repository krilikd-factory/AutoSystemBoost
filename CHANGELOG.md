# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V56-16a34a?style=for-the-badge" alt="V56">
  <img src="https://img.shields.io/badge/Previous-V55-6b7280?style=for-the-badge" alt="V55">
  <img src="https://img.shields.io/badge/versionCode-560-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OP12">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

## V56 — *smarter learning + memory visibility* (in progress)

Grounded in 500 real sessions of the module's own telemetry. The headline is a
fix to the environment classifier that was quietly blocking Smart Mode from ever
trusting what it learned, plus the module's first look at memory pressure.

### 🔥 Smart Mode "boiler" fixed: it was secretly running the PERFORMANCE plan
Two independent reports — "Smart turns the phone into a boiler, Balanced is
always fine" and elevated warmth on the reference device — traced to one bug in
the session planner. Its profile dispatch predates Smart Mode: it matched
`BATTERY` and `BALANCED` explicitly and everything else fell into the *else*
branch — the **performance plan**. So Smart sessions always ran with full
sensor polling, headroom reads enabled, `deep_sleep` never engaged, and — the
hot part — the **anti-clamp armed**: ASB kept re-raising the vendor thermal
engine's clamps (up to 95 °C) in a write war. The field log showed it plainly:
`cap_owner=vendor` on 59% of ticks, 96–235 mA and a 40 °C surface in
DEEP_IDLE overnight, 63–65 °C SoC peaks in daily use. Smart now plans as what
it actually is — a battery/balanced blend: **battery plans when idle or
screen-off** (sparse sensors, thermal divider, deep-sleep on, anti-clamp off)
and **balanced plans when active** (exactly the profile users report as
running cool). The storm shield also covers Smart screen-off now, which the
old dispatch accidentally excluded.

### 🧠 Learning unblocked: wake *attribution* — the user is not "noise"
Two rounds of field telemetry drove this. Round one (500 sessions) showed the
environment classifier calling **64% of sessions "hostile"** because active
screen-on use naturally has ~zero deep-idle; the idle-quality verdict is now gated
on the session being idle-dominant (≥50% of tracked time idle). Round two — 43
fresh sessions after the reset — exposed the deeper half of the same bug: **53% of
sessions were rejected as `wake_noisy`, and every single one had `wake_bg=0`** —
all their wakes were the user's own screen checks. The model was counting *you
picking up your phone* as environment noise. Every learning gate now uses
**background wakes** (`bat_wake_bg`) instead of total wake cycles: the environment
classifier's wake-rate, the trust gates and their iq wake-penalty, the
wake-noise/settle causes, the `wake_noisy` verdict, the clean-night reward, and the
wake-spike anomaly. Screen wakes remain tracked and reported, they just no longer
condemn a session. Replayed against the fresh telemetry: learn-feeding clean
sessions go **10 → 29 (23% → 67%)**, `wake_noisy` rejections **23 → 0**, and env
"hostile" **19 → ~1** (matching reality: the device's background hygiene is
genuinely clean). Session schema bumped to v16; `noisy_dim` now records the
bg/screen split so the old-logic shadow stays comparable.

### ♻️ Learning reset on upgrade — now resurrection-proof
Upgrading from V55 or earlier resets the learned state once (buckets, pstats,
app-heat, session history, auto-battery state) while preserving every user setting
and the device detection. Field data proved the first version of this reset was
being silently **defeated**: the old governor daemon is still running during
install and re-saves `buckets.bin`/pstats from memory every ~5 minutes — a
device examined after a "successful" reset held **286 pre-reset bucket sessions**
with `last_seen` timestamps older than the reset marker (this is also why the
WebUI kept showing 200+ sessions). The reset now leaves a pending marker that
`service.sh` consumes at the **next boot, before the governor starts** — deleting
the learned state again at a moment when no old daemon is alive to resurrect it.
Devices that already upgraded and got resurrected are repaired by a one-shot boot
sweep (learner state only; the append-only `session_history.jsonl` survived the
race cleanly and is kept).

### 📊 Memory-pressure visibility (first step toward memory-aware tuning)
The module recorded nothing about RAM/swap despite memory being a stated priority.
V56 samples `/proc/pressure/memory` (PSI) every tick and records a per-session
**peak pressure** and **pressured-tick count** (`mem_psi_peak`, `mem_press_ticks`).
The first cut wrote these into the WebUI status JSON only; field records proved
they never reached `session_history.jsonl`, so they are now written by the actual
session-record writer too (and stay in the live status for the WebUI). Pure
observation — no behaviour change — but it's the data needed to make memory-aware
decisions in a later release instead of flying blind.

## V55 — *device-adaptive: per-device CPU bounds + device-native vendor overlays*

The **"works properly on more than one phone"** release. Two shifts underneath it:
CPU ceilings now scale to the installing device's real hardware, and per-model
vendor tuning — audio, camera, media, GPS, Wi-Fi — is built **live from each
device's own stock files** at install instead of shipping pre-baked overlays.
Net result: **76 fewer files** shipped, and any OnePlus (not just the 15/13/12)
gets real tuning. Cumulative over V54 — all settings and learned data carry across.

### 📱 Device-native vendor overlays for every OnePlus
Dropped all pre-baked per-model overlays (canoe/alor audio SKUs, canoe
`media_profiles`, static camera tone, op12/op13 overlay sets — 79 files). A single
clone-and-patch pipeline now runs on *every* OnePlus: it clones the device's own
stock audio (keeping its real SKU + codec-specific controls like the canoe
HiFi/DS2/Audiosphere set), camera tone, `media_profiles`, GPS, perf and Wi-Fi
WCNSS, then key-patches only known values (volume→88, flat EQ, Class-H DAC, video
bitrate, GPS protocol keys, thermal/boost ceilings). Every file comes from the
device itself, so it can't mismatch its HALs. Non-reference models (Ace / T / R
series) now get full audio/camera/media/GPS/Wi-Fi tuning instead of governor-only.
OP12 keeps its `system/odm` camera carve-out (that path SIGABRTs its multicamera
HAL). The old OP15 volume fix (`volume_listener` / `audio_pre_processing`) is now
derived from the device's own cloned `audio_effects` — added only if missing,
skipped when ViPER is present — so it needs no static file either. A manifest plus
3-strike bootloop self-recovery tears the whole generated overlay back out if the
device fails to boot three times, returning it fully stock.

### ⚙️ Device-adaptive CPU frequency bounds
At install, `asb_synthesize_bounds.sh` reads the device's real per-cluster
`cpuinfo_max_freq`, scales the OP15 reference *ratios* onto it, and snaps to real
frequencies from each cluster's own table; the governor loads these over its
compiled defaults at boot. Topology-aware for 2/3/4 clusters (so a 3-cluster SoC
like the OP12 gets its middle cluster a sane ceiling), range-guarded, and
revertible — an absent or malformed bounds file just leaves the compiled defaults.
On the OP15 itself the synthesised values equal the defaults, so it's unchanged.

### 🔬 Install-time device analysis
New `asb_install_probe.sh` inventories the device's specific stock files (CPU
topology, GPU back-end, audio SKU + mixer/effects, camera/media presence, Wi-Fi
WCNSS, GPS, perf) and writes a report the installer summarises and `asbdiag`
surfaces. Pure observation — modifies nothing — so per-device patching is auditable
and a returned field bundle shows what was patchable on a device we don't own.

### 🔎 Standby tuning from real wakelock data
A full-day OP15 capture named the top idle wakeups; the GMS activity-recognition
background sampling interval is now lengthened via the existing wakelock-throttle
pass (doesn't disable location, foreground unaffected). An overnight capture
confirmed idle drain dropped ~7.9 %/h → ~1 %/h. A few OnePlus bloat services (HTMS
ads, Market auto-upgrade check, Pictorial telemetry) are now bucketed to `rare` —
restricted, not disabled; push is left alone.

### 🌐 Connectivity check + fewer debug daemons
Captive-portal check now uses Cloudflare `generate_204` with a gstatic/Google
fallback instead of the slower Google-only check (fixes spurious "no internet" on a
working connection). Developer-only daemons (crash/ramdump collectors, `ostatsd`,
`qseelogd`, `mqsasd`, `bootstat`, `cnss_diag`, …) are stopped on boot. Removed seven
redundant Bluetooth `system.prop` entries (one pinned a longer LE scan interval).

### 🎞️ WebUI: transitions, toast layering, slider-vs-swipe
All page transitions unified onto one easeInOutCubic curve and trimmed to 0.32 s —
same smooth motion, quicker. Fixed toasts appearing *under* the Config page (they
were z-index 100, below the page's 120; now 1000, above everything). Fixed dragging
a Config slider flipping the page — the swipe handler now ignores gestures that
start on a control. Removed the Device-Adaptive Bounds toggle (it's always-on now;
edit `governor.conf` to override).

### 🎥 OP15 1080p recording bitrate
Bitrate lift is now resolution-aware (parses each `<Video>` line) so 1080p lands on
40 Mbit and 4K on 100 Mbit. On-device data confirmed recording already gets 40 Mbit
via `/vendor/etc/media_profiles*.xml`; `asbdiag` had been reading the camera's own
`/odm` copy, which sits on a read-only opex partition the module can't touch, and
falsely failing. It now checks the overlaid framework file.
