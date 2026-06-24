# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V52-16a34a?style=for-the-badge" alt="V52">
  <img src="https://img.shields.io/badge/Previous-V51-6b7280?style=for-the-badge" alt="V51">
  <img src="https://img.shields.io/badge/versionCode-520-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## V52 — *field-tuned*

> The headline of V52: **full, first-class support for OnePlus 15, 13 and 12** — three SoC generations (SM8850 / SM8750 / SM8650), all device-tuned and field-tested on real hardware. Plus a long-standing OnePlus 12 + APatch camera bug finally solved at the root, a smarter and more autonomous Smart mode, and a round of honesty fixes driven entirely by on-device logs.

**Highlights over V51**

- 📱 **Three devices, fully tuned.** OnePlus 15 (canoe / SM8850), OnePlus 13 (sun / SM8750) and OnePlus 12 (pineapple / SM8650) are now all primary targets — per-device CPU/GPU topology, audio SKU, camera overlays and thermal shapes, each validated on real units.
- 📷 **OnePlus 12 + APatch camera — fixed at the root.** The multicamera HAL crash that broke the camera on OP12 under APatch (even with camera tweaks off) is solved: the tweak engine no longer touches the camera path on that specific combination, while OP12 + KernelSU and OP13/OP15 keep the full tweak set. Scoped precisely by reliable root-manager detection.
- 🔋 **Smart mode leans further into autonomy — safely.** A new short screen-off tier reclaims the easy battery savings in brief "glance and put down" windows the logs showed Smart was missing, with zero cost to responsiveness during active use. Plus a new **Smart Battery Bias** slider in the WebUI for users who want to push economy further.
- 🛰️ **GPU caps actually work on OP15 now.** The Adreno 840 leaves the devfreq frequency nodes empty and is driven by pwrlevel instead, so the per-profile GPU caps were a silent no-op on OP15. A safe pwrlevel fallback fixes it without ever overclocking past the vendor's thermal ceiling.
- 📊 **"Запас" (headroom) no longer stuck on n/a.** On SM8850 the kernel's headroom signal latches as unreliable early in a boot and never recovered; it now re-validates once the signal proves trustworthy again.
- 🧪 **Logkit is now genuinely useful for autonomy.** Captures land on `/sdcard` next to the diag report instead of inside Termux's private dir, the trace records real battery-current draw, and a wake-source snapshot lets standby drain be attributed instead of guessed.
- 🩺 **A full pre-release audit** caught and fixed a stale governor version string and a shipped-config parity gap, on top of verifying markers, bounds, workflows, and that all `rm -rf` are scoped.

> Cumulative on top of V51 — nothing from V51 was removed. Existing users keep every setting across the update (see Config Persistence). Reboot once after flashing.

---

### Detailed changes

### Config persistence: Smart Battery Bias carries across reinstall and updates

asb_preserve_user_config migrates the user's WebUI choices over the freshly-shipped governor.conf on every reinstall/update, but it works from an explicit key list — and the new smart_battery_bias wasn't in it, so a slider value would have reset to default on the next flash. Added it to the preserved keys, verified by simulation that a user value (e.g. 150) survives a clean reinstall. The rest of the persistence story is intact: profile selection lives in /data/adb/asb/active_profile and Smart's learned data plus smart_mode_enabled live under /data/adb/asb/, all outside the module dir, so they survive flashing an update.

### WebUI: Smart Battery Bias slider (under Aggressive Camera Tweaks)

Exposed smart_battery_bias as a slider in the WebUI config list, placed right under the Aggressive Camera Tweaks card as requested. Range 0-300 in steps of 50; the live value shows next to the handle ("Off" at 0) and only commits to governor.conf on release, so dragging doesn't spam config writes. Added a new "range" control type to the renderer (previously only bool and segmented controls existed), with matching slider styling and an EN/RU short description: "Nudges Smart mode toward battery saving (0 = off, higher = more economy, slightly less snappy). Only affects Smart." Default stays 0 (off) — this is a dial for users who want to push Smart further toward autonomy beyond the automatic short screen-off tier, not an on-by-default change. The value flows straight to the governor's smart_battery_bias config field (already parsed), applied with confidence scaling and clamped to 0-300. Reboot to apply, as the governor reads config at startup.

330 tests pass, lint clean, governor compiles, WebUI HTML/JS balanced, governor.conf/shipped in parity.

### Smart autonomy: short screen-off tier + optional bias knob + headroom fix

Three changes driven by the latest OP15 smart_daily capture.

1. Short screen-off economy (the real win). The log showed Smart sitting at its low learned daytime alpha (~400, even ~390 median with the screen OFF) for 90% of the session, because the only screen-off battery floor kicked in at 120s — so every brief glance-and-put-down window left easy economy on the table at zero UX cost. Added an intermediate tier: 30-120s screen-off now applies a gentle lean (alpha floor 600, modest sleep bias, interactive bonus capped at 90) — enough to back the GPU/big cores off without slamming to the 700 floor of the sustained-off tier, so a quick re-wake stays snappy. Under 30s still does nothing (instant glances), 120-1800s still floors at 700, 1800s+ still at 850.

2. smart_battery_bias knob (governor.conf, x1000, default 0 = unchanged). An optional autonomy dial that nudges the effective Smart alpha upward, scaled by confidence and clamped to a sane 0-300 so it shifts the lean without flipping Smart fully to battery or dragging a cold-start Smart battery-ward. Kept OFF by default because the data showed active screen-on use was already appropriately responsive (~385) — the screen-off tier is the targeted fix; this knob is there for users who want to lean further.

3. Headroom / "Запас" no longer stuck on n/a. On SM8850 the msm_performance interface reports a stuck-100% (or implausible-hot) signal early in a boot, which correctly latches headroom as a dead interface. But the latch never recovered, so even once the kernel started reporting a real capped value (e.g. 2227200 = 61%) the WebUI showed n/a for the rest of the boot. Added a recovery path: 5 consecutive plausible, non-100% reads clear the latch and headroom goes valid again (single good reads don't, to avoid flapping). This is what the WebUI "Запас" cell reads, so it now populates on OP15 instead of permanently showing n/a.

329->330 tests pass (added the new tier assertion), lint clean, governor compiles, governor.conf/shipped in parity.

### Battery/Smart: network_stats_poll_interval (gated on the LOG category)

Added the one genuinely safe idea from the DisableServers battery module: stretching network_stats_poll_interval (how often the framework polls per-app network stats) from the stock cadence to 2h (7200000) to trim those wakeups. Data-usage figures just refresh less often — no functional loss. Scoped tightly per your spec:

- Only when the user enabled the LOG category at install (asb_feature_enabled LOG). It's a telemetry/logging-reduction tweak, so it belongs to LOG — if LOG is off, this never touches the setting.
- Only in an EFFECTIVE battery state: the battery profile, OR Smart mode when its blend is strongly battery-leaning (smart_alpha_battery >= 800/1000 — the same >=80% threshold the governor uses to treat Smart as battery). Outside that it restores the AOSP default (1800000), so it's fully reversible, and asb_settings_put records the user's original value in the restore manifest for uninstall.

apply_network_stats_poll runs at boot and on every profile change (so the battery profile is covered immediately). For Smart, the reconcile loop watches smart_alpha_battery and re-applies only when it crosses the 800 boundary (reason "smart-eff-batt"), not on every tick — so a drifting Smart lean flips the interval at the transition without write churn. Validated across all combinations (battery/smart-high/smart-low/LOG-off/performance); 329 tests pass, lint clean.

### Pre-release audit: version sync + shipped-config parity

Full pre-release audit of the archive. Two real issues found and fixed:
- Version mismatch: the C governor still defined ASB_VERSION "V50" while module.prop, the WebUI badges, and the changelog were all V52. The governor logged and fingerprinted itself as V50. Bumped to V52. (The env fingerprint is ASB_VERSION|kernel, so this correctly triggers a one-time quarantine/relearn of stale Smart data on first boot after the update — the intended behaviour on a version bump.)
- Shipped-config parity: config/governor.conf.shipped was missing CAMERA_AGGRESSIVE=0 and CAMERA_AGGRESSIVE_INJECT=safe, which config/governor.conf has. Since the shipped file is what a fresh install copies in, new users would have started without those keys. Added them so a clean install and an upgrade end up with the same key set.

Everything else checked out: all on-device scripts parse as POSIX sh; ASB:*:BEGIN/END markers are balanced and paired (service.sh 9/9, system.prop 16/16); no duplicate keys in governor.conf; the generated FSM bounds header is up-to-date with profile_bounds.conf; every profile has its required keys; both GitHub workflows are valid YAML on NDK r28c and the release packaging uses rsync -a while excluding build/dev artifacts; no TODO/FIXME/debug flags/hardcoded paths; all rm -rf are scoped; uninstall wipes cleanly; the smart_trace header and data row both have 27 columns; the WebUI HTML/JS is balanced; and the C compiles clean apart from a couple of benign unused-parameter and a bounded-snprintf truncation warning (no overflow risk). 329 tests pass, lint clean.

### OP12 camera fix scoped to APatch only (KSU OP12 keeps the tweak engine)

Refined the previous OP12 camera fix so it applies to OP12 + APatch only, not every OP12. The multicamera HAL crash is APatch-specific: APatch's /odm is a real separate mount, so churning the camera conf disturbs a mount the HAL reads; on OP12 + KernelSU /odm is a symlink to /vendor/odm and the camera tolerates the tweak engine. So KSU OP12 now keeps the full reversible camera/audio tweak path like OP13/OP15, and only OP12 + APatch keeps the camera byte-for-byte stock.

Added a reliable install-time root-manager detector (asb_detect_manager) that sets ASB_IS_APATCH from the manager-exported env (APATCH / KSU) with on-disk control dirs (/data/adb/ap, /data/adb/apd vs /data/adb/ksud) as the fallback — far more reliable than getprop in the install/recovery environment. The install-time camera-tweak block is now gated on ASB_IS_OP12 && ASB_IS_APATCH. The runtime engine (asb_apply_dynamic_tweaks) does the same: it computes _skip_cam = OP12 && APatch (env or fs markers) and skips only the camera section on that combination, while still running the audio layer and still working normally everywhere else. Net effect by combination: OP12+APatch camera stock (fix); OP12+KSU full tweaks; OP13/OP15 full tweaks.

### OP12 APatch camera (root cause): no tweak engine on OP12 at install OR boot

You confirmed the OP12 APatch camera failed even with the camera tweaks OFF, which ruled out the aggressive layers and pointed at the engine itself touching the camera path. Diffing the full install against the known-good module (which has NO tweak engine at all) isolated it: inside asb_apply_device_overlay, v11work ran the tweak engine AT INSTALL — asb_tw_save_base on the camera conf plus asb_apply_dynamic_tweaks "$MODPATH" — unconditionally, regardless of CAMERA_AGGRESSIVE. The working module does neither (0 such calls). On OP12 APatch that install-time churn of the camera path is enough to break the multicamera HAL even with tweaks off. The runtime engine's OP12 guard didn't save it because (a) it ran at install where its getprop platform check is unreliable, and (b) the baseline-save ran before that guard.

Two fixes so OP12 is byte-for-byte stock on the camera, exactly like the working module, while OP13/OP15 keep the full reversible tweak path:
- install.sh: the install-time camera-tweak block (baseline save + asb_apply_dynamic_tweaks) is now gated on the reliable install-time ASB_IS_OP12 flag and skipped entirely on OP12.
- asb_tweaks.sh: asb_apply_dynamic_tweaks now early-exits on OP12 (pineapple/SM8650) at the very TOP of the function, before the audio loop too — so at boot the engine touches nothing on OP12 (not camera, not mixer), matching the working module which has no engine.

Verified by simulating the full OP12 install for both builds: the resulting camera dir is identical (config/ + media_profiles.xml, no conf_tuning_params.json — the OP15 one is wiped and OP12 ships none, so the device's stock camera conf is used untouched). Combined with the earlier removal of the post-fs-data partition-fold loop, v11work's OP12 install + boot behaviour now matches the known-good module on every camera-relevant path.

### OP12 APatch camera — removed the post-fs-data partition-fold loop (the actual cause)

Direct diff against the known-good module (camera works on OP12 APatch) finally isolated the remaining difference. The source trees, the op12_overlay bytes, and the install-time _odm_dups single-path (camera -> system/vendor/odm ONLY) all already matched the working build. The one thing left in post-fs-data that the working build does NOT have was a "fold any top-level partition dir (vendor/odm/product/...) back into system/" loop. It iterated the odm partition at every boot; on APatch that participates in stacking a separate mount over the real /odm, which SIGABRTs the OP12 multicamera HAL (ChiMcxRoiTranslator) — exactly the regression we'd been chasing. KernelSU tolerated it (its /odm is a symlink to /vendor/odm), so only APatch broke.

Removed that loop entirely. post-fs-data now differs from the proven working module by exactly one thing: the opt-in aggressive-tweak engine call (asb_apply_dynamic_tweaks), which is itself guarded to return early on OP12 (pineapple/SM8650) and so never touches the camera. So OP12 APatch gets the working module's exact camera behaviour, while OP13/OP15 keep the full tweak set (audio/camera aggressive layers, GPU pwrlevel capping, etc.). The install-time upgrade scrub that removes any stale system/odm/etc/camera mirror from a previously-regressed install is kept, so users coming from a broken build are cleaned up on reinstall.

### Logkit: wake-source attribution + honest standby-drain caveat

Analysing the three daily captures (OP15/OP13/OP12) surfaced a measurement caveat worth fixing in the tool itself. The smart_daily capture holds a partial wakelock so Doze can't freeze the script — which means the device never enters true deep sleep during the run, so the screen-OFF mA figure is an UPPER BOUND, not real standby. The drain summary now states this explicitly, and a periodic wake_sources.txt snapshot (top kernel wakeup_sources every snapshot interval) was added so a high standby reading can be attributed to an actual holder (modem, Wi-Fi, an app) instead of guessed. This is the difference between "OP15 idles at 100mA" (misleading — partly the logger) and seeing which subsystem is actually awake.

From the captures, for reference (screen-OFF mA is upper-bounded as above): OP13 and OP12 are healthy (session quality 97/92 avg, failure=none, low real drain). OP15 shows quality 75 avg with primary_failure=heat and a poor energy-budget accuracy (21/100) — consistent with the SM8850's known aggressive thermal throttling making drain spiky and hard to predict, not an ASB regression. No profile or governor values were changed off this data: the screen-OFF numbers are contaminated by the logger's own wakelock, so tuning against them would be chasing a measurement artifact. The new wake_sources.txt in the next capture is what will let us tune against real standby.

### Logkit: save to /sdcard (not Termux) + richer autonomy capture

Two changes to the smart/daily/gaming/sleep log collectors:

1. Output location. The capture folder was created under $TMPDIR, which under Termux is Termux's private dir — invisible from a file manager and awkward to retrieve. A new lk_resolve_outbase helper now picks the storage root the same way asb_diag does (/sdcard, then /storage/emulated/0, then /data/local/tmp as a fallback), so the folder lands next to asb_diag_report.txt. All 7 logkit scripts updated; the progress-check and retrieval comments were corrected to /sdcard. The final zip already went to /sdcard, so now the working folder and the archive sit together.

2. More informative for battery analysis. The Smart trace (used by daily, gaming, and sleep) now records four autonomy fields per poll: draw_mA (battery current magnitude — the key drain signal, pair it with the charging column for direction), gpu_busy_pct, and the live little/prime cluster frequencies in MHz (so you can see whether cores actually idle down). The end-of-run _smart_summary gains a Battery-drain section: average mA overall, split by screen ON/OFF (standby drain) and by profile, plus an off-screen red-flag check (GPU busy and little-cluster freq that should be near-idle when the screen is off). This turns the daily log into something you can actually read autonomy off of, rather than just Smart-state telemetry.

### Diag: GPU write-test (to settle whether the GPU cap actually sticks)

The OP13 reports show GPU devfreq max_freq at the hardware max (1100MHz) on all three profiles, which raised the question of whether ASB's GPU cap works there. cur_freq was 222MHz (GPU idle), so there's no active drain, but the ceiling not moving needed explaining. asbdiag now runs a GPU write-test mirroring the CPU one: it writes a mid available freq to devfreq/max_freq (or, on pwrlevel devices like OP15, bumps max_pwrlevel), reads it back, and restores. The next report will show [PASS] (ASB controls the GPU ceiling) or [FAIL] (the vendor msm-adreno-tz governor overrides it, the same cooperative-override pattern walt has with CPU scaling_max). This turns an open question into a measured fact instead of a guess.

No profile changes: the OP13 CPU caps are monotonic (battery prime 39% < balanced 56% < performance 71%), and the battery min==max==cur seen in the snapshot is the walt governor running the core under momentary load, not ASB pinning the floor (ASB writes CPU_MIN_LITTLE=307200, a low idle floor — confirmed in apply_screen_aware_caps).

### OP15 GPU caps were a silent no-op — fixed with a safe pwrlevel fallback

The OP15 SMART log exposed a real bug. OP15's Adreno 840 leaves the devfreq frequency nodes (devfreq/max_freq, available_frequencies) EMPTY and controls the GPU through max_pwrlevel instead. apply_gpu_caps only ever wrote devfreq/max_freq, so on OP15 the per-profile GPU percentages (battery 50%, balanced 85%) were applied to an empty node and did nothing — the GPU was never capped for battery there. (OP13's Adreno 830 populates devfreq, so it was always fine.)

apply_gpu_caps now falls back to pwrlevel capping when devfreq is empty. pwrlevel is an inverted index (0 = fastest), so GPU_MAX_PCT maps onto it: 100% -> fastest, lower % -> a slower level. Crucially it is SAFE: the vendor sets max_pwrlevel as a thermal ceiling (6 on OP15), and we capture that value once at first boot as a FLOOR and never write below it — so performance/balanced leave the vendor ceiling untouched (no overclock on a throttle-prone SoC) while battery is allowed to slow the GPU for real savings. service.sh remains the single owner of GPU caps; profile_core writes neither devfreq nor pwrlevel.

asbdiag now reports the GPU as pwrlevel-controlled (with the captured vendor floor) instead of printing "GPU: n/a" on these devices.

Also confirmed from the logs: both devices healthy (all PASS, write-test PASS, RAM expansion=0, temps ~44C no throttling), and the live audio SKU on the OP15 unit is alor (not canoe) — so the alor tweak_base baselines kept earlier are the active ones, not junk.

### Comment cleanup (service.sh, system.prop, src/, runtime/)

Trimmed verbose and redundant comments while preserving everything functional. Removed history narratives ("the previous version hardcoded X / real deploy data showed 9030 reads"), a duplicated OOM note, and over-long WiFi/cpufreq/tweak-engine headers — condensing each to the rationale that actually helps a maintainer. Deliberately kept: the ASB:*:BEGIN/END block markers (install.sh parses these with sed to add/remove category blocks — removing them would break the toggle logic), algorithm documentation (anti-thrash clamp thresholds, storm-shield day/night split, Smart learning triggers), the smart_dynamic_tune argument contract, and the non-obvious bug warnings (e.g. apply_cpufreq_caps call ordering). The codebase was already fairly disciplined, so this is a focused trim of war-story prose rather than a mass deletion. All markers verified intact (system.prop 16/16, service.sh 9/9), governor compiles, 329 tests pass.

### Audit of /data/adb/asb + orphan-baseline prune

Reviewed everything the module writes to /data/adb/asb. Nothing is junk: state files (active_profile, smart_mode_enabled, buckets.bin, learn data) drive the profiles and Smart learning; session_history.jsonl is the largest file but is bounded (rotates at 500 lines with a hard byte cap); the small .log files don't grow unbounded; stale_props_cleaned is a 0-byte run-once marker; and uninstall.sh already wipes the whole directory.

The tweak_base/ directory (the .asbbase files that prompted the question) holds clean baselines of the audio mixer and camera-tuning files, captured before the aggressive layer is applied. They're required for the AUDIO_AGGRESSIVE / CAMERA_AGGRESSIVE toggles to be reversible with just a reboot (no reinstall), and they live outside the module's system/ tree on purpose so they don't leak into the live /vendor partition. On OP15 you see both canoe and alor SKU baselines because the OP15 package legitimately ships both SKUs — they aren't removable junk.

Added a safety net: asb_save_dynamic_baselines now prunes orphaned baselines on (re)install — any .asbbase whose source file is no longer shipped by the current build is removed, so tweak_base can't accumulate stale files across reinstalls or device/SKU changes. Active baselines are always preserved (only files absent from the freshly-built set are removed).

### WebUI: shortened config descriptions

Trimmed all 29 config-toggle descriptions (14 EN + 15 RU) to one concise, informative line each. Removed verbose background and repeated caveats while keeping what each toggle does, the safe default, and any reboot/conflict note. Descriptions went from 239-778 chars down to 80-205. No functional change — names, keys, defaults, and the underlying behaviour are untouched.

### RAM expansion: confirmed ASB never force-enables it + fixed the toggle that never loaded

Answering the direct question: after a reboot with the toggle OFF, ASB does NOT force RAM expansion on. Two independent reasons: every profile sets UX_RAM_EXPAND=0 (i.e. the only value ASB would ever write is "off", never "on"), and that write is gated behind UX_MANAGE_OEM_TOGGLES.

While verifying this I found that gate was reading a value that was never actually loaded: the UX_MANAGE_* flags live in governor.conf, but nothing sourced governor.conf into the environment that asb_apply_ux runs in (the per-profile files define UX_RAM_EXPAND etc. but not the UX_MANAGE_* switches). So the gate always saw the default 0 — meaning ASB never wrote ram_expand_size at all, AND a user enabling "Manage OEM Toggles" in the WebUI had no effect. asb_apply_ux now reads UX_MANAGE_ANIM_SCALE / UX_MANAGE_TIMEOUTS / UX_MANAGE_OEM_TOGGLES / UX_ANIM_FORCE_RESTART point-wise from governor.conf at apply time. Net effect:
- Toggle OFF (default, and the first-boot shipped value): ASB never touches RAM expansion — neither on nor off. Safe.
- Toggle ON: ASB now actually enforces UX_RAM_EXPAND=0 on every boot, so a user who wants RAM expansion to stay disabled finally can make it stick.
In no case does ASB enable RAM expansion. This also makes the animation-scale and touch-timeout managers honour their WebUI switches (previously they were effectively always in restore/off mode).

### Diag: fixed false OP13 camera FAIL (device-aware tone values)

The only FAIL on the OP13/OP15 reports was cosmetic: asbdiag checked aggressive sunsetSatScale against the OP15 value (1.4) on every device, but OP13 intentionally runs a softer 1.3 (and blueSatParam 1.02 vs 1.05) to avoid low-light banding. The device had the correct 1.3; the check was wrong. The verification now picks the expected value from the live SoC, so OP13 no longer false-FAILs. With this, OP15 and OP13 reports are clean across all profiles.

### Confirmed from the OP15 daily logs: caps and RAM behaving correctly

The 6-hour OP15 smart-daily capture settles the open questions with real data:
- Caps: the governor's own telemetry shows cap_owner=vendor with vendor_clamp_1h=56 and cap_source=vendor_raised/vendor_clamp. ASB writes the cap; the OEM thermal governor then clamps it under load. The vendor_overrides log shows max_overridden=0 (ASB's MAX caps stick) and only min_overridden=1 (vendor nudges the floor). So the varying scaling_max in snapshots is the OEM governor cooperating with ASB, not an ASB failure — and ASB's detente logic (cap_detente_skipped=18) deliberately avoids a write-war. Report card: session quality last=97/avg=73, budget accuracy 90/100, anomalies=0.
- RAM: ram_expand_size=0 throughout on OP15 (RAM expansion correctly OFF). The per-profile "available" swings are working-set drift, confirmed earlier by OP15 showing the EXPECTED battery<=balanced<=performance app(anon) ordering.

