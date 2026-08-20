# AutoSystemBoost — V63 Release Notes

<p align="center">
  <img src="https://img.shields.io/badge/Release-V63-16a34a?style=for-the-badge" alt="Release V63">
  <img src="https://img.shields.io/badge/Previous-V62-6b7280?style=for-the-badge" alt="Previous V62">
  <img src="https://img.shields.io/badge/versionCode-630-0ea5e9?style=for-the-badge" alt="versionCode 630">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OnePlus%2015-canoe-ef4444?style=flat-square" alt="OnePlus 15">
  <img src="https://img.shields.io/badge/OnePlus%2013-sun-f59e0b?style=flat-square" alt="OnePlus 13">
  <img src="https://img.shields.io/badge/OnePlus%2012-pineapple-eab308?style=flat-square" alt="OnePlus 12">
  <img src="https://img.shields.io/badge/Ace%205%20%2F%20Ace%206-SM8650%20%2F%20SM8750-14b8a6?style=flat-square" alt="Ace 5 and Ace 6">
  <img src="https://img.shields.io/badge/Policy-capability--gated-8b5cf6?style=flat-square" alt="Capability-gated policy">
</p>

> **V63 is the largest ASB refinement since V62.** It adds new user controls for sleep, GPS, wake-locks, networking and performance; a tiered thermal-budget engine; safer device-specific gating; and an evidence chain that explains every major decision. V63 is designed to reduce unnecessary heat and energy use **without replacing required performance with blind caps**.

> Actual battery-life gains depend on display time, signal quality, applications, Bluetooth/audio route, ambient temperature and the length of true screen-off periods. V63 therefore reports its evidence instead of promising one fixed percentage for every device.

---

## V62 → V63 at a glance

| Area | V62 release baseline | V63 release improvement | Practical result |
|---|---|---|---|
| **Thermal control** | Device-aware limits, but no P0 validation of an implausible selected thermal source. | Validates `socd` against CPU peers, falls back to a real CPU zone, records confidence and revalidates the primary source. | A false vendor thermal report cannot become a fake 90–95°C governor input. |
| **Performance tuning** | Per-device frequency scaling and profile limits. | Adds **Performance Ceiling** (60–100%), a tiered thermal budget and optional Observe / Shadow mode. | Users can trade peak headroom for cooler, calmer sustained use without fixed model tables. |
| **Sleep-side power** | Quiet Night and V62 Doze controls. | Adds **Act on Wakelocks**, **Trim Background GPS**, **Quiet Radio at Night** and screen-off classification. | V63 can identify or selectively address the app/radio work that prevents real sleep. |
| **Networking** | Network buffers, qdisc and restore-aware baseline. | Adds **Spread Network Load** (RPS) and **Transmit Queue** controls. | Fast Wi-Fi can distribute softirq work; loaded wireless links can reduce queueing latency. |
| **Audio / DSP** | V62 repaired DSP routing and output safety. | Adds route-aware offload evidence, Bluetooth reconnect trace and conflict-first audio verdicts. | DSP remains usable while diagnosis stops making unproven offload claims. |
| **Multi-device safety** | V62 removed fixed OP15 frequency assumptions. | Adds capability manifest, device tiers, exact-fingerprint property domains and lease arbitration. | Unknown devices degrade safely instead of receiving copied property packs. |
| **Configuration writes** | Validated config updates. | Adds atomic linked thermal writes, config backup/preview, writer provenance and legacy-state recovery. | New controls and valid slider values work even after an older retained config. |
| **Upgrade path** | Config schema 17. | Tested schema-17 → schema-18 additive migration with backup and idempotence. | A V62 update preserves existing choices and adds V63 controls safely. |
| **Release build integrity** | A release-only pre-build check could require the next GitHub release asset before the first build produced it; selective packaging could also omit a tool that ZIP validation required. | `update.json` is strictly post-build OTA metadata, while the release package contract now proves that every required `tools/` runtime helper is copied back after the developer-tool exclusion. | The first V63 build has no dependency on a future asset or manifest contents, and required diagnostic/runtime tools cannot silently disappear from the flashable ZIP. |

