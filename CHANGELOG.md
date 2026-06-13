# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V50-16a34a?style=for-the-badge" alt="V50">
  <img src="https://img.shields.io/badge/Previous-V49-6b7280?style=for-the-badge" alt="V49">
  <img src="https://img.shields.io/badge/versionCode-500-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

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
