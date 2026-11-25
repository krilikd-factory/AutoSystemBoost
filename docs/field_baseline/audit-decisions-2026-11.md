# ASB audit decisions — 25 November 2026

Audit applies to source commit `987f037273b29751957622654de2b1214b487c09`; later changes need independent review. Host and packaged-artifact checks do not prove physical-device behavior.

## Implemented

* M-01: test/release CI verifies its clean source checkout before build and compares a clean-unpacked flashable ZIP with its actual staged files and modes. It verifies the commit and the embedded payload, configuration and native-artifact hashes. These checks are independent of the historical `tools/asb_tree.sha256` and `docs/RELEASE_MANIFEST.json`, which describe an older delivered source archive, not current `main`. They do not claim source-to-binary reproducibility or that a device loaded a binary.
* M-02: an advisory reports public OTA metadata alongside source version and flags malformed or cross-repository URLs. `update.json` is not modified; a newer test version than public OTA is expected. A warning is not proof that the old URL fails.
* Field matrix: `validation-matrix.md` defines the evidence to collect for recovery, energy and performance, with uncertainty and privacy safeguards. It is not evidence that any device tests ran.

## Agree, conditional or further work

* M-03, M-04 and M-06: a worker inventory, measurements, explicit ownership, restore readback and bounded conflict handling are valuable. A wholesale scheduler or writer migration would change timing, power and recovery on real phones and requires measured baseline, failure-injection tests and a controlled rollout; a passive host-only estimate would not establish CPU, wakeups, forks or energy per feature.
* M-05: retain capability gating and avoid extending vendor camera/audio settings without per-device evidence. Do not claim that readback alone demonstrates effect or that a property is ineffective. Changing existing proven and unproven settings wholesale requires a per-build inventory and phone testing.
* N-01–N-04, WebUI and reporting: reducing warning debt, profiling real WebView and improving prioritized evidence are worthwhile, but numerical gains, UI budgets and energy impact require measurement; avoid breaking restore behavior or creating new polling just to report its cost. Locale data is already separated, and there is existing lazy/visibility logic.
* P1/P2 ideas on adaptive governance, thermal slope, radio, VM, game and camera policies are hypotheses, not demonstrated improvements; validate data quality, causal effect, ownership and fallback per device before enabling them.

## Disagreement / qualification

* A single generic deadline scheduler is not automatically lighter or safer: consolidating independent lifecycle and failure domains can create a new single point of failure. Measure workers first and migrate only where evidence supports it.
* A universal screen-off/deep-idle ban on diagnostics or maintenance would invalidate explicit user-requested captures and may break required functionality. Classify work by purpose and user consent, then measure and bound it.
* Adding every proposed field or assigning per-feature energy without a reliable source would imply accuracy the system does not have. Report unknown rather than inventing estimates.
* Requiring specific hardware/root combinations as an unconditional automated gate is not possible without access to them. They are release evidence requirements, not claims of tests completed here.
* Resetting Smart learning on every fingerprint change can discard useful data after harmless updates; decide invalidation using measured compatibility and preserve an export/rollback path.

Existing OTA publication rules remain unchanged: do not point public metadata to a V66 asset before that asset exists. The changelog URL still needs a release-owner review.
