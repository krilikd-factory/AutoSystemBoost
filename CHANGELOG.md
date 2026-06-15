# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V51-16a34a?style=for-the-badge" alt="V51">
  <img src="https://img.shields.io/badge/Previous-V50-6b7280?style=for-the-badge" alt="V50">
  <img src="https://img.shields.io/badge/versionCode-510-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

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
