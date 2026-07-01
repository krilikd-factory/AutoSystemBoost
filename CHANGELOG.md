# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V55-16a34a?style=for-the-badge" alt="V55">
  <img src="https://img.shields.io/badge/Previous-V54-6b7280?style=for-the-badge" alt="V54">
  <img src="https://img.shields.io/badge/versionCode-550-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OP15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OP13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OP12">
  <img src="https://img.shields.io/badge/+%20any%20OnePlus-device--native-8b5cf6?style=flat-square" alt="any OnePlus">
</p>

---

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