---

# New V63 tweaks and controls

## Battery, heat and performance

### Performance Ceiling

**New WebUI control:** `Performance Ceiling` (`perf_ceiling_pct`, 60–100%, default 100%).

This is a proportional ceiling over the profile’s own device-correct CPU/GPU limits. It does **not** substitute one fixed frequency table for all phones and it does not raise the profile floors that keep scrolling and audio responsive. For example, 90% is a mild everyday reduction; 75% is an explicit battery-first trade-off for travel or light use.[1]

| Setting | What V63 changes | Safety boundary |
|---|---|---|
| `100%` | Keeps the selected profile’s normal limits. | Default; no extra ceiling. |
| `95–90%` | Applies a modest proportional cap. | Suitable for calmer everyday use when peak benchmark speed is not needed. |
| `85–75%` | Applies a clearer sustained-performance trade-off. | Better suited to travel, charging or battery-first intent. |
| `70–60%` | Strong conservative cap. | Available only as an intentional user choice; it is not selected silently. |

### Adaptive Thermal Budget — enabled by default

V63 adds a **tiered thermal-budget engine**, operating before the hard thermal cap is raised. It evaluates available thermal headroom, skin trend, temperature rise rate and battery-current evidence. Instead of jumping directly from unrestricted performance to a hard restriction, it can apply a light, moderate or severe trim and holds that choice for a dwell interval to avoid oscillation.[2]

The shipped policy is deliberately bounded:

| V63 thermal-budget control | Default | Purpose |
|---|---:|---|
| `thermal_budget_enable` | `1` | Enables adaptive pre-cap response. |
| `thermal_budget_light_headroom_pct` / `thermal_budget_light_trim_pct` | `70%` / `8%` | First gentle response while headroom is narrowing. |
| `thermal_budget_moderate_headroom_pct` / `thermal_budget_moderate_trim_pct` | `45%` / `18%` | More visible response for sustained pressure. |
| `thermal_budget_severe_headroom_pct` / `thermal_budget_severe_trim_pct` | `25%` / `32%` | Conservative response before hard thermal protection dominates. |
| `thermal_budget_dwell_s` | `30 s` | Prevents caps from rapidly moving up and down. |

Camera activity receives special treatment: a light budget response is not allowed to undermine a protected camera deadline. Hard thermal safety and platform thermal limits always retain priority.

### Observe / Shadow mode and intent presets

V63 introduces `shadow_mode`: ASB calculates and records its policy decision but avoids policy writes. It is intended for diagnosis and validation before a new policy is trusted on a device. This is available through the `observe` intent preset rather than as an aggressive default.[3]

The new `asb_intent.sh` helper supplies safe-writer-backed presets for **daily**, **camera**, **game**, **travel**, **charging** and **observe**. Presets use already validated V63 knobs; they do not edit `governor.conf` directly or bypass its full semantic validation.[3]

---

## New sleep, GPS and wake-lock controls

### Act on Wakelocks

**New WebUI control:** `Act on Wakelocks` (`wakelock_action`, default off).

V63 always observes significant wake sources when the kernel exposes them. When this control is enabled, an application must satisfy multiple safeguards before V63 acts: it must be user-installed, hold a relevant partial wakelock through a long screen-off interval, and the device must demonstrably remain awake. The action is Android’s reversible **restricted** bucket; V63 does not force-stop the app and never targets kernel/system sources, the modem, display, alarms, sensors, authenticator, dialer, SMS, messaging or clock apps.[4]

### Trim Background GPS

**New WebUI control:** `Trim Background GPS` (`gnss_trim`, default off).

V63 targets a narrow case: a third-party app that continues holding location while **cached** and screen-off. It limits that app to coarse location only while the condition persists. Foreground use, navigation, fitness/route tracking, emergency/finding functions and protected classes are excluded. Permissions are not revoked; full access returns when the app leaves the cached state, and all ASB restrictions are restored when the control is disabled or ASB is removed.[5]

### Quiet Radio at Night

**New WebUI control:** `Quiet Radio at Night` (`night_modem_idle`, default off).