No code changes were needed for either — the data shows them working as designed.

### OP12 CAMERA — FINALLY FIXED: my system/odm mirror was the regression

Direct comparison of the known-good build (20000, camera works on OP12 APatch AND KernelSU) against the regressed build (3590, breaks APatch) gave the definitive answer. The working module writes the camera/media overlay to system/vendor/odm ONLY — a plain cp, no system/odm mirror, no post-fs-data bind-mount. My "dual-path" change (mirror camera into system/odm + bind-sync /odm at boot), added to chase a supposed /odm desync, was ITSELF the regression: on APatch, shipping system/odm/etc/camera makes the manager stack a separate mount over the real /odm partition, which crashes the multicamera HAL (ChiMcxRoiTranslator SIGABRT). KernelSU tolerated it because its /odm is a symlink to /vendor/odm, so only APatch broke — exactly the symptom reported.

Reverted to the working module's approach precisely:
- _odm_dups now emits system/vendor/odm ONLY for camera/media (no system/odm).
- Removed the post-fs-data /odm bind-sync entirely.
- prune now strips any system/odm/etc/camera, and the upgrade-path cleanup scrubs the mirror left by the regressed build from the previous install dir (and modules_update), so users coming from 3590 are fixed on reinstall without a stale /odm mount lingering.
- op12_overlay remains byte-identical to the working module.

This matches the build that is confirmed working on OP12 under both APatch and KernelSU.

### Cross-device review (OP12/OP13/OP15 diag logs, build 3590)

Verified against the supplied reports: write-test PASS on OP13 and OP15 (ASB controls caps); OP12 KSU shows camera /odm and /vendor/odm in agreement. The varying scaling_max percentages across profiles in the snapshots are the live walt/uag governor moving the ceiling under momentary load (cur stays low), not cap failures — the diag already reports these as informational rather than FAIL. profile_bounds remain monotonic (battery <= balanced <= performance) for CPU and GPU, single-owner cap ownership intact, 329 tests pass.

### RAM usage + RAM-expansion toggle: diagnosed, no placebo changes

Two OP13 reports plus the OP15 set (same build) let us settle both memory questions with data:

- "Battery uses more RAM than performance": the new /proc/meminfo breakdown shows OP13 battery app(anon)=2317MB vs balanced 1528MB — but on OP15 (same build) the order is the EXPECTED battery=3820 < balanced=3951 < performance=3989 < smart=4413, i.e. battery is the LOWEST. If the battery profile genuinely held more memory it would show on OP15 too; it doesn't. So the OP13 figure is working-set drift between snapshots taken 8 minutes apart (different apps open), not a profile defect. No VM tuning was changed to "fix" a non-issue.

- "Without module 5.98 GB, with module 7.22 GB" + "RAM expansion re-enables after reboot": these are linked. ASB only writes ram_expand_size in ONE gated place (UX_MANAGE_OEM_TOGGLES=1); with that toggle OFF, ASB never touches RAM expansion, so OxygenOS re-enables it on boot and the larger zram allocation inflates "used" memory. The fix for the user is to turn ON "Manage OEM Toggles" — every profile sets UX_RAM_EXPAND=0, so ASB then forces RAM expansion OFF on every boot and it stays off. The toggle's RU/EN descriptions were misleading (claimed OFF makes the Settings choice "stick", which it doesn't) and now explain this clearly. asbdiag also prints the live ram_expand_size / adaptive_battery / low_heat values so we can confirm the off-value format on-device.

### Diagnostics: full /proc/meminfo breakdown (settle the battery-vs-performance RAM question)

The OP13 reports show battery holding more "used" RAM than performance, which is counter-intuitive. The headline "available" number is misleading because it swings with whatever apps happen to be open at snapshot time, and the three reports were taken minutes apart in one session. To answer it properly, asbdiag's memory section now prints the full breakdown: MemFree, Cached, Buffers, SwapCached, Active/Inactive split into (anon) and (file), SReclaimable, SUnreclaim, KReclaimable, Shmem, Mapped. It also derives two apples-to-apples figures — total reclaimable cache vs committed app(anon) memory — and notes that profiles should be compared on app(anon), not on "available". This will show whether battery's higher "used" is just reclaimable file cache (harmless, handed back under pressure — likely, given battery runs vfs_cache_pressure=120 vs performance's 30) or genuinely more live app memory.

### Full cross-directory revision (common/src/runtime/config/profiles/overlays/post-fs-data/service/system.prop/apply_profile)

Systematic audit of every directory. Result: no critical bugs or conflicts remain. Verified:
- All shell scripts parse cleanly (build_ndk_release.sh is bash-only by design, fine).
- profile_bounds.conf is monotonic on every metric (battery <= balanced <= performance) for CPU MAX/CAP and GPU, with MIN < CAP < MAX inside each profile; generated .sh/.h are in sync.
- The three profiles expose an identical 76-variable set (no drift), swappiness is monotonic 80/35/12.
- src/ compiles with no errors and brace-balances to zero in every .c/.h.
- Single-owner cap ownership is intact: profile_core writes zero CPU caps and zero GPU frequencies, service.sh owns scaling_max, and the governor manual-gate is present.
- op12_overlay is byte-identical to the proven-working module; op13 camera JSON/XML are valid; system.prop has balanced ASB blocks (16/16) and no duplicate keys.
- OP12 camera dual-path (system/vendor/odm + system/odm) is correctly emitted so /odm and /vendor/odm stay in sync; the post-fs-data bind-sync is a correct no-op-on-KSU fallback (tidied a stale comment that still referenced the old camera-off theory).
- No dangerous rm, no open TODO/FIXME markers, watchdog/reconcile loops all sleep, uninstall restores the baseline. The 5 lint warnings are RESERVED feature placeholders, not defects.

### OP12 CAMERA FIXED: /odm desync was the APatch-only cause (proven)

The 1190 diag reports cracked it. On KernelSU Next (camera works) the OP12 report shows /odm=58506 AND /vendor/odm=58506 — they AGREE (diag: "no desync"). The earlier APatch termux dump showed /odm=58480 (stock) vs /vendor/odm=58506 (ours) — they DISAGREE. The OP12 multicamera HAL reads the real /odm partition, so when only /vendor/odm is patched (APatch) the two configs conflict and ChiMcxRoiTranslator SIGABRTs during configure_streams. KernelSU mounts the overlay into both paths, so it never desyncs.

The old code shipped the OP12 camera overlay to system/vendor/odm ONLY (based on a since-disproven theory that camera-on-/odm caused the crash). That was itself the APatch breakage. Fix: OP12 now gets the SAME dual-path write as OP13 — the camera overlay is mirrored into both system/vendor/odm and system/odm, so the manager patches /odm too and the two always agree. The prune step no longer strips system/odm/etc/camera (that would re-create the desync). As belt-and-braces, post-fs-data.sh also bind-mounts the module's camera files onto /odm on OP12 when it detects a mismatch (no-op on KernelSU where they already agree). OP13/OP15 are unaffected.

### Diagnostics: stop false performance/battery FAILs from the live governor

scaling_max_freq is managed live by the OEM scaling governor (walt/uag), which lowers it under light load even when ASB applies no cap. The diag's "performance prime >=90%" check was reading that momentary value and reporting a false FAIL (seen on both OP15 and OP12 at 58-79%). Performance now reports the live % as info (ASB applies no cap there), and battery's cap check is a soft NOTE that points at the write-test rather than a hard FAIL. The write-test itself (added last build) confirmed PASS on both OP12 and OP15 — ASB genuinely controls the caps; the confusing numbers were just the governor moving scaling_max around.

### Fixed: OP15 performance prime cluster pinned at 1.63 GHz (vendor clamp)

OP15 diag in the performance profile showed the prime cluster frozen at `min=max=cur=1632000` (35 % of its 4.6 GHz) while balanced sat healthily at `cur=max=2438400`. The shell writes the full ceiling once, but OnePlus PowerHAL re-clamps the prime cluster straight back down, and because the governor was told to skip all CPU-cap writes in every manual profile (`manual_cap_skip`), nothing re-asserted the ceiling — so performance ended up LOWER than balanced. The governor now keeps defending the cap in the performance profile (a new `fsm_profile_is_performance` flag carves performance out of `manual_cap_skip`), so its anti-clamp logic re-raises the prime ceiling against vendor clawback. Battery and balanced stay shell-owned as before; smart stays governor-owned. With the per-device bounds scaling from the previous build, performance now resolves to ~83 % at idle rising to the full 100 % ceiling under load on OP15, instead of being pinned at 35 %.

### Fixed: smart-mode / thermal caps were absolute kHz — froze OP13/OP15 in low states

The FSM cap bounds (`asb_fsm_bounds.generated.h`) are absolute kHz authored against the SM8650 (OP12) reference — e.g. the battery FLOOR of 921600. On OP13 (prime ~4.32 GHz) and OP15 (prime 4.6 GHz) that floor is only ~21 % of the cluster, so whenever smart mode or the thermal safety-net pulled toward the floor the phone froze. The governor now records each cluster's real `cpuinfo_max_freq` at topology discovery and scales every bound by `real_hwmax / reference_hwmax` per slot (`asb_bounds_scale`), clamped to the cluster ceiling and a sane 300 MHz floor. So the same bounds table now tracks each device's real silicon: OP13's battery floor/ceil become ~1.21/2.89 GHz instead of 0.92/2.21, OP15 scales up similarly, and OP12 (the reference) is unchanged. Manual battery/balanced/performance still use the shell percentage caps (governor skips them there); this fix matters in smart mode and during thermal events on the higher-clocked SoCs.

### OP13 battery screen-on caps raised (50/44 -> 58/48 %)

Users still reported UI jank in the battery profile on OP13. The screen-on caps were nudged up so the little/prime clusters keep more interactive headroom while still saving power versus balanced/performance.

### Kept: 1188's profile/CPU/GPU/VM improvements and OP12 camera payload

The performance profile (now genuinely full-power), the softened battery VM/WALT tuning, the GPU single-owner cleanup, and the smart-mode swappiness fix are all retained. The OP12 camera overlay (`video_beauty_default_config`) is intentionally byte-identical to the proven-working OP12/APatch module — including its lenient `//` comment and the `exteragram` activity name, which that module ships and the camera HAL accepts. This is not a regression: aligning OP12's payload with the known-good module is the correct, tested state, and the fold-exclusion plus OP12-aware overlay safety remain in place.

### Section revision: fixed profile-shape inversions and a second dual-owner (GPU)

Audited common/src/profiles/config/runtime plus service.sh and post-fs-data.sh. Real bugs found and fixed:

- PERFORMANCE bounds were LOWER than BALANCED (a profile-shape inversion). In config/profile_bounds.conf the performance ceiling was CPU prime 3302400 vs balanced 3974400, and GPU 50% vs balanced 85% — so "performance" capped the hardware below "balanced". Raised performance to CPU little/prime 3724800/4704000 (above the fastest SoC, effectively uncapped) and GPU 100%, restoring battery <= balanced <= performance. The same inverted fallbacks in profiles/performance.sh (2956800/3302400/GPU 50) were corrected too, and the generated bounds (.sh/.h) regenerated.
- GPU had the same dual-owner conflict CPU had: both profile_core.asb_apply_gpu (absolute) and service.sh apply_gpu_caps (per-device percent) wrote devfreq max_freq/min_freq, racing on the same node. profile_core no longer writes GPU frequencies (service.sh apply_gpu_caps is the sole owner); the non-frequency GPU tunables stay in profile_core.
- smart_dynamic_tune.sh capped swappiness at 90 instead of 100 for its default bucket, matching the battery-jank fix (maxed swappiness stutters on zram even with free RAM).

Noted but left as-is (safe): WALT/VM/NET have profile_core + service.sh appliers that write the same nodes, but both read the same loaded-profile values so they produce identical results — redundant, not conflicting. Ripping them out risks subtle ordering regressions for no behavioral gain.

### OP12 camera: overlay now byte-identical to the working module + desync diagnostics

The termux dump showed /odm/etc/camera/media_profiles.xml = 58480 (stock, root:root) but /vendor/odm/etc/camera/media_profiles.xml = 58506 (ours, root:shell) — the two camera partitions DISAGREE, and the OP12 multicamera HAL reads /odm directly. Made the OP12 overlay byte-identical to the known-good debug module (synced video_beauty_default_config, the last differing file). Rewrote asbdiag section 6b to (a) compare /odm vs /vendor/odm media_profiles sizes and flag a desync — the prime crash suspect — and (b) report the file owner so we can see whether the module wrote /vendor/odm directly. The old 6b still assumed the abandoned "camera-off" approach and would have misreported; it now reflects the working-module-match approach.

### WebUI: moved "Manage OEM Toggles" under "Background Trim Level"

Reordered the config render array so "Manage OEM Toggles (RAM/Battery/Heat)" now sits directly beneath "Background Trim Level", grouping the memory/system-toggle controls together.

### Settings preservation across reflash (verified + hardened)

Confirmed all WebUI settings survive a module reflash: asb_preserve_user_config carries every user-settable governor.conf key (including UX_MANAGE_OEM_TOGGLES and the rest) from the previous install onto the freshly-shipped config, and the selected profile persists in /data/adb/asb/active_profile (a data-dir path the manager doesn't wipe). Hardened the preserve step to also read the previous config from modules_update as a fallback, since some KSU/APatch flows stage the old install there.

### install.sh: removed verbose installer prints

Dropped the chatty installer ui_print lines (post-reboot diagnostics instructions, "Preserved N WebUI settings", "V4A stripped", "Stripped // comment", "OP15 aggressive wired"). The underlying logic (comment stripping, V4A removal, config preservation) is unchanged — only the console spam was removed.

### Battery-mode UI freezes: fixed the real cause (VM thrash + low responsiveness)

The OP13 battery report exposed the likely true cause of the jank — and it wasn't the CPU caps (which were actually fairly high). Two battery-profile settings were punishing interactivity:
- VM was thrashing: vm.swappiness=100 (max) and vm.vfs_cache_pressure=400 made the device swap to zram and drop file caches even with ~9 GB RAM free, which on zram adds compress/decompress stalls = visible stutter. Also dirty_expire/writeback=240000 (4 min) caused big writeback bursts, and page_cluster=3 added swap-in latency. Retuned to swappiness=80, vfs_cache_pressure=120, dirty_expire/writeback=60000/30000, page_cluster=0 (1 page per swap-in, lowest latency). Still battery-friendly, no longer thrashing.
- Scheduler responsiveness was too low: WALT_TOPAPP_WEIGHT=40 (vs 110 balanced) and WALT_BOOST_MIN_UTIL=200 (vs 48) meant the foreground app got little scheduler priority and cores wouldn't ramp until very high load, so the UI lagged. Raised to TOPAPP_WEIGHT=80, BOOST_MIN_UTIL=90, ED_BOOST=5 — between the old battery and balanced, so it stays economical but the UI stays responsive.

### Diagnostic instrumentation for the cap mystery (unchanged numbers)

Separately, the live CPU caps on OP13 match neither ASB's per-device percentages nor the governor bounds (e.g. prime pinned at 1689600, a value absent from the cluster's available table). The shell cap math is provably correct and the governor's manual gate is in place, so something outside ASB is setting them or ASB's writes aren't sticking. Added a scaling_max writability flag and a live write-test (write a known freq, read back, restore) plus governor_persist.log tail and smart_mode flag so the next report shows definitively who controls the caps. No cap numbers were changed blindly.

### Diagnostics: prove who actually controls the CPU caps (OP13 battery jank)

The OP13 battery reports show caps that match NEITHER ASB's per-device percentages NOR the governor bounds: little=2400000 (67%), prime=3283200 (76%), and balanced/performance prime both pinned at 1689600 — a value that isn't even in the cluster's available-frequency table or any ASB bound. The shell cap logic is provably correct (simulated on OP13's real frequency tables, battery L50/B44 yields 1555200/1747200), and the governor's manual-profile gate is in place, so the live values are coming from something else (OEM/kernel override, or ASB's writes not sticking). Added decisive instrumentation to asbdiag so the next report pinpoints it:
- Per-cluster scaling_max writability flag.
- A live write-test on policy0: writes a known available freq, reads it back, restores the original — PASS means ASB can control caps, FAIL means the OEM/kernel overrides them.
- governor_persist.log tail, smart_mode_enabled flag, smart_prev_profile, and the last screen_aware_caps decision, so we can see what the shell intended vs what stuck.

