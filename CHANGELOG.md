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