This control works inside the learned/configured night window and only while screen-off. It changes keepalive/probe timing so fewer background sockets wake the modem path. It does **not** power the radio off, and it does not suppress calls, SMS or high-priority push. The explicit trade-off is that a polling application can be later until morning; users who rely on polling instead of push should leave it disabled.[6]

### Screen-off classifier

V63 adds a read-only `asb_screenoff_class` observer. It distinguishes genuine sleep from screen-off audio, VPN/tunnel activity, GNSS-held work, charging and other confounders before anyone attributes drain to CPU policy. The classifier writes no system node and changes no user policy in this release cycle.[7]

---

## New network controls

### Spread Network Load

**New WebUI control:** `Spread Network Load` (`net_rps`, default `stock`).

V63 can direct receive-packet work to the efficiency cluster (`little`) or all available cores (`all`) when the device exposes the relevant queue nodes. On high-throughput Wi-Fi, this can prevent one core from being pinned by softirq work. On a slow link, waking extra cores can cost more energy than it saves, which is why stock remains the default and “prime-only” steering is intentionally not offered.[8]

### Transmit Queue

**New WebUI control:** `Transmit Queue` (`net_txqueue`, default `stock`).

The new choices are `short` (256) and `shorter` (128), alongside stock behaviour. They are aimed at reducing bufferbloat and loaded-link latency, not at claiming guaranteed higher throughput. V63 captures previous values before change and restores them when the control returns to stock.[8]

### Network safety and diagnostics

Network writers act only on real, active interfaces with writable queues. V63 records the applied result rather than assuming a driver accepted the request. Existing route/buffer/qdisc controls remain available and restore-aware; the new RPS and queue controls complement them instead of replacing them.

---

## Thermal-source safety and cross-device correctness

### A bad `socd` sensor cannot become a false governor input

Some devices expose a thermal zone named `socd` whose value may diverge sharply from actual CPU zones. V63 checks a selected `socd` against validated CPU peers. It rejects a source that is more than **25°C above** the peer median or **12°C or more below** it. When a valid peer exists, ASB uses that **real CPU sysfs zone** as the control path; it does not invent a median with no readable path.[9]

A valid `socd` retains priority and receives peer-checked confidence. If no usable fallback exists, V63 stays conservative and reports low confidence rather than pretending the sensor is validated. V63 also revalidates a primary `socd` every 60 seconds, allowing recovery from transient vendor-reporting faults.[9]

### Provenance everywhere it matters

The following fields are now available through `/dev/.asb/state`, native status JSON, effective-policy JSON, `asbdiag` and full-day logkit:

| V63 field | Meaning |
|---|---|
| `thermal_control_source`, `thermal_control_zone` | The actual sensor path controlling ASB thermal policy. |
| `thermal_source_confidence` | Uninitialized, fallback/unvalidated or peer-checked source confidence. |
| `thermal_rejected_type`, `thermal_rejected_raw` | Evidence for a rejected candidate; raw values are not rendered as degrees. |
| `startup_quarantined` | Early boot samples excluded from Smart learning. |
| `battery_window_confidence`, `battery_window_reason` | Explains whether a drain window is trustworthy; charging invalidates discharge confidence. |

This is a major cross-device improvement: a field log can now distinguish a bad sensor, a platform clamp, a real ASB trim, audio work or a radio issue before anyone changes a policy.

---

## Capability-gated multi-device architecture

V63 does not copy a generic “tweak pack” to every Snapdragon phone. It introduces several layers that decide what can actually be justified on the current device:

| V63 subsystem | Function | Why it matters |
|---|---|---|
| **Capability Manifest** | Read-only probe of CPU policies, OPP availability, cgroup/uclamp, thermal, GPU, camera and battery-current paths. | A node existing is not treated as proof it is safe to write. |
| **Device Tier / Device Pack** | Unknown devices stay generic; mutable vendor domains require a validated exact build fingerprint. | An OTA or similar model name cannot silently authorize stale properties. |
| **Managed Properties** | Optional property blocks are applied only after feature and device-domain validation. | Properties are no longer loaded blindly at boot through a global `system.prop` payload. |
| **Lease Arbiter** | Coordinates baseline, Smart, profile, user cap, camera, safety and platform thermal priority. | Competing writers can back off instead of fighting the same node. |
| **Effective Policy** | Read-only machine-readable view of applied config, capability/tier context, energy policy and transaction provenance. | Support can inspect what ASB can actually justify, not only selected UI values. |