No blind cap-number changes were made this round — tuning numbers before knowing whether the writes even apply would be guesswork.

### Fixed: ASB kept re-asserting OxygenOS RAM expansion (and adaptive battery / low-heat)

Every profile apply wrote `ram_expand_size`, `adaptive_battery_management_enabled` and `sem_low_heat_mode` to global settings unconditionally. These are OEM-owned toggles that OxygenOS re-asserts at boot, so ASB and the OS fought each other — on OP13 the RAM-expansion toggle kept switching itself back on after a reboot, and the user saw used storage creep up (+1 GB) as the swap file was re-created. Unlike the animation/timeout writes, these three had no opt-in gate. They are now behind a new `UX_MANAGE_OEM_TOGGLES` switch (default OFF), so by default ASB never touches RAM expansion, adaptive battery, or low-heat mode and the user's own choices in Settings stick. The switch is exposed in the WebUI (RU + EN) for anyone who does want profiles to drive them.

### Fixed: profile cap conflict (dual source of truth) — percentages are now the only owner

The CPU caps were converted to per-device percentages, but several places still read the legacy absolute `CPU_CAP_*` / `CPU_MAX_*` values, creating a real conflict:
- `service.sh` called `apply_cpufreq_caps` standalone at service start, before the percentages were set, so it read the absolute kHz left in `_P_CPUCAP_*` by `asb_load_profile` and — being percentage-based now — misread e.g. 1190400 as ">=100%", briefly uncapping every cluster. That standalone call is removed; `apply_screen_aware_caps` (the single owner) runs at startup and on every profile/screen change.
- `asb_utils.sh` no longer seeds `_P_CPUCAP_*` / `_P_CPU_MAX*` from the absolute values (left empty; percentages come from `apply_screen_aware_caps`).
- `profile_core.sh`'s `asb_apply_cpu` dead per-cluster cap computation (absolute) was removed — it only applies schedutil tunables now.
- The `asb_reconcile.sh` cap-drift watchdog compared live freq against absolute `CPU_CAP_*` on a 2-cluster assumption, firing false re-applies and missing OP12's mid clusters — disabled (screen/profile transitions already re-apply correctly and topology-aware).
- The unused `asb_check_perfhal_drift` is now a no-op instead of logging spurious drift against stale absolutes.

Net: only `apply_screen_aware_caps` → `apply_cpufreq_caps` writes `scaling_max/min_freq`, using per-device percentages of each cluster's own max. The absolute numbers left in `profiles/*.sh` are vestigial (kept for reference/min-floor only) and no longer fight the percentage owner.

### Fixed: OP13 camera first-launch flash returned (per-boot /odm churn)

With aggressive camera on, the engine reverted the conf to baseline then re-applied the tone every boot — two writes to the `/odm` conf that the OP13 camera HAL reads early, re-introducing the brief "storage loading / camera unavailable" flash. The camera apply is now idempotent: it builds the desired conf in a temp from the baseline, applies the aggressive/inject layers there, and swaps it in (atomically, preserving SELinux context) ONLY if it differs from the live file. A normal reboot with unchanged toggles rewrites nothing.

### Fixed: animation scales stuck at 0.9 with the toggle off

If an earlier build forced a profile animation scale (0.8/0.9) without saving a baseline, a later build with `UX_MANAGE_ANIM_SCALE` off found no baseline to restore and left the scale stuck. The off-branch now also resets a known ASB-set value (0.8/0.9) back to stock 1.0 when there's no baseline, while never touching a value the user chose themselves.

### OP12 camera: REVERSED the prop diet (it was the regression)

Direct comparison with the known-good debug module (working camera on OP12/APatch) overturned the earlier diagnosis. That module FORCES the full camera prop set — 83 camera props in system.prop plus runtime resetprop of mfnr/eis/isSupportExplorer/isHasselblad/dual_camera_sat/sat.fallback.dist on EVERY device including pineapple — and the camera works. Our "camera prop diet" that deleted these props on OP12 was itself the cause: stripping them left the multicamera HAL in a partial/inconsistent state and it SIGABRTed in ChiMcxRoiTranslator during configure_streams.

Reverted to the proven approach: restored the full ASB:CAMERA block in system.prop (was trimmed to media/vidc props only) and removed the pineapple delete-branch from apply_camera_props_static so OP12 now applies the same full, consistent camera prop set as OP13/OP15 — exactly like the working module. No device gating, no deletion. These are the original ASB camera props that worked on all three devices before the diet was introduced.

### CPU caps ownership fully consolidated (min-freq + drift monitor)