> **No AIST/SysTwks-style property bundle, global sysctl pack, `swapoff`, zram recreation or conflicting audio overlay was imported into V63.** Optional mechanisms are capability-gated, owned, recorded and reversible.

---

## Audio, DSP and Bluetooth diagnostics

V63 keeps the working AIDL DSP path while making audio evidence substantially more reliable.

The full-day recorder now captures route context, AudioFlinger evidence, relevant platform/vendor offload properties and Bluetooth reconnect evidence with MAC redaction. Its verdict is conservative by design: an offload/compress thread is not claimed to belong to active Bluetooth playback unless route evidence supports that conclusion. Conflicting property evidence wins over an optimistic observation.[10]

DSP output restrictions continue to prevent headphone-oriented processing from unintentionally boosting speakers. DSP source checks remain part of both workflows.[11]

---

## Configuration reliability, backup and recovery

### Atomic safe writer with transaction provenance

`runtime/asb_config_safe.sh` is the only runtime writer for `governor.conf`. Every change is staged, validated as a complete config and atomically renamed. Transactions now record a stable result class, reason, key, pre/post epoch and honest reload status. The state path is injectable for staging/host tests while production remains at the normal device location.[12]

### Three important WebUI/update fixes

| Fixed case | V63 resolution |
|---|---|
| Valid 69–70°C throttle slider update could leave `ceiling < enter`. | Slider writes `enter`, matching `ceiling` and manual mode in one atomic transaction. |
| A retained older config did not contain a newly added V63 key. | Writer accepts a key known to either the active config or the current shipped schema; arbitrary keys remain rejected. |
| An old inverted thermal pair blocked every unrelated write. | A narrow, logged legacy recovery aligns an in-range ceiling to the existing `enter` value, then applies normal validation. Explicit invalid thermal edits still fail. |

When the last recovery is used, `recovery=legacy_thermal_ceiling` appears in the transaction sidecar, effective policy and diagnostics. No hidden policy repair occurs without evidence.

### Backup, import preview and Smart reset

V63 adds a versioned config-backup tool with checksum and import preview. The preview uses the same config validation surface without changing the active config. V63 also adds **Smart Learning Reset**, which clears only learner-owned history, buckets and night-window data; it leaves configuration, baselines and uninstall/restore records intact.[13]

---

## Complete V63 configuration additions

V63 adds **15 configuration keys** over the public V62 release. The visible controls are marked below; advanced keys are shipped with bounded defaults and validated by both shell and native config contracts.

| Group | New V63 keys | Default / availability |
|---|---|---|
| **Performance** | `perf_ceiling_pct` | **WebUI:** 100%; 60–100% in 5% steps. |
| **Sleep / app work** | `wakelock_action`, `gnss_trim`, `night_modem_idle` | **WebUI:** all default off; explicitly opt-in. |
| **Networking** | `net_rps`, `net_txqueue` | **WebUI:** both stock by default. |
| **Adaptive thermal budget** | `thermal_budget_enable`, `thermal_budget_dwell_s`, `thermal_budget_light_headroom_pct`, `thermal_budget_light_trim_pct`, `thermal_budget_moderate_headroom_pct`, `thermal_budget_moderate_trim_pct`, `thermal_budget_severe_headroom_pct`, `thermal_budget_severe_trim_pct` | Enabled with bounded 3-tier defaults and 30-second dwell. |
| **Advanced diagnostics** | `shadow_mode` | Default off; used by the Observe intent for calculate-and-log behaviour. |

---

## Updating from V62

Updating from V62 is supported and permanently tested. V62 uses config schema **17**; V63 uses schema **18**.

| Upgrade step | V63 behaviour |
|---|---|
| Existing profile | Preserved for an in-place update. |
| Existing `governor.conf` | Preserved as the user’s authoritative configuration. |
| Backup | `governor.conf.bak.schema17.<timestamp>` is written before boot-time merge. |
| Duplicate legacy records | The first historical value is retained; duplicates are removed so shell and native readers cannot diverge. |
| New V63 values | The 15 missing V63-only keys are added from `governor.conf.shipped`. |
| Existing V62 choices | Retained; V63 does not silently replace them with new defaults. |
| Schema marker | Moves to 18 only after successful migration. |
| Next boot | Migration is idempotent; schema 18 is a no-op. |

The permanent V62→V63 contract tests backup creation, additive merge, absence of duplicate keys, idempotence and a post-migration safe-writer update. It is mandatory in both `build-release.yml` and `build-debug.yml`.[14]

---

## Release validation

| Gate | V63 public release result |
|---|---|
| V62 schema-17 → V63 schema-18 migration contract | **PASS** |
| Native thermal `socd` high/low/fallback/recovery fixtures | **PASS** |
| Atomic config-writer, thermal-slider and legacy-recovery contracts | **PASS** |
| P0 state / effective policy / logkit provenance contract | **PASS** |
| DSP source contract | **PASS** |
| Schema synchronisation and source lint | **0 errors** |
| Native strict-warning budget | **79 / 79 baseline** |
| `tools/asb_diag.sh` and `system/bin/asbdiag` | **Byte-identical** |
| V62 migration test in debug and release workflows | **Mandatory** |
| Shared `update.json` / `module.prop` metadata validator | **Mandatory in debug and release**; stale release metadata is rejected before compile. |

---

## What to expect after updating

V63 should feel **more controlled and more explainable**, not artificially more aggressive. On a device with correct thermal reporting, behaviour remains close to V62 while diagnostics and adaptive policy improve. On a device with a bad `socd` report, V63 prevents false thermal restriction and uses a real CPU thermal path when one is available.

The new sleep controls are intentionally opt-in. Quiet Radio, Background GPS Trim and Wakelock Action can be valuable when a full-day report shows the matching cause, but they are not marketed as universal magic switches. A proper overnight conclusion needs a continuous multi-hour screen-off capture with radio, audio and location context.

---

## V62 historical foundation

V62 remains the foundation for V63. It introduced a clean-install-safe posture, device-native frequency cap scaling, profile-aware uclamp control, screen-off quieting, bounded camera hold, video-aware GPU limits, safer DSP routing, robust settings read-back, 11-language WebUI coverage and a complete `asbdiag` diagnostic path.

V63 builds on that work with **new controls, adaptive thermal budgeting, evidence-first diagnostics, capability-gated multi-device safety, configuration recovery and a verified public upgrade path**.

---

## References

[1]: ./runtime/profile_core.sh "Profile-scaled performance ceiling"
[2]: ./src/asb_governor.c "Tiered thermal-budget policy"
[3]: ./tools/asb_intent.sh "Validated V63 intent presets"
[4]: ./runtime/asb_wakelock_watch.sh "Wakelock observation and safe action contract"
[5]: ./runtime/asb_gnss_trim.sh "Background GNSS trim safety conditions"
[6]: ./webroot/index.html "Quiet Radio at Night user contract"
[7]: ./runtime/asb_screenoff_class.sh "Observe-only screen-off classifier"
[8]: ./runtime/asb_net_offload.sh "RPS and transmit-queue controls"
[9]: ./src/asb_metrics.h "Thermal-source validation and fallback"
[10]: ./tools/logkit/_asb_logkit_common.sh "Audio/offload and Bluetooth provenance"
[11]: ./tools/dsp_stubs/asb_dsp_syntax_check.sh "DSP source contract"
[12]: ./runtime/asb_config_safe.sh "Atomic configuration writer"
[13]: ./tools/asb_config_backup.sh "Backup and import preview" 
[14]: ./tests/test_v62_to_v63_migration.sh "V62 to V63 migration regression contract"