Finished the single-owner refactor. Two more stray writers were folded in:
- Per-cluster scaling_min_freq is now written inside apply_cpufreq_caps (the 4-cluster-aware single owner), clamped so min never exceeds the cap. The old 2-cluster LITTLE/BIG min-freq writes (which ignored OP12's mid/prime clusters and ran outside the owner) were removed.
- asb_drift_check (called by the watchdog) was comparing live frequencies against hardcoded absolute kHz (1132800/1612800) and only policy0/policy6 — obsolete after the move to per-device percentages, so it logged false drift on OP12. It's now a genuine sanity monitor: it flags any cluster where scaling_min_freq > scaling_max_freq, and the obsolete absolute-cap comparison was dropped. It still only monitors (no writes).

Net result: scaling_max and scaling_min for manual profiles have exactly ONE writer (apply_cpufreq_caps), Smart is governor-owned, profile_core writes neither. This removes the last of the multi-owner races behind the contradictory diag caps.

### Profiles architecture: single owner for CPU caps + per-device tuning

Audit confirmed the real conflict: three layers wrote scaling_max/min at once (profile_core.sh asb_apply_cpu, service.sh apply_screen_aware_caps, and the C governor), so caps contradicted each other — diag showed performance prime stuck at 39-58% (should be ~100%), OP13 battery 32%/32% (jank), and OP12 battery prime 55% > balanced prime 41% (impossible shape). Fixes:

- SINGLE OWNER. profile_core.sh asb_apply_cpu no longer writes scaling_max/min (keeps only schedutil tunables). Manual profiles (battery/balanced/performance) are owned solely by service.sh; Smart is owned solely by the C governor.
- GOVERNOR GATE. writer_apply_caps now skips CPU cap writes in manual profiles unless a thermal cap is engaged (then it may only pull DOWN for safety). It never overrides the manual profile ceiling again — that's what pinned performance to 39-58%. Smart is unaffected.
- PER-DEVICE CAPS. apply_screen_aware_caps now detects the SoC (canoe/sun/pineapple) and uses per-device screen-on percentages with a monotone shape (battery <= balanced <= performance). OP13 battery lifted from 32/32 to 50/44; OP12 battery little 60 / prime 45 with the MID workhorse auto-lifted (~72%); OP15 left light. Performance is uncapped on every SoC.

### Animation scales now restore (fix for stuck 0.9)

asb_apply_ux saved no baseline, so once ASB set window/transition/animator scales to 0.9 they stuck there even after the "manage animation scale" toggle was turned off. It now snapshots the stock scales + touch timeouts once (config/ux_baseline.conf) and, when the toggle is OFF, restores them instead of leaving the override in place.

### OP13 camera aggressive softened (low-light banding)

The aggressive tone grade is now device-aware: OP13 (sun) gets a softer grade (blueSatParam 1.02, nightDownGain 0.35, dayDarkBoost 1.3) to stop the low-light saturation jumps the user reported; OP15 keeps the full grade.

### Diagnostics: normalized score

Summary now prints applicable=PASS+FAIL and pass_ratio=PASS/applicable so devices are comparable — raw PASS (OP13 31 vs OP15 28) just reflected more applicable checks on OP13, not better tuning.

### Per-device profiles: caps are now a percent of each cluster's own max

The profile CPU caps were absolute kHz values tuned for a generic ~3.3 GHz SoC. On OP15 (canoe, prime 4.6 GHz / perf 3.63 GHz) this pinned the prime cluster near 1.6 GHz even in performance, and on OP13 (sun) it under-drove the big cluster; only OP12 (~3.3 GHz) was roughly right. `apply_screen_aware_caps` and `apply_cpufreq_caps` now express every cap as a PERCENT of each cluster's own `cpuinfo_max_freq`, snapped to the nearest available step, so a single set of numbers fits all three SoCs:

- performance: no cap on any cluster (full hardware range everywhere).
- balanced: uncapped screen-on; screen-off trim to ~55%/45% little/big.
- battery: screen-on ~55% little / ~40% prime, with the mid workhorse cluster(s) lifted to ~77% on 4-cluster OP12 so the UI stays smooth; screen-off ~35%/25% for real savings.

Combined with the topology-aware MID tier, OP12's policy2/policy5 (the 2,3,4 / 5,6 mid cores) keep headroom in battery instead of being throttled to the single prime core's cap, and OP15/OP13's big clusters run at their proper speed in performance. Smart mode is unchanged — it is the dynamic in-binary governor that already reads live per-cluster frequencies, so it scales per-device on its own.

### Diag: clearer per-cluster cap reporting

The CPU section of `asb_diag.sh` now prints each cluster's tier (little / mid / prime), its scaling-max vs hardware-max, and the cap as a percent of hardware, plus a profile-aware sanity check (performance must read ~full speed on the prime cluster; battery must actually cap it). This makes it obvious at a glance whether a profile is driving each device's clusters correctly.

### Fixed: OP12 camera still crashing after 1170 — boot-time fold re-created the /odm mirror

1170 reverted the install-side OP12 camera regression, but the camera kept crashing on the APatch OP12. Root cause: `post-fs-data.sh` has a boot-time "fold" loop that copies any `vendor/odm/...` files left at the module root into `system/<part>/...`. For `odm` that meant a root `odm/etc/camera` (which the manager can materialise) was folded into `system/odm/etc/camera` on EVERY boot — re-creating exactly the OP15-shaped multicamera mirror on the real `/odm` partition that SIGABRTs `ChiMcxRoiTranslator::Initialize`. The proven-working module has no such fold. The fold now skips every `*/etc/camera/*` and `*/etc/media_profiles*.xml` path (those come only from the controlled install overlay, never a boot-time fold), and post-fs-data scrubs any `system/odm/etc/camera` / media_profiles a previous boot or build may have left. Camera/media is now placed exactly once, at install, into `system/vendor/odm` only on OP12 — matching the working module.

### Fixed: heavy battery-profile lag on OP12 (4-cluster) and OP13/OP15

The battery profile used a 2-tier LITTLE/BIG cap model. On OP12 (pineapple, a 4-cluster SoC: policy0 little + policy2 ×3 mid + policy5 ×2 perf + policy7 ×2 prime) every cluster above policy0 was treated as "BIG" and capped to the prime-cluster battery ceiling (~1.07 GHz screen-on), which throttled policy2 — the main UI/app workhorse — and made the phone lag badly, especially below ~25 %. `apply_cpufreq_caps` is now topology-aware: with 3+ clusters the middle cluster(s) get a MID tier capped roughly halfway to their own ceiling, so policy2 runs ~2.3 GHz in battery instead of ~1.07 GHz while the prime cluster stays capped for power. The screen-on battery caps were also raised (little 729600→1132800, big 1075200→1612800) so OP13/OP15 (2-cluster) stay smooth in battery too; the big screen-off savings are unchanged. 2-cluster devices keep their exact prior tier mapping (the MID tier only triggers at 3+ clusters).

### OP12 camera: scrub stale system/odm mirror on upgrade

Comparing against the known-good debug module confirmed 1170's OP12 path is already correct — the overlay goes to system/vendor/odm ONLY (no system/odm /odm mirror), exactly like the working build; the multicamera HAL crash was caused by the earlier system/odm camera mirror. But a user upgrading FROM a regressed build still had that build's system/odm/etc/camera in the previous install dir, which the manager can keep mounted into the real /odm until reboot — so the camera kept crashing even on the fixed module (explains why "1270" didn't fix it for the APatch user while a clean debug install did). Install now scrubs system/odm/etc/camera and media_profiles from the previous install ($NVBASE/modules and modules_update) and our own staging on OP12, so nothing re-mounts the OP15-shaped multicamera env into /odm. A clean reflash + reboot is still the most reliable, but the upgrade path is now self-healing. video_beauty content note: the working file kept the stock "// Sort by English alphabet" comment and exteragram activity; that comment is harmless (the working camera had it), so the JSON-comment concern was a red herring.

### CRITICAL: OP12 4-cluster CPU topology — fixes battery-mode sluggishness

OP12 (pineapple/SM8650) was unusable in battery mode because the governor only understood a 2-cluster (little/big) or a hardcoded {0,4,7} layout. OP12 actually has FOUR cpufreq policies — policy0{0,1}, policy2{2,3,4}, policy5{5,6}, policy7{7} — and policy4 doesn't even exist. So the big clusters policy2 and policy5 were never managed and stayed pinned near their 614 MHz minimum in the battery profile (confirmed by the hardware-profile reports: policy2/5 cur=614400 while max is 3148800/2956800). That's the "phone unusable below 25%/sluggish in battery" symptom; the RAM growth is most likely a side effect (pinned cores can't drain work, caches pile up).

Fixes:
- cpu_topology_discover() (asb_metrics.h) now dynamically enumerates policy0..15 instead of guessing. For 3+ clusters it maps slot0=first(little), slot2=last(prime), slot1=the strongest middle, and records EVERY physical policy with the slot that governs it.
- writer_apply_caps() (asb_writer.h) now applies each slot's max/min cap to ALL physical clusters in that slot, not just the 3 representative paths — so on OP12 BOTH policy2 and policy5 get the big cap. OP15/OP13 (2 clusters) are unchanged.
- asbdiag section 10 now prints the physical-policy -> slot mapping so the fix is verifiable on-device.

The governor C compiles cleanly; brace balance verified; 329 tests pass. OP15 (my device, 2 clusters) behaves exactly as before.

### Fixed: OP12 camera regression — reverted to the proven-working camera path

Comparing the user's last-working OP12 module against the broken one showed the camera files were byte-identical; the difference was the OP12 *handling*. The working build simply applied the overlay to `system/vendor/odm` and set its normal camera props, and the camera worked. The broken build added three things that together regressed OP12's multicamera HAL (`ChiMcxRoiTranslator::Initialize` SIGABRT): the `system/odm` camera mirror (`_odm_dups` writing camera/media into the direct `/odm` path), an `asb_op12_camera_off` "hard disable" path, and a pineapple camera-prop "diet". Crucially, the working build set `persist.vendor.camera.sat.fallback.dist=2.0`, `mfnr.enable=1`, etc. on OP12 and the camera worked — which disproves the earlier theory that those props caused the crash. The real regression was the new `/odm` camera mirror changing the environment the vendor HAL sees.

OP12 is now back to the working path: `_odm_dups` no longer mirrors into `system/odm` on OP12 (OP13 keeps the dual path — its separate `/odm` genuinely needs it and works), `asb_op12_camera_off` is removed, and the pineapple skips were taken out of `apply_camera_runtime` / `apply_camera_experimental` so OP12 gets the same base camera props the working build used. The OP15-only camera props (video HDR, 4K60 EIS, Hasselblad/Explorer) stay gated to canoe, and the 81-prop static set (which the working build never had) stays off on pineapple. OP13 and OP15 paths are untouched.

### asbdiag: deep per-SoC hardware profile for individual governor tuning

Added section "10. HARDWARE PROFILE" to asb_diag.sh (run with su -c asbdiag — no separate script). It captures everything needed to tune the governor, profiles and Smart mode individually per SoC (canoe / sun / pineapple), which matters because the chips have different cluster layouts and frequency tables — the likely reason OP12 feels sluggish in battery mode while OP15 is fine.

It collects: full CPU cluster topology (every policy with its affected_cpus, hw min/max, scaling min/max/cur, the complete scaling_available_frequencies table, governor + schedutil/walt tunables, scaling driver); a per-core cluster map and online state; CPU capacity (EAS energy model); sched/walt clamp globals and msm_performance cpu_max_freq; the full GPU profile (model, governor, freq table, pwrlevels, busy %, throttling); all relevant thermal zones live temps (cpu/gpu/skin/shell/soc/battery/modem/ddr) and cooling-device count; battery capacity/status/temp/current/health; ASB governor live state (current profile, smart alpha, last plan, log tail); and the shipped profile_bounds.conf BATTERY/BALANCED/PERFORMANCE caps printed right next to the real hardware tables so they can be compared directly. A tuning hint flags the OP12 case: if a BATTERY_CPU_MAX cap doesn't line up with an actual frequency step for that SoC's clusters, the governor may be pinning the wrong cluster low.

### OP12: full camera-off (fixes the multicamera HAL crash for good)

The APatch crash log was unambiguous: the vendor camera HAL SIGABRTs in ChiMcxRoiTranslator::Initialize / ChiMulticameraBase::Initialize during configure_streams — the multicamera override session. It's not props (already clean) and not a specific file; the OP12 HAL simply rejects ANY non-stock camera environment, even valid overlays. And the previous cleanup only stripped system/-prefixed paths, leaving root-level vendor/odm, odm, vendor/etc/media_profiles that APatch can still mount — so "minus camera" never produced a true camera-off.

OP12 (pineapple/SM8650) now gets a hard camera-off: a new install-time asb_op12_camera_off removes every camera dir and media_profiles*.xml across ALL locations (system/vendor/odm, system/odm, system/vendor/etc, and the root-level vendor/odm, odm, vendor/etc plus the op12_overlay copies), wipes any saved camera baselines and camera_orig.conf, and forces ASB_CAMERA=false for the device regardless of the menu. runtime/asb_tweaks.sh returns early on pineapple (no camera baseline/restore/aggressive/inject), and service.sh logs "camera category: fully disabled". OP13 and OP15 are untouched and keep their working camera overlays. Simulated install confirms 0 camera/media files remain for OP12.

### Diagnostics greatly expanded

asb_diag.sh grew from ~300 to ~400 lines and is far more probative:
- Camera: dumps the multicamera/HAL props that matter for the ChiMcx crash (isHasselblad, isSupportExplorer, 4k60.eis, mfnr, multiframe.nr, dual_camera_sat, sat.fallback.dist, aux.packagelist, backCamSize) and the camera-provider service state. On OP12 the verdicts INVERT: it now checks that mvg_sat_config.json is stock-sized (flags the ~3081-byte OP15 one), that video_beauty has NO ASB additions, and that media_profiles is stock — i.e. it actively proves the camera-off is real.
- New MEMORY/LMKD/ZRAM section: RAM totals, swap/zram devices + comp_algorithm, LMKD/vmpressure props, kernel vm tunables (swappiness etc.), memcg presence for BG_TRIM.
- Network: adds rmem_default, available congestion list, tcp_fastopen, default_qdisc, DNS props.
- Audio: adds hifi/offload/fluence/ULL props and AUDIO_EQ_COMPAT state.

### Fixed: OP13 camera first-launch error reintroduced by the OP12 /odm fix

Adding the direct `/odm` write path for the OP12 camera fix made the boot engine rewrite `system/odm/.../conf_tuning_params.json` on every boot — even with CAMERA_AGGRESSIVE off — because `asb_tw_restore_base` always rewrote the file. On OP13 that file maps to the separate real `/odm` partition the camera HAL reads early at boot, so the rewrite raced the HAL and brought back "Loading storage / camera unavailable" on first launch (then cleared). The two builds the user compared were byte-identical, confirming the cause was runtime churn, not content. `asb_tw_restore_base` now byte-compares the live file against the baseline first and skips the write entirely when they already match, so an unchanged conf is never rewritten at boot. Toggling aggressive on/off still applies/reverts exactly once. This keeps the OP12 /odm fix intact while removing the per-boot churn that broke OP13.

### OP12 camera diet now also deletes the multicam SAT prop (ChiMcx crash)

The new crash log from the APatch OP12 was a SIGABRT in `ChiMcxRoiTranslator::Initialize` during `configure_streams` — the multi-camera ROI translator. The device's `mvg_sat_config.json` was confirmed stock (2636 bytes, not the OP15 3081-byte one), so the shipped-config leak is closed. The remaining trigger is a leftover camera prop: `persist.vendor.camera.sat.fallback.dist` (SAT = Smooth Auto Transition, the multi-camera zoom path), which older builds force-set to 2.0 and which is absent from OP12 stock. The pineapple diet deleted ~80 camera props but had three gaps — `sat.fallback.dist`, `main.hfr`, `fast.af` — that the generic path set but the diet never removed. So a device that once ran an older build kept `sat.fallback.dist=2.0` persistently (a clean install returns early before setting it, but never deletes a value a prior build left). The OP12 diet now deletes those three as well, so reinstalling over any old build leaves OP12 with no forced multicamera props. This is the most likely remaining cause of the `ChiMcx` SIGABRT.

Caveat: the crash report came from a pre-1164 install (no `asbdiag` launcher present), so it predates the multicam-config strip and the active prop-deletion diet. source-1165 should be installed fresh on the APatch OP12 and the camera retested; if `ChiMcx` still fires with `persist.vendor.camera.*` all empty (check via `getprop | grep camera`), the cause is outside ASB (a conflicting module or the APatch overlay itself), since the device's camera files and props would then be stock.

### Found the real OP12 camera crash: OP15 multicamera config on /odm

The APatch user's logcat finally pinpointed it. Camera props were already clean (diet working), but the camera HAL still SIGABRT'd in ChiMcxRoiTranslator::Initialize -> ChiMulticameraBase::Initialize during configure_streams, via the OPLUS extension layer (/odm/lib64/libextensionlayer.so, camera.oemlayer.so). "Mcx" = multi-camera: the crash is the multicamera ROI translator choking on an OP15-shaped config.

The module's shipped OP15 camera calibration set (system/vendor/odm/etc/camera) includes multicamera configs — mvg_sat_config.json, infiniti{main,tele,front,ultrawide}, conf_tuning_params.json — that are OP15-specific (our mvg_sat is 3081 bytes with different keys vs OP12 stock's 2636). install.sh already stripped this set from system/vendor/odm for OP12/OP13, but NOT from the system/odm copy that maps to the real /odm partition the extension layer reads. So the OP15 multicam set could reach /odm and crash the HAL. The removal now covers BOTH system/vendor/odm/etc/camera and system/odm/etc/camera at all three strip points. The device-correct camera files still come from the op12/op13 overlay.

### OP12 camera + aggressive audio now robust on APatch (not just KSU)

Two users on the SAME OP12 (CPH2581) got different results — the difference was the root manager, not the device or other modules. On KSU everything applied; on APatch the camera still crashed and AUDIO_AGGRESSIVE didn't take. Diagnosed from the reports: on APatch the camera prop layer was still live (persist.vendor.camera.mfnr.enable=1, empty on the working KSU device) and the module mixer still read CLS_H_ULP (aggressive never written).

Two robustness fixes:
- Camera prop diet now ACTIVELY deletes all 81 camera props on pineapple (resetprop --delete) instead of merely skipping the apply. So even if a previous build forced them, or service.sh timing differs on APatch, OP12 ends up with no forced camera props — HAL-safe. (ro.* props clear on reboot; persist.* clear immediately.)
- The aggressive audio/camera engine no longer SKIPS a file when it has no saved baseline (the old "restore_base || continue" silently did nothing on APatch, where the install-time baseline save hadn't populated /data/adb/asb). It now saves a baseline if missing, restores it, then applies the aggressive patch — so AUDIO_AGGRESSIVE / CAMERA_AGGRESSIVE work regardless of manager.

### Fix: quiet Bluetooth audio (auto mode now truly hands-off)

With bt_absvol_mode = auto, ASB was still forcing persist.bluetooth.disableabsvol=false, enablenewavrcp=true and re-writing the global bluetooth_disable_absolute_volume setting on every boot — none of which exist in stock. Forcing the new-AVRCP stack and re-writing absolute-volume after the BT stack initialises desyncs the volume scale, so BT audio (e.g. YouTube) plays very quiet until an audio-session restart (opening ViPER) re-negotiates it. AUTO is now genuinely hands-off: install strips our absolute-volume + newavrcp props from system.prop, and service.sh skips the absolute-volume writes entirely. ON/OFF still work as before for users who want explicit control. (Applies on reinstall + reboot.)

### Fix: tone-key injection ignored when set to "aggressive"

With CAMERA_AGGRESSIVE on and tone-key mode = aggressive, the injection of the missing tone keys (blueSatParam, nightDownGain*, dayDownGainDarkBoost) silently did nothing — confirmed by the OP13 report (blueSatParam live: none). The runtime flag reader asb_tw_flag only treated "1" as enabled, but the WebUI seg control writes "aggressive", so the inject layer was skipped. asb_tw_flag now accepts 1, on and aggressive as enabled. After this, OP13's lone FAIL clears: the injected keys land in conf_tuning on the next reboot. OP15 and OP12 reports were already fully green (camera prop diet confirmed working on OP12 — the black screen is gone).

### New: global diagnostic, run with one short command

Added tools/asb_diag.sh — a single full-system audit covering everything ASB touches — and a launcher so users don't copy anything: the module ships system/bin/asbdiag on PATH, so after a reboot the whole report is one command:

    su -c asbdiag

The launcher finds the module across KernelSU / APatch / Magisk roots and runs the script; the install summary now prints this command. The audit reports module state and mounts, audio (mixer volume/EQ/Class-H/hi-res + aggressive companders/HPH mode), bluetooth (absolute-volume mode + props + global setting), GPS (capabilities/NTP), Wi-Fi (WCNSS tuning + p2p-safe supplicant + live link), network/TCP (buffer props + kernel rmem/wmem/congestion), camera (retouch/tone/bitrate per read-path, with the OP12 no-props note), performance (CPU freqs+governor, GPU, thermal, cool-gaming), display/UX (HWUI props + animation scales) and the full WebUI governor.conf. Each line shows want-vs-live with a PASS/FAIL/N-A verdict plus a plain-language legend. Saved to /sdcard/asb_diag_report.txt (storage root; real / is read-only) with a /data/local/tmp fallback. install.sh chmods the launcher and both tools scripts; tools/ survives the install prune.

### Fixed: WebUI settings (camera, etc.) lost on module reinstall

Reinstalling the module unzips a fresh config/governor.conf, which overwrote whatever the user had toggled in the WebUI — so camera and other settings reverted to defaults. Install now runs asb_preserve_user_config before finalizing: it reads the previous install's still-on-disk governor.conf and carries the user's saved choices over the freshly shipped file. It migrates only the WebUI-settable keys (AUDIO_AGGRESSIVE, AUDIO_EQ_COMPAT, CAMERA_AGGRESSIVE, CAMERA_AGGRESSIVE_INJECT, bt_absvol_mode, BG_TRIM_LEVEL, cool_gaming, auto_battery_enable, charge_aware_enable, night_quiet_enable/auto, the three UX_* keys, region_allow_locale). Untouched keys keep the new shipped default and brand-new keys this version adds are introduced cleanly. Verified by simulation: a prior install with camera/audio toggles on retains them after reinstall, while new keys still pick up their defaults.

### OP12 camera black-screen: full camera prop diet on pineapple

The OP12 user removed BOTH video_beauty files and rebooted, and the camera still black-screened — which rules out the camera config files entirely and isolates the cause to the camera PROP layer. ASB was forcing ~81 persist.*camera* / ro.*camera props, none of which exist in OP12 (pineapple/SM8650) stock, and the OP12 camera HAL evidently can't tolerate them.

Two structural fixes:
- Relocated the whole static camera prop block out of system.prop (which applies globally and can't be device-gated) into a new service.sh function apply_camera_props_static, so it can be gated per device.
- All three camera prop layers (apply_camera_props_static, apply_camera_runtime, apply_camera_experimental) now hard-skip on pineapple/sm8650: OP12 gets ZERO camera props and runs the stock camera untouched. OP13 (sun) and OP15 (canoe) are unaffected and still get the full set (OP15 also keeps the Hasselblad/Explorer/4k60 props gated to canoe).

This is the "camera prop diet" the data points to: file overlays were already verified green on OP12, so the remaining invasive layer was props. If the OP12 camera comes back with this build, the prop layer was the cause. The lmkd camera-adaptive prop stays in system.prop (it's an LMKD memory tunable, not a camera-HAL prop).

### Fixed: OnePlus 12 camera/GPS desync — module now overlays /odm directly

On OnePlus 12 the camera hung on a black screen and GPS stayed stock, while the verify report showed the smoking gun: `/vendor/odm/...` was patched but the separate real `/odm/...` partition was still stock (camera `video_beauty` app-count 1 vs 8, `media_profiles` bitrate 20000000 vs 37300000, GPS `CAPABILITIES=0x17` + `time.xtracloud.net`). OnePlus 12 (and 13) have a genuinely separate `/odm` partition that the camera/GPS HAL reads directly, but the overlay was written only into `system/vendor/odm` (→ `/vendor/odm`). On OnePlus 13 the two paths happen to resolve together so it looked fine; on OnePlus 12 they diverged and the camera read stale stock config.

The device overlay now writes every `/odm` file into BOTH `system/vendor/odm/` and `system/odm/`, so KSU/Magisk mounts the patched copy into the real `/odm` partition (the manager builds its partition list from the dirs the module ships under `system/`, and already sets up an `/odm` mirror). The boot-time aggressive-camera engine likewise patches and baselines both conf_tuning paths. Whichever partition the HAL reads is now patched and consistent.

### Fixed: invalid JSON in video_beauty_default_config (// comment)

OnePlus 15's stock `video_beauty_default_config` carries a `// Sort by English alphabet` line comment. The file is otherwise JSON and a strict parser rejects it (confirmed: it fails `json.load` as shipped). Install now strips whole-line `//` comments from every `video_beauty_default_config` the module writes, on all devices and both `/odm` paths, restoring valid JSON while preserving permissions and SELinux context.

### Fixed: camera first-launch failure on OnePlus 13/12 with aggressive camera on

The boot engine rewrote the camera conf in place with `sed > tmp; cat tmp > file`, leaving a window where the HAL could read a truncated file or one that lost its SELinux label — surfacing as "Loading storage / camera unavailable" on first launch (OnePlus 13) on devices that read the conf early from a separate `/odm` partition. The engine now writes atomically: it builds the new file in a temp, copies the original's mode/owner/SELinux context, and `mv`s it into place, for both the audio mixer and camera conf writes. A brace-balance check reverts to the baseline if a patch ever yields a structurally broken file.

### WebUI: camera tone-mode is now a compact nested control

Reworked the camera tweak UI so it no longer opens a big second card. "Aggressive Camera Tweaks" stays a single card; inside it, a small "Tone-key mode" row with a compact safe|aggressive segmented switch appears at the bottom, dimmed and locked until the master toggle is ON. A one-line hint ("Aggressive injects keys your model lacks (risky)") replaces the long paragraph. safe = tune existing keys only; aggressive = also inject the missing tone keys. EN + RU.

### Verifier improvements (module-path autodetect + per-device bitrate)

Adopted two fixes after cross-checking the device reports:
- The verifier now discovers the installed module dir by scanning /data/adb/modules, /data/adb/ap/modules and /data/adb/ksu/modules for id=AutoSystemBoost (APatch and KSU use different roots), instead of hardcoding the KSU path — so it stops mis-reporting on APatch (OP12) installs.
- The 1080p bitrate check is now per-device: OP15 (canoe) ships a 40 Mbps profile, OP13/OP12 overlays use 37.3 Mbps, so the previous fixed 37300000 expectation no longer FAILs spuriously on OP15.

Note on the /odm-vs-/vendor-odm mismatch: the camera config differing between /odm (stock) and /vendor/odm (patched) on OP12 is real, but mirroring the overlay into a module-side system/odm does NOT fix it — the APatch/KSU logs show only "Handle partition /vendor" runs, /odm is mounted read-only as a mirror and a module system/odm tree is never mounted there. OP13/OP15 happen to already carry the content in their on-device /odm; OP12's /odm is pure stock and can't be overlaid without writing the real partition (which the module must not do). So the confirmed camera-crash fix remains the canoe-only gating of the Hasselblad/Explorer/4k60 props, not an /odm mirror.

### Fix: OP12 camera crash (OP15-only props forced on every model)

The camera force-set a set of OnePlus 15 (canoe) camera-HAL props on ALL devices regardless of model: ro.vendor.oplus.camera.isHasselbladCamera, isSupportExplorer, persist.vendor.camera.video.hdr.enable and video.4k60.eis.enable. None of these exist in OP12/OP13 stock; forcing the Hasselblad/Explorer pipeline on an OP12 (pineapple, Gen3) made the camera HAL try to bring up hardware that isn't there and crash the camera app — before and after any tweak. These props are now gated strictly to the canoe platform in service.sh, and the 4k60-EIS line was removed from the static system.prop. OP15 keeps them; OP13 (sun) and OP12 (pineapple) no longer get them, which clears the OP12 crash. Confirmed against the device reports: only canoe matches the gate.

Also note from the on-device reports: on OP12 the camera reads its config from /odm, and neither KSU nor APatch overlays /odm (both only "Handle partition /vendor"), so the curated retouch list / tone / bitrate can't be injected there on OP12 — its /odm is purely stock. That's a mount limitation, not a patch failure (OP13/OP15 happen to already carry the content in /odm). The /odm FAILs in the verify report reflect this, not a regression.

### WebUI: camera tweaks regrouped

Moved "Aggressive Camera Tweaks" to sit under "Bluetooth Volume Mode". The former standalone "Inject Missing Tone Keys" item is now a nested safe/aggressive sub-control ("Tone Key Mode") that only appears once Aggressive Camera is ON, rendered indented under it. SAFE = tune existing keys only; AGGRESSIVE = also inject the missing tone keys. governor.conf stores it as safe|aggressive; install.sh and the verifier read the seg value. EN + RU strings updated.

### Verifier: clearer Digital Volume check

The "Digital Volume raised to 88 (across mixers)" line could FAIL spuriously when a SKU exposes the loud control under a different name or already sits at 88 while the patch fully applied (the real signal, "no stock 80-87 left", was already PASS). The check now judges success by "no stock 80-87 Digital Volume left" and reports the ==88 count as info only.

### Added: on-device verification script (tools/asb_verify_device.sh)

A root-shell script that reads the live mounted files and reports, per tweak, the live value vs expected with PASS/FAIL/N/A. The audio section was rewritten to be accurate on multi-SKU devices: instead of grabbing the first `sku_*` mixer alphabetically (which on OnePlus 13 is the inactive `sku_kera`, producing misleading results — a missing control silently counted as 0 and passed/failed by accident), it detects the active SKU from `ro.vendor.audio.sku`, scans every mounted `mixer_paths*.xml`, and judges a tweak present if any live mixer carries it — distinguishing "control absent on this codec" from "control present but unpatched". It also checks `conf_tuning_params.json` on both `/odm` and `/vendor/odm`, probes the governor more robustly, and adds a mount-gap diagnostic that flags when a mixer is patched in the module's staging copy but not visible live (a KSU/Magisk mount issue rather than an ASB failure). Aggressive audio/camera checks remind the user that, from the boot-time engine, those apply after a reboot.

### Aggressive audio + camera tweaks now apply on a plain reboot

The AUDIO_AGGRESSIVE, CAMERA_AGGRESSIVE and CAMERA_AGGRESSIVE_INJECT toggles used to be read only at install time, so flipping them in the WebUI did nothing until the module was reinstalled — and the descriptions said as much. They are now driven by a small boot-time engine (`runtime/asb_tweaks.sh`) shared by the installer and `post-fs-data.sh`:

- At install, after the always-on base tweaks are applied (volume → 88, flat EQ, Class-H DAC for audio; stock tone for camera), a baseline copy of each affected file — every `mixer_paths*.xml` and the camera `conf_tuning_params.json` — is saved under `/data/adb/asb/tweak_base/`. The baseline lives outside the module's `system/` tree on purpose, since anything under `system/` is magic-mounted into `/vendor` and a stray `.asbbase` there would leak into the live partition. The save force-overwrites so a reinstall re-captures a fresh baseline rather than a stale one.
- On every boot, `post-fs-data.sh` restores each file from its baseline and then, only if the toggle is on, re-applies the aggressive layer on top — pre-mount, so the change is live for that boot. Turning a toggle off and rebooting reverts cleanly to the baseline.

This means a normal reboot now applies or reverts these tweaks, for OnePlus 15/13/12 alike. The aggressive logic (headphone companders off + Class-H HIFI for audio; the sunset/blue/shadow tone shifts and the missing-tone-key injection for camera) lives in one place instead of being duplicated across the install branches, and the now-unused install-time helpers were removed. The WebUI descriptions were updated to say the changes apply after a normal reboot. Verified end to end in simulation: toggle on → aggressive applied, toggle off → reverted to baseline, with valid XML/JSON throughout, including the inject path on a trimmed OnePlus 13 conf.

### Full aggressive tone set on every model, via an opt-in "inject" button

Aggressive Camera Tweaks couldn't apply the full tone set on OP13/OP12 because their stock conf_tuning is a smaller, platform-native file (OP15 ships 225 tone params, OP13 only 128, OP12 has no file at all) — the missing keys belong to OP15-specific camera-HAL features. Rather than drop a full OP15 file on them (the same mistake that crashed OP12 with canoe configs), there's now a second, clearly-marked toggle next to Aggressive Camera: "Inject Missing Tone Keys (risky)" (CAMERA_AGGRESSIVE_INJECT, OFF by default, EN + RU, warning icon).

- Aggressive Camera ON alone: rewrites only the tone keys the device already ships (safe; OP13 gets the subset it has).
- Inject ON (requires Aggressive ON): also adds the absent tone keys (blueSatParam, nightDownGainParam/Hizoom/Front, dayDownGainDarkBoostParam) into TMCParamsSet after the sunsetBrightScale anchor, so the full aggressive set applies on OP13 too. Each key is inserted only if absent (no duplicates) and the JSON stays valid.

The injected keys may be ignored by a camera HAL that doesn't consume them (best case) or misbehave — which is why it's a separate, explicitly "risky" button the user enables only to test and can turn back off. Verified: injecting all five into the real OP13 stock conf_tuning keeps valid JSON with no duplicates. The on-device verifier reports the inject state and checks the injected values.

### Aggressive Camera Tweaks toggle (opt-in tone/colour)

Added a new WebUI Config toggle "Aggressive Camera Tweaks" (CAMERA_AGGRESSIVE, OFF by default, EN + RU) mirroring the audio one. When ON it applies small, reversible tone/colour shifts to the camera's conf_tuning_params.json:
- sunsetSatScale 1.6/1.7 -> 1.4 (less over-saturated sunsets, more natural)
- blueSatParam 0.95 -> 1.05 (slightly richer blue sky)
- nightDownGainParam* 0.3 -> 0.4 (lift night shadows for more detail)
- dayDownGainDarkBoostParam 1.3 -> 1.4 (brighter daytime shadows)

Each sed rewrites only the exact stock value and only keys that exist on the device, so OP15 (full conf_tuning) gets all of them, OP13 (trimmed conf_tuning) gets the subset it ships, and OP12 (no conf_tuning on Gen3) gets nothing — no errors either way. When OFF, the camera stays at the stock OnePlus tone. Like the audio toggle, the conf_tuning side applies on the next module reinstall. JSON stays valid after patching; the on-device verifier reports the aggressive camera state.

### Aggressive audiophile mixer tweaks, gated by the WebUI toggle

The Config page's "Aggressive Audio Tweaks" toggle (AUDIO_AGGRESSIVE, OFF by default) now also drives real mixer_paths changes, not just props:
- Headphone companders HPHL/HPHR off (1->0): removes dynamic-range compression on the headphone path for a cleaner, more dynamic signal.
- RX HPH Mode CLS_H_ULP -> CLS_H_HIFI: higher-fidelity Class-H DAC mode at a small power cost.

These apply to all three devices (OP13/OP12 via the in-place mixer pass, OP15 via an aggressive-only pass over its shipped mixers). When the toggle is OFF, every one of these stays at stock — only the safe baseline (vol->88, flat EQ, Class-H DAC armed, hi-res) is applied. Because mixer files are read-only once mounted, the mixer side of this toggle takes effect on the next module reinstall (the prop side applies at boot); the toggle description says so. The on-device verifier now reports the aggressive state too.

### Cross-device tweak audit + on-device verifier script

Audited every ASB tweak against the three stock dumps (OP15/OP13/OP12) and the installed modules. Findings: audio (Digital Volume->88 on every mixer SKU, IIR0 EQ flattened, Class-H DAC, hi-res 384000), GPS (CAPABILITIES 0x17->0x3F, NTP->pool.ntp.org), Wi-Fi (gRuntimePMDelay 2000 / gActiveMaxChannelTime 40 / gBusBandwidthVeryHighThreshold 12000 with p2p_disabled preserved), camera (video_beauty full list with Telegram, tone-fix 0.9, 1080p bitrate 37.3 Mbps) and perf (cool-gaming qape) all apply on every model where the underlying file exists. The only per-model gaps are expected hardware differences (OP12/Gen3 ships no conf_tuning or qapegameconfig).

Added tools/asb_verify_device.sh: a root/Termux script that reads the LIVE mounted system files (post magic-mount, not the module staging copies) and reports PASS/FAIL/N-A for each tweak, including which partition (/odm vs /vendor/odm) the camera configs actually resolve from. It prints to screen and saves the report to /sdcard/asb_verify_report.txt (storage root; the true / is read-only) with a fallback at /data/local/tmp.

### Telegram now matches the standard client (was a modified-client leftover)

The Telegram entry in video_beauty carried activityName "exteragram" — the only entry whose activityName isn't the app's normal identifier (the others are securesms, viber, vk, whatsapp, etc). It came from the OP15 stock dump, which was pulled from a device running a modified Telegram client (exteragram). On a phone with the standard Telegram, that value doesn't match, so Telegram dropped off the retouch list — which is exactly what the OP13 user saw. Changed it to the standard "telegram" across all overlays so it matches the normal org.telegram.messenger client.

### Camera crash on OP12 + short retouch list on OP13 — both fixed (root cause: JSON comment)

Confirmed by parsing the installed dumps: the video_beauty_default_config we shipped had a `// Sort by English alphabet` comment on line 5, and a strict JSON parser fails at exactly that byte (line 5, char 84). The two symptoms were the same bug:
- OP12's camera HAL uses a strict JSON reader (its stock file has no comments) → the parse error crashed the camera.
- OP13 tolerated the file enough to open the screen but fell back to a truncated list (only Viber showed) instead of the full set.
OP15 never showed it because its own stock file ships a comment, so its parser is lenient.

Fix: every video_beauty_default_config is now strict, comment-free JSON. Verified all three contain the full curated list with Telegram and Viber present (OP13: 10 apps, OP12: 8, OP15-base: 7), structure byte-compatible with the stock OnePlus blocks (same fields, same activityName values taken from stock). Also reverted the earlier system/odm overlay: the KSU logs show KernelSU Next only runs "Handle partition /vendor", so an install-time system/odm tree is never mounted — we ship /vendor/odm only, like OP15. The shipped video_MLFT_* and oplus_* camera files that a strict linter flags are stock OnePlus passthrough (one is binary despite the .json name) and are byte-identical to stock — not edited by ASB.

### Fixed: camera tweaks invisible on OP13 (read from /odm, not /vendor/odm)

OnePlus 13's camera HAL reads its config (video_beauty_default_config, conf_tuning_params.json, camera media_profiles) from the /odm partition, while the overlay only wrote the /vendor/odm copies. So on OP13 the "retouch appearance in video" list still showed the stock apps and the tone/bitrate tweaks didn't take — OP15 happened to read /vendor/odm so it worked there. The device overlay now writes BOTH partition copies (/odm and /vendor/odm) for video_beauty, conf_tuning, camera media_profiles, gps.conf and izat.conf, on OP13 and OP12. After reinstall, OP13's retouch list will show the full curated app set (all with beauty off) and the camera tone-fix/bitrate will apply.

### Root vendor/ at the module root is a KernelSU artifact, not a bug

Earlier builds tried to suppress the vendor/ directory that appears at the module root on OP13/OP12 (whiteout markers, symlinks, boot-time heal). The KSU install log settled it: after the module finishes installing, KernelSU Next runs its own "Handle partition /vendor" step that materialises that vendor/ as part of its magic-mount (it mounts the real /vendor read-only as a mirror, then merges only the module's files on top, per file). So the root vendor/ is a framework service copy — the device keeps its full stock /vendor and only ASB's files are overlaid. It does not shadow the partition, which is why OP13 boots and runs every tweak normally. The whiteout/symlink attempts were fighting the framework and have been removed; the layout pass now only folds a genuinely malformed tree from an old buggy build and otherwise leaves KSU's vendor/ alone.

### Fixed: V4A guard was false-stripping ViPER on devices that have it

The previous V4A guard decided whether to keep ViPER4Android by probing `soundfx` directories for `libv4a_re.so`. That probe is unreliable — SELinux or a non-standard lib location can make the file invisible to a shell `find` even when Android loads it fine — and it false-stripped V4A from OnePlus 15, which ships the library. The guard now uses a reliable signal instead: it checks whether the device's **own stock** `audio_effects` config already wires v4a. If the stock config references v4a, the platform demonstrably has the library (Android is using it today) and V4A is kept; only when no stock config mentions v4a — meaning the library is genuinely absent — is the reference stripped from the module's files (inline, preserving XML validity), preventing the missing-library boot crash. Verified against all three stock captures: OnePlus 15 and OnePlus 12 keep V4A (both ship ViPER), OnePlus 13 has it stripped (no ViPER on that build).

### Hardened: stray root vendor/ now unmounts and falls back to a symlink

On OnePlus 13 the installed module still showed a real top-level `vendor/` directory (an on-disk copy of `system/vendor`), while OnePlus 12 and OnePlus 15 did not — OnePlus 15 instead gets a `vendor` symlink. The difference is the root manager: some KSU kernels re-materialise a real `vendor/` from `system/vendor` at mount time rather than using a symlink, and the earlier cleanup's plain `rm -rf` could not remove it when it was a live mountpoint. The layout fix (in both `customize.sh` and `post-fs-data.sh`) now unmounts the stray directory first (handling the mountpoint case), folds its files into `system/<part>/`, and — if a KSU kernel still re-creates it — replaces it with a `./system/<part>` symlink, the exact layout OnePlus 15 ships and boots with. The functional tweaks were already correct on all three devices (they live under `system/vendor`, which is what actually mounts); this removes the duplicate tree so the on-disk layout matches OnePlus 15 everywhere.

### Conflict audit + Bluetooth absolute-volume fix

Did a full pass for parameters set by more than one mechanism (system.prop, governor, profiles, service.sh, install-time sed):

- **Fixed a real Bluetooth conflict.** `bt_absvol_mode=on` was silently undone on every boot: the installer set the disable-absolute-volume props from the chosen mode, but service.sh hardcoded them back to 0/false at runtime. service.sh now reads the same `bt_absvol_mode` from governor.conf, so "on" actually sticks.
- Verified the CPU-cap layering is NOT a race: with `msm_perf_boost_only=1` the governor drives caps via msm_performance and only touches `scaling_max_freq` as a budgeted anti-clamp when the vendor thermal HAL clamps below target; service.sh's profile cap is the base layer. They cooperate.
- Confirmed profile_bounds.conf and the generated C header are in sync (CPU_CAP->floor, CPU_MAX->ceil), no duplicate/conflicting props in system.prop, no overlapping prop writes between post-fs-data and service, and that settings changes (including the GMS tracking block) all save originals for clean restore on uninstall.

### Wi-Fi tuning restored (the safe way) on all three devices

Earlier I over-corrected and dropped Wi-Fi tuning entirely while fixing the toggle bug. Wi-Fi tuning is back, done device-safely like the audio/perf passes: ASB clones the device's own stock wifi dir and sed-patches a small, conservative set of WCNSS driver values in place (only keys that already exist):

- Power: `gRuntimePMDelay` 3000 -> 2000 (radio idles to runtime-PM sooner)
- Latency: `gActiveMaxChannelTime` 45 -> 40 (shorter active-scan dwell)
- Throughput: `gBusBandwidthVeryHighThreshold` 15000 -> 12000 (engage high-perf bus sooner)

The supplicant overlay files are cloned verbatim and never patched — their p2p_disabled/tdls lines keep the Wi-Fi toggle working. Roaming thresholds and regulatory country are left alone. Applies to OP15/OP13/OP12. (The system.prop side was dropped: the wifi props I first added weren't real OnePlus/QCOM keys, so they'd have been inert placebo — only the verified WCNSS file values are kept.)

### Critical fixes: OP15 Wi-Fi toggle, OP12 detection, stray vendor/ cleanup

Three on-device problems found by comparing installed OP15/OP13/OP12 modules:

- **OP15 Wi-Fi toggle would not stay on.** The module shipped a `wpa_supplicant_overlay.conf` with the stock `p2p_disabled=1` / `tdls_disabled=1` lines removed; overlaying that over OP15's firmware stopped the toggle from enabling. Removing `system/vendor/etc/wifi` by hand fixed it, which pinpointed the cause. ASB doesn't tune any Wi-Fi config values, so it no longer ships or clones Wi-Fi configs at all — the device keeps its own stock files, and regulatory country is handled at runtime in service.sh.
- **OnePlus 12 was detected as "generic OnePlus".** The SM8650 fallback matched only the SoC string, but some ROMs report the platform as `pineapple` while hiding `ro.soc.model`, so OP12 fell through to the generic path (audio off, vendor overlay pruned, near-empty system/). The fallback now also matches `pineapple`, mirroring how OP13 matches both `sm8750` and `sun`.
- **Stray root-level vendor/ now cleaned at boot.** A real top-level vendor/ beside system/ (seen duplicated on OP13/OP12 installs) is now folded into system/ and removed in post-fs-data.sh, pre-mount, so even a module left in a bad layout by an older build self-heals on the next boot.

### Fixed: OnePlus 13 shown as "CPH2649" in WebUI

The device name on the WebUI home page resolved from a model-code map that listed the OnePlus 13 only under CPH2721/PJE110. Units reporting CPH2649 (and the CPH2653/CPH2655/OP5D55L1 variants) fell through to the raw code. Those codes are now mapped to "OnePlus 13", so the header shows the proper market name. OP12 was already correct.

### Fixed: Wi-Fi toggle could refuse to turn on

The boot service was running `cmd wifi force-country-code enabled IT` on every start, with a hardcoded "IT" default and no detection. Forcing a regulatory domain that disagrees with what the modem reports can stop the Wi-Fi toggle from switching on. This now: (1) heals existing installs by undoing the force once on next boot, (2) no longer forces a country at all, and (3) only sets a soft `wifi_country_code` hint when a confident SIM/operator ISO code is present (or an explicit WIFI_COUNTRY override), leaving regulatory authority to the modem. Applies to all devices.

### Quieter install tail

The per-device tuning steps (perf, GPS-assist, region localization) now apply silently \u2014 no per-step lines at the end of install. The Bluetooth-volume line only appears when you pick a non-default mode (auto is silent), and the "install summary written" confirmation was removed (the file is still written for debugging). The install summary file records what was applied for anyone who needs it.

### OP13/OP12 fixes from on-device audit + V4A fully silent

Comparing a live OP13 install against the previous one surfaced two things:

- **Speaker volume now boosted on OP13/OP12, not just headphones.** The per-device mixer patch only raised the RX (headphone) Digital Volume paths to 88; the WSA (speaker amplifier) paths stayed at stock. It now boosts both RX and WSA across the 80\u201387 range, matching what the OP15 mixer pass already did \u2014 so the loudspeaker gets the same lift.
- **Honest Wi-Fi region reporting.** OP13 ships WCNSS/supplicant files with no explicit country line (the modem drives the regulatory domain at runtime). The localizer now only replaces an existing country line and never inserts one \u2014 forcing a SIM-derived country where the device intentionally omits it risks a wrong regdomain when roaming. The install summary reports "unchanged (modem-driven regdomain)" in that case instead of a misleading "localized: yes".
- **V4A status no longer printed at all** \u2014 it applies silently whether or not the library is present.

### Quieter install output + cleanup

- The V4A status line now prints once instead of once per audio_effects file (was 9 identical lines on OP15). The library is detected a single time before the loop.
- Perf and Location/GPS tuning each collapsed from a multi-line banner to one concise summary line.
- Removed the empty legacy Magisk-template index file (`.AutoSystemBoost-files`) that could be left behind in `/data/adb/modules/` \u2014 ASB ships its own uninstall.sh and never needed it.

### Video-call beauty disabled on OP13/OP12 (matching OP15)

ASB ships a camera `video_beauty_default_config` that forces the per-app "face beauty" smoothing OFF for video-call apps, so your face isn't auto-retouched in calls. This is now applied on OnePlus 13 and OnePlus 12 as well. Rather than copy the OP15 file verbatim, each device gets a merged list: OP15's curated messenger set (Signal, Meet, Telegram, Instagram, Viber, VK, WhatsApp) plus whatever the device's own stock config already covered (Discord/Teams/WeChat on OP13, WeChat on OP12) — all with beauty off. Gated by the CAMERA category.

### Fixed: OnePlus 13 bootloop from a stray root-level vendor/ directory

The real OnePlus 13 bootloop was a module-layout fault, found by diffing the actually-installed module against a working OnePlus 15 install. A Magisk/KernelSU module must keep every mounted file under `system/` — the root layer maps `system/vendor` → `/vendor`, `system/odm` → `/odm`, and so on. The OP13 install ended up with a **real** top-level `vendor/` directory (≈32 device-patched files) sitting beside `system/vendor/`. The root layer can bind that partial directory over the whole real `/vendor` partition, hiding the thousands of files vendor init needs → vendor init fails → bootloop. OnePlus 15 dodged it because its full shipped `system/vendor` produced a clean `vendor` symlink instead of a real directory; on OP13/OP12 the pruned-and-rebuilt tree materialised a real one.

A final install step, `asb_normalize_module_layout`, now guarantees the safe single-tree layout on every device: any real top-level `vendor/`, `odm/`, `product/`, `system_ext/`, `my_product/`, or `mi_ext/` directory is folded back into `system/<part>/` (the `system/` copy wins on any conflict), the stray root directory is deleted, and its entries are pruned from the restore manifest. Symlinks created by the framework (the normal layout) are left untouched, so OnePlus 15 is unaffected. This is layout-level and device-agnostic, so it also protects OnePlus 12.

### OnePlus 13 & 12 get the portable subset of the OnePlus 15 mixer tune

OnePlus 15's hand-tuned mixer carries ~44 control changes. Most are canoe-codec-specific (HiFi Function, DS2 OnOff, Amp DSP Enable, Codec Wideband, Audiosphere, Virtual Bass Boost, HPH Idle Detect, Set Custom Stereo, Voice Sidetone) and are simply absent on OnePlus 13's and OnePlus 12's codecs — injecting them would be wrong or harmful, so they are deliberately not ported. What *is* shared across all three codecs — verified control-by-control against each device's own stock mixer, with identical pre-patch baselines — is the character of the tune, and that is now applied in place to the device's freshly-cloned mixer files (every `sku_*` and cdp/mtp/qrd variant): `RX_RX0/1/2 Digital Volume` 84 → 88 (the louder playback), `IIR0 Enable Band1..5` → 0 (flatten the stock EQ), and `HPHL/HPHR_RDAC Switch` → 1 (Class-H headphone DAC always armed). The edits are name-anchored, so a control that doesn't exist on a given codec is a no-op; the XML stays valid on both devices. Gated by the audio category. Real-device listening is still the final check, but the baselines match OnePlus 15 exactly, so the result should track its sound for the shared controls.



OnePlus 15 previously shipped its perf (`perfconfigstore`, `perfboostsconfig`, `qapegameconfig`, `qapeboostsconfig`) and GPS-assist (`xtwifi.conf`, `lowi.conf`) configs as static pre-patched files in the project archive. These edits are fully reproducible by the same in-place sed patching used for OnePlus 13/12, so OnePlus 15 now runs `asb_patch_perf_inplace` + `asb_patch_location_inplace` against its own live stock files at install time, and those static files were dropped from the shipped tree. The hand-tuned audio SKU and WCNSS WiFi configs (thousands of lines of bespoke mixer/policy edits that no sed pass can reproduce) remain shipped as-is — those are the actual OnePlus 15 tuning and are not safe to regenerate. Net: the shipped `system/` dropped from 131 to 124 files with zero behaviour change on OnePlus 15.

### WebUI: automatic Russian localization

The WebUI now ships an i18n layer that switches the entire interface to Russian when the device/browser language is Russian (`navigator.language` starting with `ru`), and stays English otherwise. Coverage includes navigation and section headers, the four power-profile names, every Live-monitor cell label, the full Config page — including each setting's name, description, and segmented option labels — and all toast messages. English remains the in-markup fallback, so any string without a translation degrades gracefully. The translation lives in a single `I18N.ru` dictionary for easy extension to other languages.



Two layout faults were visible in the installed OnePlus 13 module: a nested `system/system/` directory and a real top-level `vendor/` beside `system/`, neither of which OnePlus 15 has. The nested `system/system/` came from the audio/wifi clone re-applying the `system/` prefix to a live source path that already started with `/system` (`/system/vendor/etc/audio` → `system/system/vendor/...`); the clone now canonicalises the source by stripping a leading `/system` and clones only the **first** matching source (`/vendor` before `/odm` before `/system/vendor`), so it always lands at `system/vendor/...` and never duplicates the same tree into a second location. That first-match rule also removed a third fault — an earlier build cloned both `/vendor/etc/audio` and `/odm/etc/audio`, materialising a redundant `system/odm/etc/audio/audiox_param` tree (plus `system/odm/etc/wifi`) that simply duplicated files the device already has on its own `/odm` partition.

The real root `vendor/` is folded back into `system/vendor/` by a final normalization pass that now runs in `customize.sh` **after** the installer framework has fully finished — the previous pass ran mid-install and could be undone by later framework steps. The normalization also collapses any `system/system/` as a safety net, prunes the restore manifest, and reasserts the `vendor_configs_file` SELinux context. The result matches the OnePlus 15 layout on both OnePlus 13 and OnePlus 12: a single `system/`-only tree with no root partition directories and no nested `system/system`. Framework-created symlinks (the valid layout) are left untouched.



A second latent bootloop risk on non-OnePlus-15 devices: the device-agnostic audio pass injected the ViPER4Android FX effect (`<library name="v4a_re" path="libv4a_re.so"/>`) into the device's `audio_effects` config. That library ships natively in OnePlus 15's OxygenOS (its stock `audio_effects_config.xml` already references v4a), but OnePlus 13's does not — referencing a missing effect library makes `audioserver` fail to load effects at boot. The injection is now guarded on the library actually existing under any `soundfx` directory in `/vendor`, `/odm`, or `/system` (lib and lib64); if it's absent the stock effects chain is left intact. OnePlus 15 behaviour is unchanged.

### Fixed: OnePlus 13 & 12 missing their own audio/wifi config dirs

The shipped `system/vendor/etc/audio` (sku_canoe/sku_alor) and `.../wifi` (wcn7750/kiwi_v2/peach_v2) directories are OnePlus-15 hardware-specific. The overlay path correctly deletes them on OnePlus 13/12 but never replaced them — so those devices were left with **no SKU audio directory** and a **wrong top-level `mixer_paths.xml`** (the OnePlus 15 canoe one), while their real per-codec configs live under `sku_sun`/`sku_kera`/`sku_tuna` (OP13) and `sku_pineapple`/`sku_cliffs` (OP12). Android's audio HAL selects its mixer/policy by SKU at runtime, so a generic top-level file carrying another codec's values can mis-route or mute paths; WiFi `WCNSS_qcom_cfg*.ini` is chip- and regulatory-specific too.

The installer now clones the live device's own `audio/` and `wifi/` config directories into the module so it ships the device-correct configs, and drops the OnePlus 15 top-level audio policy/mixer files that don't belong. OnePlus 15's tuned values are deliberately **not** cross-ported onto a different codec or WiFi chip — that would be unsafe — the device's own working configs are restored, and the device-agnostic in-place EQ/volume/codec pass still patches the device's own files by name. Gated by the audio and WiFi categories respectively.

A second latent bootloop risk on non-OnePlus-15 devices: the device-agnostic audio pass injected the ViPER4Android FX effect (`<library name="v4a_re" path="libv4a_re.so"/>`) into the device's `audio_effects` config. That library ships natively in OnePlus 15's OxygenOS (its stock `audio_effects_config.xml` already references v4a), but OnePlus 13's does not — referencing a missing effect library makes `audioserver` fail to load effects at boot. The injection is now guarded on the library actually existing under any `soundfx` directory in `/vendor`, `/odm`, or `/system` (lib and lib64); if it's absent the stock effects chain is left intact. OnePlus 15 behaviour is unchanged.

A short, practical follow-up to V51 driven entirely by real device logs: a couple of WebUI numbers that were misleading or missing are now correct, two more background daemons are silenced, and Cool Gaming graduates to a default after field testing showed no fps cost.

> Cumulative on top of the published V51 release. Nothing from V51 was removed.

---

### Runtime GMS tracking suppression (reversible) + OP15 camera tone-fix

- **GMS/analytics tracking block via the settings DB.** Some Google analytics endpoints (Clearcut, Phenotype log upload, GA collection, usage-stats, ad-tracking) live in `settings global`, which props can't reach. Added a runtime block for these, gated under the LOG category. Every changed key's previous value is saved to a restore log, and the module's uninstall puts them all back — so it's fully reversible. This closes the one real privacy gap versus dedicated debloat modules: ASB now covers both prop-level telemetry suppression and the settings-DB analytics keys.
- **Camera tone-fix now on OP15 too.** The over-bright / false-HDR easing (gentler high-lux tone-mapping and higher highlight-fusion thresholds) previously added for OP13/OP12 is now applied to the OP15 shipped camera tuning as well, so bright-sunlight video looks more natural on all three devices. Sensor color/noise calibration remains untouched. Experimental — compare before/after footage.

### Broader GMS analytics suppression

Closing a couple of gaps versus dedicated debloat modules:

- **Broader GMS analytics suppression** (LOG category): added framework-level flags to quiet Clearcut/Phenotype/usage reporting and GMS version reporting, on top of the existing wide telemetry/logging suppression (statsd, ostatsd, nocheckin, tombstones, logd trimmed to 32K, OPlus gaia/theia/midas daemons stopped). Best-effort — some reporting is gated server-side by Google.

These make ASB's telemetry/logging coverage match or exceed a typical battery-debloat module, so it can stand on its own for users who want both performance tuning and reduced background reporting in one module.

### Safer defaults & sharper diagnostics (review pass)

A round of corrections driven by code review, tightening defaults that were too opinionated and adding observability so results can be judged on numbers:

- **Bluetooth volume is now a setting, not a forced default.** The earlier change that disabled absolute volume globally was reverted — it can be louder on some sinks but also alters the volume scale and steps, so it's polarizing. New `bt_absvol_mode` (auto/on/off) in Config; default **auto**, which currently behaves as off (stock-safe). Turn it on if you specifically want the phone to drive a quiet car/speaker directly.
- **Region localization is more conservative.** Wi-Fi country is now rewritten only from a confident SIM or network-operator ISO code. System locale is no longer used unless explicitly opted in (`region_allow_locale=1`), since locale ≠ real location and a wrong regulatory domain is worse than a foreign-but-correct one. The detection source and applied value are recorded.
- **Install summary file.** The installer now writes `install_summary.txt` (device detected, overlay applied, region source/result, BT volume mode, camera/GPS applied) so post-install debugging doesn't require guesswork.
- **Budget self-correction hygiene completed.** The bias streak is now cleared on charging as well as during the night override, so the daytime forecast never learns from charging windows or deep-idle nights.
- **Gaming peaks in the report card.** Added `game_charging`, `bat_temp_peak`, `cpu_max_peak`, and `cool_level_peak`, so charge-aware Cool Gaming can be evaluated on real numbers instead of feel.
- **Plain-language diagnosis.** The report card now ends with `diagnosis: primary=… secondary=…` and a one-line `improvement:` hint, derived from the same quality subscores — so 20 numbers resolve to one actionable takeaway.

### Config page refresh

The WebUI Config page was restyled into cleaner cards: each setting now has an icon tile, a colored status badge (Enabled / Disabled / mode), and a larger toggle, in ASB's own teal accent. Purely cosmetic — same settings, same behavior.

### Region-aware WiFi/GPS at install time

The shipped WiFi and GPS configs were authored with an Italian regulatory domain (`gCountryCode=IT`, `country=IT`, `it.pool.ntp.org`) — correct for the author, wrong for everyone else. WiFi country code is a **regulatory** setting: a mismatched one can block channels the device is allowed to use or, worse, permit ones it isn't. The installer now detects the device's country at install time — from the SIM operator, then the network operator, then the system locale — and rewrites the WiFi country across every shipped WCNSS/supplicant file accordingly. The GPS NTP server is switched to the global `pool.ntp.org`, which always resolves and routes to nearby time servers (a hardcoded per-country pool can be dead in some regions, which would break time sync entirely). If no country can be detected, the values are left as-is rather than guessing. This applies to all three devices; OP13/OP12 keep their own stock WiFi regulatory tables, so only their NTP is normalized.

### Fixed: shipped top-level mixer_paths missed the volume boost

An on-device audit of a live ASB install surfaced that the shipped top-level `mixer_paths.xml` (vendor/etc and vendor/odm/etc) still carried stock `Digital Volume` values (86) while every SKU-specific mixer was correctly boosted to 88. On OP15 this is harmless — the SKU mixer (sku_alor/sku_canoe) is the active path and was patched — but on a device or variant that falls back to the top-level mixer, the volume boost would have been missed. The shipped top-level mixers are now pre-boosted to match (Digital Volume → 88, HPHL/HPHR RDAC enabled), so the louder-audio tuning applies regardless of which mixer the device loads.

### Multi-device support: OnePlus 13 & OnePlus 12

ASB now installs and adapts to three devices, auto-detected at install time:

- **OnePlus 15** (CPH274x / SM8850) — full package, unchanged.
- **OnePlus 13** (CPH2649 / SM8750 "sun") — new.
- **OnePlus 12** (CPH2581 / SM8650 "pineapple") — new.

The installer detects the device by model, codename, and SoC, then applies the matching overlay. The large in-place audio/media pass (volume boost, hi-res sampling rates, codec ceilings, mixer gains, A2DP formats, Bluetooth) is device-agnostic — it finds the device's own files by name and patches them — so it already works identically across all three. On top of that, OP13 and OP12 get device-tuned overlays for GPS (accuracy/lock-speed), camera, and video-recording bitrates (including raised slow-motion), with the factory sensor calibration left intact.

### Perf tuning ported to OnePlus 13 & 12

The OP15 package shipped pre-tuned `perf/` XML as full-file replacements valid only for the `canoe` target; on OP13/OP12 those files were either pruned or, worse, the target-less `qapegameconfig.txt` would have applied OP15's game caps globally. Perf tuning now patches the **live device's own** stock perf files in place — the same OS-update-proof approach ASB already uses for audio — keyed to each device's targets (`sun`/`tuna`/`kera` on OP13, `pineapple`/`cliffs` on OP12).

The tuning mirrors OP15's intent with device-correct values: per-game thermal/current ceilings lowered (48 °C/1150 mA → 44 °C/900 mA, so games throttle earlier and run cooler — OP13 only, OP12's older perf framework has no game-config); debug daemons turned off (`enable.lm`, `memperfd`, `prekill`) as pure overhead; foreground render-thread boost enabled; blind qape boosts shortened (duration 10→3, count 3→1); refresh-rate switch hysteresis 10→12 s; and the idle render-thread boost trimmed (2000→1600 ms). Only props and rows that already exist on the device are touched, so each platform degrades gracefully. The stale `canoe` perf files are stripped before the device-correct ones are cloned, so no wrong-target config leaks. Gated by the CPU category.

### Location/GPS-assist tuning ported to OnePlus 13 & 12

The OP15 package also shipped tuned `xtwifi.conf` (Qualcomm GTP / XTRA assisted-GNSS) and `lowi.conf` (WiFi RTT ranging) as static `canoe` copies carrying `MODEL_ID="OnePlus15"`. These are now patched in place on the live device's own files instead: the assisted-GNSS cache is raised 5 MB → 32 MB (more almanac/XTRA cached → faster re-locks), assist-daemon debug logging is turned off, the GTP model id is set to the real device, and the low-power WiFi-RTT path is enabled. The stale OP15 copies are stripped first so no `OnePlus15` model id or OP15-only GTP server leaks onto another device. Only keys already present are rewritten; gated by the GPS category.

### Louder Bluetooth output

Disabled Bluetooth absolute-volume delegation (`persist.bluetooth.disableabsvol`). With absolute volume on, the phone hands volume control to the car head-unit or speaker, many of which cap at a conservative level — which is why some cheaper phones sound louder over the same speaker. Turning it off lets the phone drive the sink's gain directly, so Bluetooth output (car audio, speakers) can go meaningfully louder. Applies when the Bluetooth category is enabled.

### Camera: eased over-bright / false-HDR tone mapping (OP13/OP12, experimental)

Addressing a reported issue where video in bright sunlight looked over-bright with a visible HDR-like "pop" (strong local contrast on landscapes) even with HDR off. The cause is the ISP's tone-mapping curve and multi-frame highlight fusion engaging aggressively in high-lux scenes. Conservatively eased the high-brightness scaling and raised the highlight-fusion thresholds so the false-HDR effect is reduced while leaving normal and low-light behavior alone. This is **experimental** and benefits from real before/after footage to refine — the sensor color/noise calibration itself is untouched.

### Charge-aware Cool Gaming

Cool Gaming now adapts to the worst thermal case: gaming *while charging* with a warm battery, where render heat stacks on top of charge heat. On battery it behaves as before (engages the thermal lean from ~40 °C / 2 °C/min). When charging with a battery above ~38 °C, it tightens to engage earlier still (~38 °C / 1.5 °C/min), since that's the scenario where the device runs hottest and is least pleasant to hold — and also where fps headroom is usually available (you're rarely in a ranked match while plugged in). It stays a single tier of cooling the rest of the time, so normal on-battery play is unaffected. Exposed as `cool_gaming_level` (0/1/2) in status.

*Why only this idea from the larger gaming-cooling wishlist:* the stronger proposals (phase-aware combat/menu detection, GPU-vs-CPU bottleneck classification) need frame-time and touch-density signals the governor can't read cheaply, so acting on them would be guesswork — and guessing wrong means throttling mid-combat, the worst outcome. Charge-aware cooling uses only signals already on hand (charging state, battery temperature, game detection) and targets the one scenario where extra cooling is both most needed and least costly.

### Camera: slow-motion bitrates raised to match normal-record quality

Audited every video encoder profile in the camera `media_profiles.xml` by bits-per-pixel-per-frame. The normal record modes were already well-provisioned (1080p@30 and 4K@30 sit at a healthy ~0.5–0.64 bpp) and the sensor/ISP calibration files were left untouched — those are factory-tuned and not something a config edit can improve. But the high-speed (slow-motion) profiles were clearly under-provisioned: 1080p@120 and 720p@240 ran at ~0.20–0.25 bpp, roughly a third of the normal-record density, which shows up as soft, mushy slow-mo. Raised the high-speed bitrates to match normal-record efficiency (~0.42–0.45 bpp): 4K@120 248→418 Mbps, 1080p@120 50→112 Mbps, 720p@240 55→99.5 Mbps, 480p@240 6.4→33 Mbps. Slow-motion footage keeps far more detail; normal photo/video and all color/noise calibration are unchanged. Only applies when the Camera category is enabled.

### Budget accuracy reads "paused" overnight instead of a stale 0/100

The night gating added in V51 correctly suspends the budget self-correction during sleep (the bias streak stays at 0, so it never learns from near-zero idle drain). But the *displayed* accuracy score kept showing the last daytime value — which during a deep-sleep night reads as a misleading `0/100, error 100%`, as if the forecast had failed. The status now publishes the no-data sentinel while grading is suspended, and the report card shows `budget accuracy: paused (grading suspended during sleep/charge)` instead of a stale figure. Cosmetic only — the correction logic was already behaving correctly; this just stops the number from lying about it.

### 🎮 Cool Gaming is now on by default

V51 shipped Cool Gaming as an opt-in. Field testing settled the question: with it enabled, peak current dropped ~28 % and peak temperature fell ~4 °C in sustained play, **with no noticeable fps loss** — COD Mobile at 165 Hz stayed smooth. So it's now **on by default**. It still does the honest thing — capping how hard the SoC is pushed in games for a cooler, more even profile — and can be switched off in Config for an unrestrained SoC if you want absolute peak fps. *(Existing users who already set it keep their choice; new installs get it on.)*

---

### 🔇 Two more OPlus telemetry daemons silenced

Added `oplus_gaia` and `oplus_theia` (plus `theia_screen_monitor`) to the boot-time daemon stop list and the prop disables. These are OPlus AI/analytics daemons that periodically wake the CPU during idle. ASB already stopped the broader telemetry set; these two analytics daemons weren't covered. They go through the same guarded stop path as the rest (verified stop with retry, not a blunt kill), so the handling stays safe and consistent.

---

### 📊 WebUI corrections

- **Headroom no longer stuck at n/a.** The governor computed thermal headroom correctly but never wrote the `headroom_valid` flag to the file the Live page reads, so it always fell back to n/a. Fixed — Headroom shows its real value.
- **Honest battery-life labels.** "On time" / "Off time" were never elapsed-time counters — they're battery-life *estimates*, which is why they counted down and why "off" showed absurd 50–80 h. Relabeled to **"Est. on" / "Est. idle"**, with the idle estimate anchored to a realistic deep-idle draw band instead of swinging with the active EWMA. The action-button screen got the same idle fix.

---

### 🧪 Quality gate

- **324 automated tests** (81 + 243), 0 failures
- Clean compile in both release and debug flavors
- Lint: 0 errors, config CLEAN
- **249 files**

---

## V51 — *the self-checking release*

V50 made ASB **smart** — it learned your nights, forecast your battery, and scored its own sessions. V51 makes it **honest**: it now measures whether its own predictions are right, corrects them when they drift, refuses to learn from junk, and shows you cleaner numbers while doing it. On top of that, a round of field-driven efficiency fixes and one new opt-in comfort feature.

> Everything below is **cumulative against the published V50 release.** No V50 feature was removed — this is refinement, correctness, and a few genuinely new capabilities.

---

### 🧠 The forecast that grades itself

**Budget accuracy score.** V50's energy budget predicted hours-to-empty but never checked itself. V51 anchors each prediction, waits 30 minutes, then compares the predicted depletion pace against the *actual* battery delta — publishing `budget_accuracy_score` (0–100) and `budget_error_pct`. For the first time the module can tell you not just what it thinks will happen, but how often it's been right.

**Closed-loop self-correction.** Measurement alone isn't enough. When the forecast misses in the *same direction* for three consecutive windows (~90 min of consistent bias), the drain rate feeding the budget is nudged by a small bounded factor — at most ±12%, scaling with how long the bias persists. Under-prediction leans the budget a little sooner; over-prediction relaxes it. A single noisy window never moves anything: the streak gate and hard cap keep it from oscillating, and any direction flip resets the streak.

**Deep-sleep awareness.** Overnight, the device drains so slowly (~0.3%/h) that grading the active-use forecast against it is meaningless — so the accuracy loop now **pauses while the night/sleep override is active**, and discards any bias built from those windows. It learns from your waking hours, where the comparison actually means something, and never teaches itself that "drain is always tiny."

---

### 🌙 A cleaner night learner

**Hygiene — rejects bad samples.** V50's sleep-schedule learner was strong, but the failure mode for things like it is quiet poisoning by one weird night. V51's learner now distinguishes good wake samples from bad: a wake that lands outside the plausible morning window (a nap, a travel day, an odd schedule) is **rejected** rather than averaged in, so one irregular night can't drag your learned wake time toward a 3 AM outlier. Accepted/rejected counts are published and shown in the sleep report's new hygiene line, so you can watch the learner stay clean over time.

**Session count survives reboots.** The Live page used to show "0 ses" right after a reboot, as if the learner had been wiped. It hadn't — the actual learning persisted fine — but the *displayed* counter was a runtime variable that reset on every restart. It's now seeded from the persisted observation count, so your learner's progress reads continuously across reboots.

---

### 🎮 New: Cool Gaming toggle

By request — an **opt-in** way to run games cooler. Off by default. When enabled (Config page), the predictive thermal lean treats any detected game like a known-hot app and engages early — from ~40 °C and a gentler 2 °C/min ramp instead of 45 °C / 3 °C/min — capping how hard the SoC is pushed under sustained load. The result is a cooler, more even thermal profile during play, at the cost of a little peak performance.

It's deliberately off by default and clearly labeled: in-game heat is mostly chip physics, and the honest way to lower it is to cap the work the GPU/CPU do — a performance trade *you* should choose, not a silent default.

---

### 🔋 Field-driven efficiency

**Cooler, longer nights.** The quiet-night tick was loosened (20 → 30 s) and the post-boot settle window extended (15 → 20 min), so the device sits more deeply in idle overnight and rides out the post-reboot work without a heat bump.

**Profile tuning fixes.** Three real inconsistencies, corrected: the performance profile's TCP keepalive was waking the radio every 60 seconds (now 600 s, in line with the other tiers); the battery profile's `vm.swappiness` was an aggressive 150, burning CPU on zram compression (now a saner 100); and the performance top-app uclamp ceiling sat *below* balanced's — now raised so the tiers rise monotonically.

**Network buffer fix.** The balanced profile shipped a TCP not-sent low-watermark value that bloated the socket buffer; corrected to trim wakeups during everyday scrolling.

**Shorter post-boot warm-up.** Profile fixes (keepalive, swappiness, GPU thermal floor) combine to take the edge off the first 20 minutes after a reboot.

---

### 🛠️ Correctness & consistency (the quiet wins)

**service.sh ↔ profile_core consistency.** A latent bug: two same-named profile loaders disagreed about whether to map the profile's `_P_*` variables. The wrong one won in the boot path, so `apply_net`/`apply_vm` ran with empty values and issued dead sysctl writes. The real tuning still landed via the other engine, but the empty writes were wasted work and a latent risk of clobbering a fresh value on some kernels. Both paths now see correct values.

**Quality verdict no longer cries "vendor war."** A gaming session scored a harsh `vendor_war` verdict when the real story was a hot, hungry game and the vendor was simply thermal-clamping under load — correct protection, not a war. Vendor-war is now named the primary failure only when it beats the next-worst component by a clear margin; under heavy load where battery/heat are genuinely worse, the verdict points there instead.

**Report cards always written.** The report card, sleep night-verdict, and smart summary could go missing entirely when a capture was stopped in a way that bypassed the exit trap (detached parent, SIGKILL). They're now emitted periodically *during* the run, so the latest verdict always exists on disk regardless of how the capture ends — and they read only live state, so they're correct at any point mid-run.

**No more phantom Magisk folder.** A dead busybox shim was creating a stray `/data/adb/magisk/busybox` path on KernelSU setups. Removed, with cleanup of the broken symlink on boot.

---

### 📊 Cleaner WebUI

**Headroom now displays.** The Live page's thermal Headroom was permanently stuck at `n/a` — the governor computed it correctly but never wrote the `headroom_valid` flag to the file the page reads. Fixed; Headroom shows its real value.

**Honest battery-life labels.** The Live page's "On time"/"Off time" were never elapsed-time counters — they're battery-life *estimates*, which is why they counted *down* and why "off" showed absurd 50–80 h. Relabeled to **"Est. on" / "Est. idle"**, and the idle estimate is anchored to a realistic deep-idle draw band instead of swinging with the active EWMA. The action-button screen got the same idle fix.

**Cleaner cap-source labels.** The cap-source field showed raw internal codes (`asb_dynamic`, `shell_overridden_down`, `vendor_clamp`); they now read as plain **ASB**, **Shell**, **Vendor**, **Thermal**. Color coding unchanged.

**Write-suppression observability.** New counters expose how often ASB deliberately *doesn't* write — `write_attempts`, `write_skipped_detente`, `write_skipped_backoff` — so the détente and hysteresis logic is visible instead of invisible.

**Drain-spike → budget pressure.** A detected drain spike now bumps budget severity for a short window, so a sudden burst of consumption tightens the forecast immediately instead of waiting for the EWMA to catch up.

---

### 🧪 Quality gate

- **324 automated tests** (81 + 243), 0 failures
- Clean compile in **both** release and debug flavors (`-Wall -Wextra`)
- Lint: 0 errors, config CLEAN
- WebUI structure balanced (138/138)
- CI workflows (release + debug) audited against the tree — every validated file present, dev artifacts correctly excluded from the release package
- **249 files**, all on-disk learning growth-bounded

---

## V50

V48 made Smart Mode learn. V49 taught it to predict. **V50 makes it accountable** — for the first time the module measures its own results, forecasts your battery's survival instead of staring at a percentage, knows when to stop fighting the system, and grades every session with a number instead of a feeling. And it finally answers the most basic question honestly: *did that change make things better?*

---

### 🧠 Smart Mode — new intelligence

**Energy budget: survival forecasting.** Low battery used to mean one thing: a percentage threshold. Smart now asks the better question — *at the current measured pace, how many hours does this charge actually buy?* The screen-on drain rate feeds a live prediction; below 50% charge, graded pressure tiers engage at under 4 and under 2 predicted hours. 18% with a quiet evening ahead is no longer punished; 35% at gaming pace gets leaned on long before the old trigger. Predictions use the **current time-of-day bucket's** learned drain rate when it's confident, so a navigation hour and a reading hour no longer share one assumption. Escalates instantly, releases with a 2-minute dwell, disengages on charger, never weakens thermal or low-battery overrides.

**Session quality score 2.0.** Every learned session gets a 0–100 verdict — battery (measured drain), heat (peak temperature), stability (thermal entries, recoveries), and vendor-war (actual clamps per screen-on hour) — and names the worst component as the primary failure when it drops below 70. "Did that change help" is now a number in `learner_state.json` and the status snapshot, not an impression.

**Night window learner.** The fixed 23:00–06:00 night is gone as a hard assumption. The module learns your real bedtime and wake time from screen activity (EWMA over minute-of-day, midnight-wrap aware, debounced against 3 AM phone checks), and after a few nights the learned window drives both Night Quiet and Smart's sleep override. Go to bed at 2 and wake at 11 — ASB follows *you*.

**Charge-aware layer.** Plugged in with a cool battery and the screen on, drain stops mattering — Smart buys latency for free with a gentle performance lean. Screen off on the charger, there's nothing to be fast for — it leans cool so the pack charges at full negotiated rate. A hot pack while charging gets protective lean regardless. Resets cleanly every tick; nothing lingers after unplugging.

**Per-app heat *and* drain memory.** The persisted per-app table now remembers two things about every app: how hot it runs (drives the early predictive thermal lean — a known furnace gets leaned on from 40 °C instead of 45 °C) and how hard it drains (≥12%/h sessions bump the dominant app's drain score). Same 16-entry LRU, daily decay, no file-format change.

**Anomaly detector.** The governor diagnoses four failure modes itself instead of burying them in logs: sustained drain spike (≥25%/h), vendor clamp war (≥400/h), stuck on the battery profile past the restore threshold, and broken foreground-package detection. Current code and episode count are one `grep anomaly` away.

**Boot-settle posture.** The first 15 minutes after boot are always a storm of legitimate system work (media scan, sync, job rescheduling). During this window the predictive thermal lean uses early-engagement thresholds, keeping the post-boot warm-up shallow.

### 🔋 Battery fixes that matter daily

**Auto-battery → Smart restore: root cause fixed.** The headline V50 bug. When Smart dropped to the battery profile at low charge, charging back past the threshold never restored Smart. Three stacked causes, all fixed: the restore-state reload rejected exactly `PROFILE_SMART` on daemon restart; the state lived on tmpfs and died on reboot (now `/data/adb/asb/`); and as a final net, a battery profile + `smart_mode_enabled=1` + charge above threshold now triggers recovery even if the original intent was lost. Manual switches away from Smart properly clear the flag so the net never fights your choice.

**Daytime screen-off pockets.** Field data showed pocket time (2–25 min screen-off) drawing ~136 mA — seven times the overnight rate — because the idle lean only engaged after 30 minutes. A graded pocket tier now engages after 2 minutes; floors vanish instantly on wake.

**Cap-write churn eliminated.** ~940 cap writes per 4 daytime hours traced to Smart force-writing every few-MHz alpha jitter, with vendor re-clamping each one. Writes now require a ≥38.4 MHz (or 2% GPU) movement; thermal caps bypass the threshold. Fewer wakeups, less vendor war, cooler device.

**Sleep détente.** When the screen is off, the FSM is in deep idle, the SoC is cool, and *someone else* (vendor or shell) has owned the caps for 2+ minutes — ASB stops fighting and freezes cap writes entirely. Their idle clamps are lower than ours anyway; overriding them at 3 AM wins nothing. Exits instantly on wake or warming, with flap-proof hysteresis for everything else. The long-standing vendor-clamp holddown is also finally *enforced* in the write path (it was computed and displayed, but never consulted).

**Battery current telemetry fixed.** The kernel reports milliamps; the reader assumed microamps, so the sensor read 0–2 mA forever. Unit autodetection latches per boot; live currents now feed diagnostics and the unified battery forecast.

### 🚀 System & boot

**25–30 s boot delay and 30-minute post-boot heating — one bug, both fixed.** Three system.prop lines overrode dex2oat/runtime flags baked into ART's precompiled boot artifacts; the mismatch forced artifact re-verification on **every** boot and invalidated apps' compiled code, leaving a half-hour background dexopt storm after each reboot. The props are gone. (First reboot after updating regenerates artifacts once — then it's permanently back to normal.)

**Bluetooth: loud without clipping, stable without stutter.** The A2DP volume curve ran up to +6 dB *above* digital full scale at the top steps — pure clipping, zero added loudness; the curve now tops out exactly at 0 dB. Adaptive bitrate is re-enabled for LDAC/LHDC and six blanket `*.abr=false` overrides are removed: quality ceilings untouched, but the link now degrades gracefully under RF pressure instead of stuttering.

**GPS (Italy-tuned).** One `it.pool.ntp.org` instead of eight stacked NTP lines the HAL can't all use; MSB-only SUPL (dead MSA no longer delays assisted fixes); intermediate-fix threshold relaxed 10 m → 25 m for visibly faster first fixes in cities; XTRA CA path corrected from a desktop-Linux path to the Android system store.

**Clean uninstall, actually.** Every persistent write — ~19 `persist.*` props, Wi-Fi scan/wakeup settings, animation and touch-timeout settings, the Traceur disable, the forced Wi-Fi country code — now goes through the restore manifest, and uninstall replays it correctly around a Magisk timing trap (settings/pm restores are deferred to just after boot completes; prop restores run inline with persist-store-aware deletion).

**Release = debug.** The release binary used to ship with its log disabled — same brain, blind box. Both flavors now log identically (size-capped, tmpfs), decision logic is verified identical, and `build_flavor` in status proves which one is running. All on-disk learning data is growth-bounded: logs rotate at 400/256 KB, session history hard-trims to 500 sessions.

### 📊 WebUI & tooling

**Config page** (new): every important governor.conf switch — night quiet, sleep-schedule learning, charge-aware mode, auto-battery, audio EQ compatibility, background trim, animation/touch management — with plain-language descriptions of what each does and when it matters, saved to disk with a reboot prompt.

**Live page**: battery forecast unified with the action sheet (both now use the measured drain EWMA, labeled "(measured)", with an honest "(est.)" fallback — three disagreeing estimators became one); the scary "Surface 41 °C" tile relabeled "Hotspot · internal" (it's a board NTC near the charging circuitry by design — your actual shell temperature is the Skin tile); Smart learner panel shows the Smart teacher's confidence and sessions; headers aligned across all three pages.

**Report card**: every logkit capture (daily / sleep / gaming) ends with `_report_card.txt` — quality with named primary failure, budget prediction and source, clamp rate, détente activity, anomalies, sensor sanity, build flavor. Versions and nights compare by numbers.

**Sleep report v2**: the night verdict is measured on the *night* (sleep-core window), not poisoned by the morning wake tail — the same capture that used to read "override: POOR (19%)" now correctly reads 86–92% core firing. Comment lines no longer counted as data ticks; `governor_pid` probe fixed; `cap_verify` explains static-baseline vs dynamic Smart caps.

### 🧪 Quality gate

317+ unit assertions across two suites (0 failures), release+debug builds warning-clean, config lint clean, every shell script syntax-checked, package permissions verified — the regression suite grew with every field bug found this cycle, so none of them can silently return.

---

## V49

### Smoother unlock and app-open animations

On screen wake, the FSM previously stepped DEEP_IDLE → LIGHT_IDLE and only reached MODERATE on the next tick — a 2-second window where unlock and the first app-open animation ran on idle-level CPU/GPU caps, causing visible stutter.

V49 jumps straight to MODERATE on screen wake. CPU and GPU have headroom the instant the screen turns on, so unlock transitions and the first launch animation are smooth. The change applies to all profiles. A UI hold-down also keeps MODERATE-level frequencies through the end of an animation while the GPU still shows UI activity, so app-open transitions don't drop caps mid-frame.

### External equalizer compatibility

Reported by a user running Flow Equalizer over Bluetooth and car speakers: ASB's audio enhancements double-processed the signal, making the low end muddy and distorted.

V49 enables `AUDIO_EQ_COMPAT` by default in `governor.conf`. ASB skips its runtime DSP processing — UHQA upsampling and the high-quality resampler — so an external EQ app (Flow, Wavelet, Poweramp EQ) owns the signal without double-processing. The audio effects registry (including ViPER4Android support) and safe Bluetooth codec/offload props are left intact, so high-bitrate codecs, stable connections, and optional effect engines still work. Set `AUDIO_EQ_COMPAT=0` to restore the full ASB audio processing.

### Predictive thermal lean

Smart Mode previously reacted to temperature only by its level: a soft lean started at 50 °C and a hard veto fired at 65 °C. Now it also reacts to the heating *rate*. When the device is at 45 °C or above and warming at 3 °C/min or faster (measured over ≥30-second windows with smoothing, so sensor quantization and one-off spikes don't trigger it), the alpha bias leans toward battery proportionally — up to +120 at 12 °C/min — before any level threshold trips.

A fast ramp at 47 °C reliably predicts 55–60 °C within minutes on this SoC. Leaning slightly at the start of the ramp keeps the sustained temperature lower and avoids the abrupt cap drop the hard veto would otherwise cause — cooler and smoother at once. The lean only ever raises the battery bias, never weakens a safety override, decays automatically when the ramp stops, and stands down entirely while the hard veto holds. The window re-seeds after deep-sleep gaps so a slope is never computed across a pause.

### Critical battery tier

The low-battery override gains a second tier: at 10% or below while discharging, the forced battery lean rises from 800 to 900, network batching tightens further, and the interactive bonus caps at the night-override level. The same hysteresis applies — it releases at 40% or as soon as a charger is connected.

### Drain-rate closed loop

Smart Mode now measures the real screen-on discharge rate (% per hour, accumulated over discharge windows only) and feeds it into bucket learning as a closed feedback loop. Each bucket keeps a running average of its own typical drain; when a learned session drains noticeably faster than that bucket's norm (and the cause wasn't a thermal event, which already has its own stronger correction), the bucket's alpha leans toward battery. When sessions come in cleaner and lighter than the norm, alpha is allowed to drift back toward balanced. The setpoint is each bucket's own history, so a gaming-hour bucket is never punished for naturally draining more than a reading-hour bucket. Adjustments go through the same slow learning rate and clamps as every other signal, so the loop converges over days, not minutes. Sessions with under 10 minutes of screen-on discharge are ignored — battery percentage is too coarse for shorter windows.

### Per-app thermal profiles

The predictive thermal lean now learns which apps heat the device. When a fast temperature ramp (≥6 °C/min) is observed with a known foreground app, that app's heat score rises in a small persisted table (16 entries, LRU-evicted, scores decay daily). For apps that have proven themselves hot, the predictive lean engages earlier — from 40 °C instead of 45 °C and from a 2 °C/min slope instead of 3 — so a known heater like a heavy 3D game starts the cool-down bias in its loading screen rather than mid-match. Unknown apps keep the standard thresholds. The table persists across reboots alongside the bucket store.

### Fixed: false GAMING classification

Field logs showed the FSM entering GAMING from camera use, scrolling, and app animations: a single GPU spike above the gaming threshold held for just two polls (~4 seconds) was enough. GAMING entry now requires the GPU to stay above the threshold continuously for `gaming_confirm_ticks` polls (default 6, ~12 seconds at the active poll rate); until confirmed, high GPU load resolves to HEAVY, which carries near-identical caps. The streak survives brief dips down to the gaming exit threshold, so a real game's menu moments don't reset confirmation, and it resets on screen-off. This also stops Smart Mode from mislabeling everyday apps as gaming sessions in bucket learning.

### Fixed: Learner row showed the wrong learner

On the Smart profile, the WebUI Learner row displayed the battery-profile self-tuner (trust tier and battery session count), which only advances when the fixed battery profile runs — so a user living on Smart saw "unknown · 1 ses" forever while Smart's own learner was advancing normally. The row now shows the Smart learner when the Smart profile is active: a confidence tier (learning / active / strong), the confidence percentage, and the Smart session count. Other profiles keep the original display.

### Override observability

The status snapshot now reports `smart_lowbat_override`, `smart_thermal_trend` (the current predictive bump), `smart_trend_slope` (smoothed heating rate, m°C/min), `smart_drain_window_s` and `smart_drain_pctph_x10` (the live screen-on drain measurement feeding the closed loop), and `smart_app_hot` / `smart_appheat_n` (whether the current app is a known heater, and how many apps the heat table knows), so field logs show exactly when and how strongly each mechanism engaged.

### Fewer false "gaming" classifications

In day-to-day use, the foreground hint sometimes reported gaming when no game was open. Two causes fixed:

- The FSM-state gaming upgrade now requires a freshly detected package plus a true GAMING state, or SUSTAINED with both CPU ≥ 60 °C and GPU ≥ 30%. Heavy non-game workloads (compilation, heavy browser tabs) no longer get mislabeled.
- The package cache window dropped from 60 to 20 seconds, and a stale gaming/heavy hint decays one level while stale, so a closed game stops reporting gaming intent within seconds instead of a full minute.

### Field observability

Smart Mode trace logs (`smart_trace.tsv` from the logkit capture scripts) now record three extra columns:
- `pkg_detect_ok` — whether foreground package detection succeeded this tick
- `pkg_source` — which detection source won (1 = activity top, 2 = resumed activity, 3 = window focus)
- `cap_owner` — who effectively controls cpufreq caps (asb / shell / vendor / unknown)

These make it possible to diagnose package-detection gaps and vendor cap conflicts directly from a field log without a debug build.

### Build consistency

The local `make DEBUG=1` helper defined `-DASB_DEBUG`, but the source checks `ASB_DEBUG_BUILD`, so local debug builds silently compiled as release. Fixed to `-DASB_DEBUG_BUILD=1`, matching the CI build script. Note: the release and debug binaries differ only in diagnostic logging — the tuning and decision logic is identical, so a release install is exactly as adaptive as a debug install.

## Carried over from V48

Smart Mode is the adaptive layer over the three fixed profiles (battery / balanced / performance). It blends caps by time of day, foreground app, recent thermal behaviour, and learned per-daypart history.

- **seed_baseline** — daypart priors are honoured from first boot (25% influence at zero confidence, scaling to 100%). Full confidence in ~8 sessions.
- **Continuous learning** — bucket-rollover and 20-minute periodic triggers feed learning even without profile switches.
- **Foreground package detection** — cascading `dumpsys activity top` → `mResumedActivity` → `mCurrentFocus`, with a 60-second cache and system-UI filtering. Unknown packages classified by the FSM as GAMING/SUSTAINED are auto-upgraded.
- **Cap ownership + anti-thrash** — burst (3 clamps / 60 s) and slow-thrash (8 clamps / 5 min) detectors set a 15-second hold-down so ASB stops fighting vendor PowerHAL.
- **Smart session accounting** — dedicated `smart_sessions` block in `learner_state.json`.
- **Headroom trust** — `implausible_hot` invalidation when headroom reads ≥ 95% while CPU ≥ 60 °C.
- **Night-safe + idle-screen overrides** — battery-lean caps overnight (sleep/late/wake dayparts) and after 30 minutes of screen-off at any time.
- **Dynamic system tuning** — read-ahead, MGLRU, VM dirty ratios, swappiness re-applied on app/thermal/screen changes.
- **Animation scales opt-in** — ASB no longer touches Developer Options animation/timeout settings unless `UX_MANAGE_ANIM_SCALE` / `UX_MANAGE_TIMEOUTS` is set.

## Migration

V48 → V49 is in-place. Bucket store format unchanged; learned data carries over. Fresh installs enable Smart Mode by default; existing installs keep their current Smart Mode setting.

## File locations

| Path | Purpose |
|:--|:--|
| `/data/adb/asb/smart_mode_enabled` | Master on/off flag (0 or 1) |
| `/data/adb/asb/buckets.bin` | Persistent learned per-daypart store |
| `/data/adb/asb/session_history.jsonl` | Append-only session log (rotated at 5 MB) |
| `/dev/.asb/state` | Live key=value status, refreshed every tick |
| `/dev/.asb/learner_state.json` | Summary including `smart_sessions` block |
| `/dev/.asb/conflicts.json` | Vendor clamp and cap owner observability |
