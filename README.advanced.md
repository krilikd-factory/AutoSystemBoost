<p align="center">
  <a href="README.advanced.md"><img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English"></a>
  <a href="README.advanced.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">AutoSystemBoost — Advanced Guide</h1>

<p align="center">
  <img src="https://raw.githubusercontent.com/krilikd-factory/AutoSystemBoost/main/banner.png" alt="AutoSystemBoost" width="82%">
</p>

<p align="center"><strong>Architecture, policy ownership, Smart evidence, complete controls, diagnostics and source validation.</strong></p>
<p align="center">For advanced users, testers, reviewers and developers who need to know not only what ASB changes, but also when it refuses to change anything.</p>

<p align="center">
  <img src="https://img.shields.io/badge/GOVERNOR-6%20STATES-0f766e?style=for-the-badge" alt="Six governor states">
  <img src="https://img.shields.io/badge/BOUNDS-SCHEMA%203-0ea5e9?style=for-the-badge" alt="Bounds schema 3">
  <img src="https://img.shields.io/badge/WEBUI-84%20CONTROLS-dc2626?style=for-the-badge" alt="Eighty-four WebUI controls">
  <img src="https://img.shields.io/badge/EVIDENCE-FIRST-16a34a?style=for-the-badge" alt="Evidence first">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/SMART-12%20SCENARIO%20BUCKETS-7c3aed?style=for-the-badge" alt="Twelve Smart scenario buckets">
  <img src="https://img.shields.io/badge/FALLBACK-5%20LEVELS-2563eb?style=for-the-badge" alt="Five fallback levels">
  <img src="https://img.shields.io/badge/LEARNING-BOUNDED-475569?style=for-the-badge" alt="Bounded learning">
</p>

<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🚀_Quick_Start-16a34a?style=for-the-badge&logo=github&logoColor=white" alt="Quick start"></a>
  <a href="README.advanced.md"><img src="https://img.shields.io/badge/🧠_Advanced_Guide-0f766e?style=for-the-badge&logo=github&logoColor=white" alt="Advanced guide"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺_Быстрый_старт-1f2937?style=for-the-badge&logo=github&logoColor=white" alt="Быстрый старт"></a>
  <a href="README.advanced.ru.md"><img src="https://img.shields.io/badge/🇷🇺_Подробное_руководство-334155?style=for-the-badge&logo=github&logoColor=white" alt="Подробное руководство"></a>
</p>

## 📖 1. Purpose and reading contract

This guide describes the current architecture and operational model of ASB. It is intentionally not a release history: implementation details belong here when they help someone configure, test, diagnose or review the module safely.

The short [README.md](README.md) is the normal entry point. This document assumes that the reader understands root modules, Android system properties, sysfs, basic shell commands and the difference between a requested value and an observed value.

| Term | Meaning in this guide |
|:---|:---|
| **Requested** | What a profile, user setting or native governor asked the system to use. |
| **Effective / observed** | What the relevant interface reports after the request. A successful write syscall alone is not sufficient proof. |
| **Owned** | A setting for which ASB has a defined writer, baseline and restore path. |
| **Vendor-limited** | The firmware, PowerHAL, thermal engine or another platform owner currently imposes a different value. |
| **Not exposed** | The expected evidence or interface was not available through the paths ASB can inspect. It does not prove that the hardware lacks the capability. |
| **Unknown** | There is not enough reliable evidence to make a claim. Unknown is a valid diagnostic result. |
| **Not runtime-discoverable** | The capability cannot be established reliably from the current runtime interfaces. It must not be replaced with a guessed value. |
| **Baseline** | The pre-ASB value saved so an owned setting can be restored rather than left modified. |

> **Central rule:** absence of read-only evidence is not evidence of absence. ASB must not turn an unreadable interface into a confident “unsupported”, “active” or “stock” claim.

## 🧭 2. Design principles

ASB combines a native performance governor, shell runtime appliers, a WebUI, optional audio components and on-demand diagnostics. These pieces share configuration and evidence, but they are not interchangeable owners of the same setting.

| Principle | Practical consequence |
|:---|:---|
| 🧭 **One defined owner per policy path** | Shell and native code do not continuously fight over the same node. Ownership and handover are explicit. |
| 🌡 **Platform thermal protection outranks tuning** | ASB does not disable vendor thermal protection to obtain a benchmark result. A stricter platform clamp can win. |
| 🔍 **Device-derived capabilities** | Frequency bounds and exposed interfaces are discovered on the running device, not copied from an unrelated SoC. |
| 🧪 **Evidence before success** | Diagnostics distinguish selected, written, observed, refused, unavailable and unknown states. |
| 🧠 **Bounded learning** | Smart uses validated windows and gates; a log hint does not become a second settings writer. |
| 🔋 **Profiles remain different** | Battery has its own efficiency policy. It is not silently converted into Smart, and Performance is not a universal literal-kHz recipe. |
| 🕵 **On-demand detailed collection** | Extended captures start when the user asks. Device inventory is read-only and does not gain a permanent polling collector. |
| 🔐 **Data minimisation** | Serial numbers, IMEI, account data and network identifiers are not needed for diagnostics and are not collected for reports. |
| ↩️ **Reversibility** | Baselines, apply records and restore logic are part of the feature, not an afterthought. |
| 📦 **Patch-based module delivery** | The module patches or overlays exposed behaviour through root-module mechanisms; it does not need to embed arbitrary APK files to implement these policies. |

## 🏗️ 3. High-level architecture

| Layer | Main responsibility | Representative sources |
|:---|:---|:---|
| **Module lifecycle** | Installation, boot sequencing, update handover, stock restoration and uninstall. | `customize.sh`, `common/install.sh`, `post-fs-data.sh`, `service.sh`, `uninstall.sh` |
| **Profile policy** | Profile selection, range generation, manual appliers and Stock handover. | `apply_profile.sh`, `profiles/`, `runtime/profile_core.sh`, `runtime/asb_stock_policy.sh` |
| **Device-adaptive bounds** | Read-only discovery, topology identity, OPP-aware synthesis and stale-evidence rejection. | `tools/asb_discover.sh`, `tools/asb_synthesize_bounds.sh`, `runtime/asb_device_bounds.sh` |
| **Native governor** | Metric sampling, finite-state selection, thermal response, Smart evaluation and owned writes. | `src/asb_governor.c`, `src/asb_fsm.h`, `src/asb_writer.h`, `src/asb_smart.h` |
| **Zygisk observer + lifecycle refresh** | Opt-in process start/disconnect telemetry; separately enabled, rate-limited requests make only the existing governor refresh evidence. | `src/zygisk/`, `runtime/asb_zygisk.sh`, `runtime/asb_zygisk_info.sh` |
| **Runtime feature appliers** | Audio, network, Doze, interface, camera, background and vendor-facing controls. | `runtime/asb_*.sh` |
| **WebUI and action interface** | User controls, live monitor, named configurations, device facts, reports and apply feedback. | `webroot/index.html`, `action.sh`, `webroot/config.json` |
| **Audio DSP** | Optional processing chain, route selection, live parameters and audio-effect integration. | `src/DSP/`, `src/DSP_AIDL/`, `runtime/asb_dsp_*.sh` |
| **Diagnostics** | Effective-state inspection, support reports, field captures and comparison tools. | `tools/asb_diag.sh`, `system/bin/asbdiag`, `tools/logkit/`, `tools/*report*.py` |
| **Regression and delivery checks** | Native, shell, WebUI, source-tree and packaging verification. | `tests/`, `tools/asb_full_regression.sh`, `tools/asb_source_regression.sh`, `tools/asb_tree_check.sh` |

The native governor is a running policy component. That must not be confused with the diagnostic collection model: a persistent governor does not imply a persistent extended-log recorder or device-inventory worker.

## 📦 4. Installation, update and removal model

### 🚀 4.1. Normal installation

1. Install the regular release ZIP with Magisk, KernelSU, APatch or a supported derivative.
2. Reboot so boot-time mounts, native components, audio integration and generated device policy can be initialised in the intended order.
3. Open the WebUI and select a profile.
4. Leave optional controls at their defaults until a baseline has been observed.
5. Use **Action**, **Monitor** or `asbdiag` if a requested setting does not appear to take effect.

Do not install several ASB packages in parallel. A test build replaces the existing module through the manager's normal update mechanism.

### 🗄️ 4.2. Settings and learning are different state

ASB keeps user configuration, active-profile information, native learning, generated device bounds, baselines and diagnostic state as separate concepts. This separation matters:

- resetting configuration should not silently become a request to erase every learned observation;
- resetting Smart learning should not be necessary to change an ordinary audio or network option;
- an update can migrate compatible configuration while rejecting stale device evidence;
- a saved configuration is not proof that every option will be supported on another phone;
- a profile selection does not automatically undo unrelated explicit tweaks.

The WebUI provides named configurations, backup/export and separate reset actions. Use a backup before broad experiments, and record the firmware and root environment alongside a test capture.

### ↩️ 4.3. Stock and uninstall are not identical operations

**Stock** withdraws ASB's active profile policy and returns the relevant performance decisions to the ROM. It is useful for A/B comparisons, but a user-selected DSP, camera, network or interface option may still be an independent configuration choice.

**Uninstall** runs the module's restoration path for settings ASB owns. Baselines and ownership records are used to avoid restoring a value over a newer unrelated change blindly. After removal, a reboot is the cleanest way to return mount- and boot-integrated behaviour to the stock environment.

## 🎯 5. Profiles and policy composition

A profile is more than a single CPU maximum. Depending on the exposed device interfaces and user configuration, policy can involve per-policy CPU ranges, GPU behaviour, scheduler utilisation clamps, memory/VM behaviour, thermal response, background policy and other owned controls.

| Profile | Policy intent | Important boundary |
|:---|:---|:---|
| **Smart** | Select and refine behaviour using current workload, scenario history, smoothness, battery and thermal evidence. | Learning never outranks thermal safety, stale-evidence rejection or platform ownership. |
| **Performance** | Preserve high responsiveness and headroom for demanding work. | It does not disable thermal protection or guarantee the hardware maximum in every state. |
| **Balanced** | Provide predictable daily responsiveness with moderate efficiency. | It is not simply Smart with learning disabled; its policy ranges and behaviour are defined separately. |
| **Battery** | Reduce unnecessary peaks and prefer endurance and lower heat. | Its jank guard is bounded insurance, not a second Smart learner. Heavy work may be slower by design. |
| **Stock** | Restore the ROM-controlled policy baseline for comparison or troubleshooting. | It does not mean that every independent optional tweak has been reset to its default. |

### 📉 5.1. Performance ceiling

`perf_ceiling_pct` provides a user-level upper bound on the selected performance policy. It is an additional constraint, not a demand that every cluster always run at that percentage.

The final effective value can be lower because of:

- the profile's own state-dependent range;
- thermal budget or sustained-state policy;
- a vendor clamp;
- a missing or read-only interface;
- an OPP table that does not contain the exact requested frequency;
- another explicit safety gate.

When a value must be snapped to a real OPP table, ASB uses a conservative ceiling rule rather than rounding upward beyond the requested cap.

### 🔀 5.2. Profile switches and transient state

A profile switch can involve several ordered operations: stop or hand over native policy, apply the new ranges, reconcile runtime appliers, publish state and verify effective values. A diagnostic snapshot taken during this interval can be transient.

If `asbdiag` indicates that switching is still in progress, wait for the operation to settle and capture again. Do not infer a permanent ownership conflict from one intermediate sample.

## ⚙️ 6. Native governor

### 🎚️ 6.1. Six states

The governor uses a finite-state model. A state describes the current operating situation; it is not another user-facing profile.

| State | Operating meaning | Typical policy direction |
|:---|:---|:---|
| `DEEP_IDLE` | Screen-off idle or another situation satisfying the deep-idle gates. | Minimise unnecessary performance and background cost without misclassifying active audio, navigation, charging or VPN work as sleep. |
| `LIGHT_IDLE` | Low-intensity screen-on activity or light background work. | Preserve basic responsiveness while avoiding an unnecessary high rail. |
| `MODERATE` | Ordinary interactive work, application activity or moderate sustained load. | Provide useful headroom without treating every burst as gaming. |
| `HEAVY` | Significant CPU/GPU-backed work that does not satisfy the full gaming contract. | Raise available performance while retaining thermal and vendor limits. |
| `SUSTAINED` | Prolonged demanding work or a thermal condition that calls for a sustainable rail. | Trade short-lived peaks for stable performance and controlled heat. |
| `GAMING` | A game/application hint plus corroborating workload evidence. | Prioritise interactive performance; Battery can deliberately suppress this state. |

A high GPU reading alone is not necessarily enough to declare gaming. Likewise, a game hint without sufficient load can be promoted to a heavy state rather than receiving an unconditional maximum-performance policy.

### 🛰️ 6.2. Inputs and corroboration

The governor can combine several classes of metrics:

- per-policy CPU frequency and utilisation-related information;
- system load and core-pressure signals;
- GPU activity where the platform exposes a meaningful interface;
- screen state, touch/launch activity and application hints;
- battery level, charging state and drain-related evidence;
- thermal zones, vendor clamp evidence and sensor-confidence metadata;
- camera/media state and other scenario gates;
- native frame/smoothness records and bounded feedback from the existing log path.

Inputs are validated before arithmetic or policy use. Missing counters, implausible deltas, stale samples and unsupported interfaces must not be converted into a fictitious load value.

### ⏱️ 6.3. Hysteresis, dwell and escalation

Immediate reaction to every sample would cause oscillation and unnecessary writes. The governor therefore uses different concepts for entering, leaving and holding states:

- **dwell time** prevents immediate back-and-forth transitions;
- **separate enter/exit thresholds** provide hysteresis;
- **corroboration** prevents one weak signal from selecting an expensive state;
- **pending-state logic** allows a transition to qualify over more than one observation;
- **thermal and emergency paths** can bypass ordinary performance preferences when safety requires it;
- **write suppression** avoids rewriting a node when the requested value has not changed.

This means that “the load fell for one sample” is not a valid expectation of an immediate state exit. Conversely, touch, launch or a properly corroborated heavy workload can justify faster escalation than ordinary load averaging.

### 🏋️ 6.4. Sustained operation and cool gaming

`SUSTAINED` is not a failure state. Its purpose is to find a performance level the device can maintain without repeatedly hitting severe thermal correction.

`cool_gaming` and the sustained-temperature controls influence how early ASB prefers that sustainable behaviour. They do not turn the phone's thermal sensors off, and they do not guarantee a fixed surface temperature across games, ambient conditions and firmware releases.

`bat_suppress_gaming` keeps the Battery profile out of the gaming policy even when a game is detected. This is intentional: Battery's own performance contract remains meaningful.

### ✍️ 6.5. Writer behaviour and vendor coexistence

The writer compares requested and observed values and records disagreement rather than entering an endless write loop. Important cases include:

| Observation | Interpretation and response |
|:---|:---|
| Observed value equals the request | The request is effective at that moment; no repeated write is needed. |
| Vendor imposes a stricter ceiling | ASB must not fight thermal or platform protection to reclaim a higher cap. |
| Vendor temporarily raises a floor | A touch/launch/QoS boost is not automatically an ASB error or a new permanent baseline. |
| Repeated disagreement persists | Backoff and capability handling reduce pointless writes; diagnostics expose the condition. |
| Interface is absent or read-only | The feature is skipped or reported as unavailable/not exposed; no fake success is emitted. |
| A lease or handover is active | Another defined owner temporarily controls the path, preventing competing writers. |

Writer leases and explicit handover are ownership tools, not a claim that ASB controls every system frequency at all times. Vendor thermal and PowerHAL decisions remain authoritative where the platform enforces them.

## 🧬 7. Device-adaptive CPU bounds

### 🔍 7.1. Why synthesis exists

Fixed frequency values copied from another device are unsafe and often meaningless. ASB discovers the current CPU policy topology and hardware ceilings, then synthesises profile ranges from that evidence.

The discovery path is read-only. Synthesis writes generated configuration data, not new hardware capabilities. If discovery cannot establish identity reliably, import must fail closed rather than reuse an incompatible generated file.

### 🧾 7.2. Bounds schema 3 identity

Schema 3 validates three complementary pieces of provenance:

| Field | What it proves |
|:---|:---|
| `cluster_signature_full` | The complete physical policy/cluster signature, including policies that are not little/mid/big representatives. |
| `logical_roles` | Which discovered policy currently fills each logical role. |
| `policy_map` | Every physical policy's numeric ID, native writer slot, hardware maximum and exposed OPP shape. |

This prevents a fourth policy, changed role, different OPP table or altered writer mapping from passing unnoticed merely because the main three clusters still look familiar.

### 🧩 7.3. `policy_map` format

Each entry uses:

```text
id:slot:hw_max:opp_count:opp_min:opp_max
```

Entries are comma-separated in canonical order.

| Element | Meaning |
|:---|:---|
| `id` | Numeric `cpufreq/policyN` identifier. |
| `slot` | Native logical writer slot, not necessarily the same number as the physical policy ID. |
| `hw_max` | Exposed hardware maximum for that physical policy. |
| `opp_count` | Number of exposed OPP entries, or zero when no usable table is exposed. |
| `opp_min` | Lowest exposed OPP, or zero when the table is not exposed. |
| `opp_max` | Highest exposed OPP, or zero when the table is not exposed. |

The `0/0/0` OPP triplet is a valid evidence shape: **missing `scaling_available_frequencies` does not automatically make the policy unsupported**. Hardware ceilings and other validated interfaces can still permit bounded operation, while the absence of an OPP list remains explicit.

### 🗺️ 7.4. Logical writer slots

| Topology | Slot 0 | Slot 1 | Slot 2 |
|:---|:---|:---|:---|
| **2-policy** | Little | Big | Not used |
| **3-policy** | Little | Mid / big-class middle policy | Prime |
| **4-policy** | Little | Mid / extra-class policy | Prime |

On a 2-policy device, the second physical policy must not be mislabeled as an `extra` role simply because a 3/4-policy parser has such a field. Physical IDs and logical writer slots are deliberately separate.

### 📐 7.5. OPP-aware synthesis

For each generated MIN/CAP/MAX range, ASB uses the policy's measured hardware ceiling and defined profile ratios or policy logic. When an OPP table is exposed, ceiling values snap down to a real entry.

If every exposed OPP is above a requested target, the lowest real OPP is the only valid non-zero ceiling choice. Rounding to the nearest entry would be wrong when it rounds upward, and independent shell/native rounding would create policy disagreement.

Shell import and native import validate the same identity. A schema-2 or otherwise stale file must not be silently reinterpreted as schema 3.

## 🧠 8. Smart learning, decision layers and evidence gates

### 🎓 8.1. What Smart is allowed to learn

Smart is a native, multi-layer policy engine rather than a profile-name switch. It can build scenario-specific evidence from comparable operating windows, estimate the reliability of that evidence and use it to refine performance/efficiency decisions. The goal is to answer questions such as whether additional headroom improves smoothness, whether a lower rail is sufficient, or whether previous thermal/battery behaviour makes a candidate unattractive.

Smart does not learn by blindly writing a new value after every frame spike. A candidate passes through scenario selection, freshness, validity, comparison and cooldown rules before it can influence future policy. Learning supplies a bounded starting point; live workload, thermal, charging and vendor evidence still decide what is acceptable now.

### 🗂️ 8.2. Scenario identity: 12 buckets and hierarchical fallback

Smart distinguishes six dayparts — `SLEEP`, `WAKE`, `MORN`, `DAY`, `EVE` and `LATE` — and separates weekdays from weekends. This produces **12 scenario buckets**: six dayparts × two day classes. The model can therefore reuse a genuinely similar evening or weekend scenario without assuming that every use of the phone at the same hour is equivalent.

| Fallback level | Evidence used | Meaning |
|:---|:---|:---|
| `EXACT` | The matching daypart + weekday/weekend bucket | The most specific learned context available. |
| `DAYPART_ONLY` | The same daypart across the broader day class | Used when the exact bucket is not reliable enough. |
| `CLASS` | Weekday/weekend-class history | A broader behavioural reference, not an exact-scenario claim. |
| `GLOBAL` | Cross-scenario learned history | A conservative general starting point when local evidence is sparse. |
| `SAFE` | Neutral safe baseline | Prevents insufficient evidence from becoming a fabricated precise preference. |

This hierarchy is part of the intelligence, not an error path. A broader fallback can be more truthful than an exact but weakly supported answer.

### 📈 8.3. Confidence, freshness and bounded influence

Each bucket tracks raw observations, effective observations, last-seen time and confidence. Learned outputs are scaled towards a neutral baseline when confidence is low, rather than being applied at full strength merely because a record exists.

| Mechanism | Implementation meaning |
|:---|:---|
| **Effective observations** | Measure how much useful evidence supports the bucket, rather than counting every encounter equally. |
| **Low/high confidence tiers** | The native model defines separate confidence tiers (`350` and `650` on a per-mille scale) and a bounded maximum. |
| **Fresh period** | Evidence up to seven days old is treated as fresh by the decay model. |
| **Stale boundary** | Time decay reaches the stale boundary at 37 days; old behaviour must not dominate indefinitely. |
| **Neutral blending** | Weak confidence pulls learned biases back towards neutral instead of amplifying a guess. |
| **Bounded outputs** | Final alpha and bias values remain inside native limits and cannot override hard safety gates. |

Freshness is not the same as relevance. A fresh observation from an unsuitable charging, thermal or workload scenario can still be ineligible.

### 🎛️ 8.4. What Smart actually controls

Smart can blend Battery-like and Balanced-like CPU bounds and then apply separate, bounded adjustments. It does not randomly toggle the complete WebUI control set.

| Learned bucket value | Policy role |
|:---|:---|
| `alpha_battery_x1000` | Position of the Battery ↔ Balanced performance/efficiency blend. |
| `interactive_bonus_x1000` | Additional bounded allowance for suitable interactive scenarios, separate from idle policy. |
| `idle_bias_x1000` | Preference for restraint versus readiness during idle-related decisions. |
| `sleep_bias_x1000` | Efficiency preference for eligible sleep/night behaviour. |
| `net_conservative_x1000` | Conservatism of related runtime network policy; it is not permission to rewrite every explicit network setting. |

The bucket also retains history for idle quality, wake activity, drain and maximum temperature: `avg_idle_q_x10`, `avg_wph_x10`, `avg_drain_pctph_x10` and `avg_max_temp_x10`. Camera/profile transitions invalidate unsuitable cached decisions rather than carrying a conclusion into a different operating context.

Explicit DSP, camera and other user settings remain user choices. Smart owns its performance/efficiency policy and related native runtime decisions, not an unrestricted licence to change all 84 controls.

### 🌡️ 8.5. Device-relative thermal and drain history

Smart does not apply one absolute “normal temperature” to every OnePlus model. It uses the median thermal history of sufficiently populated buckets to establish a device-relative reference and derive bounded warm/cool adjustments.

| History signal | Possible bounded effect |
|:---|:---|
| Device is warmer than its own relevant norm | Start from a more conservative performance/efficiency position. |
| Device is cooler than its relevant norm | Permit a less defensive starting point when live gates agree. |
| Repeated high drain in comparable history | Add a bounded efficiency nudge instead of waiting for low battery alone. |
| Sparse or stale thermal history | Reduce reliance on the learned norm and retain neutral/live evidence. |

These nudges alter a starting point, not the final authority. The live thermal loop, vendor clamps and safety vetoes have the last word.

### 🌙 8.6. Screen-off, night and low-battery decision layers

Screen-off is not a single scenario. The native override distinguishes an approximate short pause window of **30–120 seconds**, an intermediate window of **120–1800 seconds**, and longer screen-off operation. This helps preserve a sensible return from a brief pause without preventing deeper restraint during a genuinely long idle period.

The night-safe override combines several conditions rather than trusting a clock alone:

- night daypart or learned night context;
- screen-off state;
- not charging;
- no heavy application scenario;
- battery-level eligibility.

The low-battery override uses hysteresis. Entry and exit therefore do not flap around one percentage, and this native efficiency response remains distinct from the separate `auto_battery_enable` profile-switch feature.

Active audio, navigation, VPN, charging, camera and heavy-work evidence can disqualify an otherwise tempting deep-idle conclusion.

### 🔌 8.7. Charge-aware performance and hot-charge protection

Charge-aware policy is a constrained decision matrix, not “plugged in equals maximum speed”. It can consider charging state, screen state, charge power class, battery temperature, SoC temperature and existing safety overrides.

| Condition | Policy consequence |
|:---|:---|
| Cool device, eligible charging scenario | Bounded charge assist may provide additional headroom. |
| Hot battery or hot SoC | Hot-charging protection can suppress the extra allowance. |
| Plugged in with screen off and heat present | The cool guard can favour cooling over unnecessary performance. |
| Existing safety floor or thermal veto | Charge assist does not cancel the floor or override the veto. |
| Charging evidence missing or unsuitable | Do not infer a high-power, cool and safe scenario from the cable alone. |

This is why `charge_aware_enable=1` is permission to evaluate an opportunity, not a guarantee of higher clocks in every charging session.

### 🔥 8.8. App heat, thermal trends and session context

Smart retains bounded per-app heat/drain history using an application hash, heat score, drain score and time decay. Entries are bounded and saved atomically through a temporary file plus `rename()`. This memory can inform later restraint without turning one bad session into a permanent verdict or collecting account/network identifiers.

The thermal path also reacts before a fixed limit is reached:

- a soft thermal pre-lean can reduce avoidable heat build-up;
- a thermal-trend bump considers the rate of heating;
- current temperature and trend remain separate from stale scenario preference;
- session planning can classify the environment as `ENV_QUIET`, noisy or `ENV_HOSTILE`;
- thermal debt and clamp debt from previous sessions can influence the next plan.

| `thermal_veto_reason` | Veto source |
|:---:|:---|
| `1` | Skin/surface thermal constraint. |
| `2` | Junction hard limit. |
| `3` | Junction fallback when skin evidence is unavailable. |
| `4` | Vendor clamps. |
| `5` | Recovery. |

A veto reason explains why extra performance was refused. It is not an error code and must not be “fixed” by fighting the platform owner.

### 🧪 8.9. Evidence pipeline

| Stage | Purpose |
|:---|:---|
| **Scenario selection** | Compare observations from sufficiently similar workload and device conditions. |
| **Freshness check** | Reject data that is too old to describe the current window. |
| **Deduplication** | Prevent repeated delivery of the same hint from counting as independent evidence. |
| **Eligibility gates** | Exclude unsuitable charging, thermal, camera, plateau or scenario conditions. |
| **Bounded A/B window** | Compare alternatives for a limited period rather than making an open-ended change. |
| **Native frame re-evaluation** | Re-read real graphics/smoothness evidence and count each evaluation window once. |
| **Plateau handling** | Stop repeating a comparison that no longer produces useful differentiation. |
| **Cooldown and recheck** | Avoid immediate oscillation while still allowing a concluded result to be revisited later. |
| **Persisted learning** | Save validated results separately from transient hints and user configuration. |

A concluded plateau is not an instruction to test the same alternative continuously. Freshness and recheck rules exist so old decisions do not become unquestionable permanent truth either.

### 🎞️ 8.10. Log-assisted smoothness feedback

The existing log path can provide bounded jank hints that schedule an earlier native smoothness comparison. The log is an input channel, not a policy owner:

1. a hint must be fresh, bounded and deduplicated;
2. the governor checks scenario, charging, thermal, cooldown and plateau gates;
3. the native engine re-reads real `GraphicsStats` evidence;
4. each window is counted once;
5. only the governor's normal decision path can change policy.

This separation is essential. A shell log parser that directly wrote CPU settings would bypass native ownership and could fight the governor.

### 🔍 8.11. Checked feedback parsing and bounded I/O

Feedback numbers are parsed as checked 64-bit values. Parsing uses `strtoull`-style validation with `ERANGE` and overflow checks **before** arithmetic. An enormous counter must be rejected, not wrapped into a plausible small delta.

The governor retains its normal feedback gate and caches file metadata to avoid re-reading an unchanged body. The cache identity includes:

- device ID;
- inode;
- file size;
- modification time with nanoseconds;
- status-change time with nanoseconds.

Atomic replacement is significant: a temp-file write followed by `rename()` must be detected as a new body even when the visible content length happens to match. Directly overwriting a fixture is not an equivalent test of that behaviour.

| Counter | Meaning |
|:---|:---|
| `smooth_log_checks` | Feedback eligibility/cache checks performed. |
| `smooth_log_reads` | Times the feedback body was actually read. |
| `smooth_log_changes` | Observed new or changed feedback bodies. |
| `smooth_log_unchanged` | Checks where the cached body remained unchanged. |

These counters support cost measurement. They do not themselves prove a battery saving.

### 🔋 8.12. Battery, charging and media gates

- `smart_battery_bias` adds an explicit user preference toward efficiency; it is not a learned temperature value.
- `auto_battery_enable` handles low-charge profile switching and previous-profile restoration, independently of ordinary scenario learning.
- `charge_aware_enable` permits the charge-aware decision layer described above only when other gates allow it.
- `smart_media_guard` prevents media-oriented behaviour from being mistaken for an ordinary interactive performance problem.
- Screen-off audio, navigation, VPN and charging can disqualify deep-idle conclusions.

### 🚀 8.13. Prime-core escape

`heavy_prime_escape`, `prime_escape_burst_s` and `prime_escape_rest_s` provide bounded prime-core relief for suitable heavy scenarios. The burst/rest pair is deliberate: a permanent prime lift would defeat the efficiency purpose and increase heat.

The escape is a temporary relaxation within other safety constraints, not an unconditional hardware maximum or an SoC-specific writer.

## 🌡️ 9. Thermal evidence and protection

### 🌡️ 9.1. Multiple temperatures, multiple meanings

CPU, junction, board, skin and battery temperatures answer different questions. ASB can cross-check available thermal zones and attach confidence to a selected source. A derived or disputed source should be shown with lower confidence rather than presented as equally authoritative.

A missing skin/board zone can limit surface-based policy even when CPU temperature remains readable. Conversely, a hot battery is not interchangeable with a CPU die reading.

### 📉 9.2. Adaptive thermal budget

The governor can reduce performance before the platform reaches a severe clamp. This proactive budget is intended to avoid inefficient peak-and-throttle oscillation and make sustained behaviour more predictable.

The budget does not replace the vendor thermal engine. If the platform imposes a stricter limit, that limit wins. ASB must not repeatedly raise a ceiling against an active vendor clamp.

### 🎚️ 9.3. User thermal controls

| Control | Role | Caution |
|:---|:---|:---|
| `sustained_temp_mode` | Chooses stock, Smart-managed or manual sustained-throttling behaviour. | Manual selection changes when ASB starts holding back; it does not move the hardware's physical limits. |
| `sustained_temp_enter` | Sets the manual entry point used by the applicable policy. | A higher value can mean more heat and later restraint; a lower value can reduce peak performance earlier. |
| `perf_ceiling_pct` | Adds an overall performance ceiling. | It is not a temperature target and cannot guarantee a resulting temperature. |
| `cool_gaming` | Biases gaming toward sustainable, cooler behaviour. | Frame-rate results depend on the game and device; no universal gain is promised. |
| `bat_suppress_gaming` | Prevents Battery from entering its gaming state. | Lower game performance in Battery is expected. |

### 🔬 9.4. Thermal diagnostics

A useful thermal report should identify the source, confidence, current limit owner and recent vendor evidence. “ASB requested a higher value” and “the phone is allowed to use it now” are separate statements.

Do not infer that thermal protection is broken just because a current clock is below a profile ceiling. Check for `SUSTAINED`, a thermal cap, vendor ownership, sensor confidence and transient profile-switch state first.

## 🎛️ 10. Complete WebUI control index

The following tables mirror the WebUI's six configuration groups. Defaults describe the normal initial policy, not a recommendation to reset a working setup. Availability and apply timing remain device-dependent.

### 🔋 10.1. Battery

| Key | WebUI name | Default | Advanced behaviour / test focus |
|:---|:---|:---:|:---|
| `auto_battery_enable` | Auto Battery Profile | `1` | Low-charge Battery switch and previous-profile restoration; test across charge thresholds and manual profile changes. |
| `smart_battery_bias` | Smart Battery Bias | `0` | Bounded efficiency preference for Smart; verify that thermal and scenario gates still apply. |
| `heavy_prime_escape` | Prime Core Lift | `1` | Enables bounded prime relief in eligible heavy scenarios. |
| `prime_escape_burst_s` | Prime Lift Length | `20` | Duration of each permitted prime-core lift; not a permanent maximum-frequency request. |
| `prime_escape_rest_s` | Pause Between Lifts | `40` | Cooling/rest interval between lifts; test burst-plus-rest behaviour rather than one sample. |
| `smart_media_guard` | Smart Media Guard | `0` | Separates suitable media scenarios from ordinary interactive escalation. |
| `charge_aware_enable` | Charge-Aware Mode | `1` | Allows additional headroom on a charger when temperature and other evidence permit. |
| `doze_level` | Deep Sleep | `stock` | Stock/night/moderate/aggressive idle timing; aggressive modes can delay notifications. |
| `doze_trim_whitelist` | Trim Doze Exemptions | `0` | Trims exemptions only for eligible user applications; verify messaging and automation behaviour. |
| `wakelock_action` | Act on Wakelocks | `0` | Enables optional action beyond observation; a wakelock name alone is not proof of a faulty app. |
| `wakelock_fitness` | Fitness Apps & Wakelocks | `protect` | Protects or limits fitness-related wake behaviour; test actual tracking sessions. |
| `gnss_trim` | Trim Background GPS | `0` | Restrains background location work without treating foreground navigation as unnecessary. |
| `night_quiet_enable` | Quiet Night | `1` | Reduces optional ASB activity in the night window; does not disable the native safety path. |
| `sustained_temp_mode` | Throttling Point | `smart` | Selects stock, Smart or manual sustained-temperature policy. |
| `sustained_temp_enter` | Throttling Temperature | `65` | Manual entry value for the applicable sustained policy; not a vendor thermal-limit override. |
| `perf_ceiling_pct` | Performance Ceiling | `100` | Additional profile-level cap; final clocks can be lower because of state, OPPs or vendor limits. |
| `cool_gaming` | Cool Gaming | `1` | Prefers sustainable game behaviour over unrestrained peaks. |
| `bat_suppress_gaming` | No Game Mode on Battery Profile | `1` | Preserves Battery's distinct efficiency policy under game load. |
| `BG_TRIM_LEVEL` | Background Trim Level | `safe` | Controls background trimming intensity; aggressive trimming can reload apps. |
| `mglru_hold` | Keep Apps In Memory | `stock` | Adjusts app-retention policy where MGLRU-related interfaces support it. |
| `kernel_sched_stats` | Scheduler Debug Accounting | `stock` | Controls optional scheduler accounting overhead; availability is kernel-dependent. |
| `gms_trim` | Google Services Trim | `stock` | Lite/strict background trimming for selected Google Services behaviour. |
| `gms_freeze` | Freeze Google Components | `off` | Safe/more/max component restraint; test push, location, casting and account-dependent functions. |

### 🌐 10.2. Network

| Key | WebUI name | Default | Advanced behaviour / test focus |
|:---|:---|:---:|:---|
| `radio_policy_enable` | Cellular / radio controls | `0` | Explicit master choice for ASB cellular/radio policy; off leaves the relevant Android behaviour alone. |
| `night_modem_idle` | Quiet Radio at Night | `0` | Optional night-time radio restraint; test message delivery and connectivity. |
| `net_screen_off_lte` | LTE While Screen Off | `0` | Controls screen-off cellular policy where supported. |
| `net_lte_light` | 5G Only When Needed | `0` | Need-based 5G policy; signal and carrier behaviour can dominate results. |
| `net_congestion` | Download Ramp · other links | `auto` | Auto/BBR/CUBIC for other route types. |
| `net_congestion_wifi` | Download Ramp · WiFi | `auto` | Per-Wi-Fi congestion control, applied only when the route and algorithm are available. |
| `net_congestion_mobile` | Download Ramp · mobile | `auto` | Per-mobile congestion control; verify the live interface rather than Wi-Fi state. |
| `net_qdisc` | Packet Queue · other links | `auto` | Auto/`fq`/`fq_codel`/`cake` for other links. |
| `net_qdisc_wifi` | Packet Queue · WiFi | `auto` | Queue discipline for Wi-Fi when supported by the kernel and interface. |
| `net_qdisc_mobile` | Packet Queue · mobile | `auto` | Queue discipline for mobile routes; do not infer success from a configuration value. |
| `net_rps` | Spread Network Load | `stock` | Stock/little/all receive-packet distribution across eligible CPUs. |
| `net_txqueue` | Transmit Queue | `stock` | Stock/short/shorter transmit-queue policy; shorter is not universally lower latency under every driver. |
| `net_route_tune` | Network Buffers | `auto` | Auto/off/conservative/aggressive buffer policy; aggressive values can increase memory use and bufferbloat. |
| `net_mtu_probing` | TCP MTU Recovery | `stock` | Optional TCP MTU recovery; test path-MTU problems separately from bandwidth. |
| `wifi_country` | WiFi Region | `auto` | Automatic or selected regulatory region; use only the legally correct region for the device location. |
| `wifi_scan_throttle` | WiFi Scan Rate | `2` | Scan restraint level; stronger restraint can delay new-network discovery and roaming decisions. |
| `net_wifi_leave` | Leave Bad Wi-Fi | `off` | Off/weak/unusable/aggressive fallback policy; can increase mobile-data use. |
| `wifi_powersave` | WiFi Power Save | `off` | Off/screen-off/always power saving; latency and throughput can change. |

#### 🔎 Network verification rules

A valid network test identifies the exact route and interface. Wi-Fi results must not be collected while traffic actually uses a mobile interface, and a VPN can change the observable path. Compare the same server, signal conditions, time window and workload.

`auto` is a deliberate non-write/hand-back choice where defined, not a hidden promise that ASB selected the fastest algorithm. Kernel support for BBR, `cake` or another option must be established from live evidence.

### 🎧 10.3. Audio

| Key | WebUI name | Default | Advanced behaviour / test focus |
|:---|:---|:---:|:---|
| `audio_profile` | Audio Profile | `stock` | Stock/base, `eq_compat` for an external processor, or Hi-Fi. `eq_compat` intentionally disables ASB DSP on the shared stream. |
| `audio_dac_hifi` | Hi-Fi DAC (mixer) | `0` | Codec mixer configuration where exposed; reboot-dependent and not proof of a particular audible improvement. |
| `media_loudness` | Media Loudness | `stock` | System media-volume curves, separate from DSP sample processing; reboot-dependent. |
| `media_vol_steps` | Media Volume Steps | `stock` | Number of media-volume steps; verify the live Android value after apply. |
| `audio_resampler` | Resampler Quality | `stock` | Stock/high/max conversion filters; relevant only when sample-rate conversion actually occurs. |
| `bt_absvol_mode` | Bluetooth Volume Control | `stock` | Shared headset/phone scale or independent phone gain; lowest-step behaviour varies by headset. |
| `bt_link_stability` | Bluetooth Link Stability | `stock` | Stable mode suppresses Wi-Fi scans during audio on affected links; new networks can appear more slowly. |
| `bt_a2dp_offload` | Bluetooth Audio Offload | `auto` | Auto/on/off hardware encoding route; off can help some external EQs but moves work to the CPU. |
| `dsp_outputs` | DSP Outputs | `all` | Selects speaker/wired/Bluetooth combinations or disables DSP while preserving its parameter values. |
| `dsp_loudness` | DSP Loudness | `0` | Main DSP enable/gain control, 0–25 dB; first effect enable can require reboot. |
| `dsp_bass` | DSP Bass Boost | `0` | Low-shelf boost; consumes headroom and causes the limiter to engage sooner. |
| `dsp_voice` | DSP Voice Tone | `0` | Broad voice-body and presence-edge adjustment, especially useful on small speakers. |
| `dsp_width` | DSP Stereo Width | `0` | Enhances stereo side information above the protected bass region; mono/centre content is not widened in the same way. |
| `dsp_clarity` | DSP Clarity | `0` | Gentle high-shelf adjustment before dynamics and final limiting. |
| `dsp_rumble` | DSP Sub-bass Filter | `off` | Off/35/50/70 Hz high-pass choice; higher cutoffs are intentionally aggressive. |
| `dsp_headroom` | DSP Output Headroom | `15` | Final sample-peak ceiling: `-0.15`, `-0.30`, `-0.50` or `-1.00` dB from the corresponding values. |
| `dsp_compressor` | DSP Compressor | `on` | Soft dynamics control for higher gain; the final peak limiter remains when the compressor is off. |
| `audio_remove_volume_limit` | Headphone Volume Limit | `0` | Explicit hearing-safety choice; ASB does not silently remove this system safeguard. |

#### 🎚️ DSP chain and route semantics

The processing order is meaningful:

```text
sub-bass filter → bass → voice tone → clarity → stereo width
→ dynamics / compression → final sample-peak limiting
```

Gain, bass and width cannot be assessed independently of headroom. A large bass boost before the limiter can reduce overall loudness even though its numeric level increased. The headroom control is a sample-peak ceiling, not an oversampled true-peak detector.

`dsp_outputs=off` releases ASB processing from the selected path without erasing tone and dynamics settings. Selecting only the actual listening route avoids applying speaker-oriented gain to headphones or vice versa.

On the built-in loudspeaker, an additional thermal policy can reduce DSP gain when the battery becomes hot and restore it after cooling. Wired and Bluetooth routes are not governed by that speaker-specific reduction in the same way.

Bluetooth DSP processing can remove playback from a low-power offload path and keep the CPU awake with the screen off. A battery comparison must therefore record the selected DSP outputs, codec/offload state and audio route.

#### 🔌 External processors and effect interfaces

`eq_compat` is the appropriate choice when ViPER, JamesDSP or another external processor should receive the stream without ASB's effect occupying the same processing path. Do not troubleshoot two processors as though they were one effect.

ASB's audio integration can involve legacy effect interfaces and AOSP/AIDL components. These workflows are separate:

- the native governor build does not rebuild the DSP;
- an AOSP/AIDL effect build is not evidence that every delivered DSP binary was rebuilt locally;
- reference/prebuilt DSP files must be described honestly as such;
- ABI selection and attach evidence belong in diagnostics, not inferred from a filename.

### 📷 10.4. Camera

| Key | WebUI name | Default | Advanced behaviour / test focus |
|:---|:---|:---:|:---|
| `CAMERA_LEVEL` | Camera Grade | `0` | Overall grading strength generated from the device's own stock camera data. |
| `CAMERA_CONTRAST` | Contrast & Colour Depth | `3` | Tone/colour intensity; compare skin, highlights and shadow banding. |
| `CAMERA_GRAIN` | Film Grain | `3` | Restores texture after denoising; high values can look noisy or artificial. |
| `CAMERA_PORTRAIT` | Portrait AI | `0` | Portrait-processing intensity; inspect edges, faces and background transitions. |
| `CAMERA_LOWLIGHT` | Macro & Low-light Sharpening | `0` | Separate macro/low-light sharpening; inspect halos and fine texture. |
| `camera_hold_enable` | Hold Performance While Camera Runs | `1` | Temporary capture responsiveness without making the camera scenario ordinary idle. |

Camera tone tables are regenerated from stock files and integrated through the module's mount path. Changing a slider saves the request, but an already mounted file may require reboot before the camera HAL sees the new content.

A valid camera comparison uses the same phone, firmware, camera application, lens, scene, lighting and capture mode. Processing strength does not replace hardware optics and cannot be validated from one preferred photograph.

### ✨ 10.5. Interface

| Key | WebUI name | Default | Advanced behaviour / test focus |
|:---|:---|:---:|:---|
| `UX_MANAGE_TIMEOUTS` | Manage UI Speed (anim + touch) | `0` | Explicit ownership gate for animation and touch timing controls. |
| `anim_speed` | Animation Speed | `-1` | Stock/default sentinel plus configurable animation-speed levels; check live system scales. |
| `UX_ANIM_FORCE_RESTART` | Force Animation Restart | `0` | Optional restart path for animation changes; can interrupt current UI activity. |
| `disable_blur` | Disable Blur | `0` | Disables supported blur effects without writing known-dangerous display values. |
| `ui_effects_level` | System Animations | `auto` | Auto/stock/flat visual-effects policy. |

Animation speed changes perceived responsiveness; it does not make application computation faster. UI benchmarks should separate animation duration from actual launch and frame-production time.

### 🧩 10.6. System

| Key | WebUI name | Default | Advanced behaviour / test focus |
|:---|:---|:---:|:---|
| `UX_MANAGE_OEM_TOGGLES` | Manage OEM Toggles (RAM/Battery/Heat) | `0` | Explicit ownership gate for supported OEM controls; ASB does not assume every ROM exposes them. |
| `athena_service` | Athena Background Killer | `stock` | Stock/off vendor background-killer policy; test app reloads and background delivery. |
| `heytap_mcs` | HeyTap MCS / OPPO Push | `stock` | Off disables `com.heytap.mcs` without a `.replace` overlay and requests one `pm compile -m speed-profile -a` after the next completed boot. Push notifications can stop or be delayed. Stock/uninstall restores only ASB-owned state and cancels pending ART. |
| `documentsui_fix` | DocumentsUI / DSU Picker Fix | `0` | One-time user-0 package/component repair with readback and rollback; disables ColorOS File Manager until Off. No ART request and no boot reapply. |
| `phantom_procs` | Background Process Limit | `relaxed` | Stock/relaxed/strict process-limit policy; strict can affect legitimate background work. |
| `mmfeed_off` | Multimedia Telemetry Off | `0` | Disables supported multimedia telemetry paths without claiming to remove all ROM telemetry. |
| `ltpo_force` | Force LTPO Refresh | `0` | Forces supported LTPO behaviour; panel and ROM support are required. |
| `ltpo_video` | Lowest Refresh for Video | `0` | Requests low refresh for suitable video playback; not every player/route is eligible. |
| `haptic_strength` | Vibration | `-1` | Stock/default sentinel plus vibration-strength levels. |
| `haptic_touch_strength` | Touch Feedback | `-1` | Separate touch-haptic intensity where the device exposes control. |
| `log_level` | Log Detail | `1` | ASB diagnostic verbosity; higher detail increases I/O and log volume. |
| `lsposed_verbose` | LSPosed Verbose Log | `keep` | Keeps or disables verbose LSPosed logging; does not imply LSPosed itself is installed. |
| `zygisk_enabled` | Zygisk Process Observer | `0` | Opt-in selection for newly started allowlisted app processes; empty allowlist and safe-mode disable. Observation alone sends no governor request. |
| `zygisk_hints` | Zygisk Lifecycle Refresh | `0` | Accepted lifecycle edges request fresh evidence from the existing governor only while the screen is on; 2-second spacing and 8 requests/minute per companion. No cap, profile or LSPosed policy. |
| `zygisk_launch` | Zygisk Cold-Start Lift | `0` | A new top-app process (cold start) carries the running unlock lift over the start or arms one inside the 5 s anti-chatter gap; package-free, at most 1/s and 20/min; profile/thermal/warm gates unchanged. |
| `zygisk_ledger` | Zygisk Process-Start Ledger | `0` | Per-package process starts with the screen off/on for this boot (tmpfs); diagnostics only, nothing restricted. |

Vendor-service and process controls require particular care. “More aggressive” is not synonymous with “more efficient”: repeated process restart can cost more energy and degrade notifications, widgets, media, sync and location.

The HeyTap ART helper is a bounded one-shot, not a boot service: `pending → running → done|failed|cancelled`, a lock against parallel execution, a post-boot delay and a 1800-second default timeout. A failed all-package compile is not retried automatically. Reapplying the same Off value does not re-arm a completed request; Stock → Off deliberately creates a new one. Uninstall cancels pending work but does not run a mass `pm compile --reset`.

## 📊 11. WebUI, monitor and effective-state semantics

### 📑 11.1. Pages

| Page | Operational role |
|:---|:---|
| **Profiles** | Select Smart, Performance, Balanced, Battery or Stock and inspect current high-level state. |
| **Monitor** | Inspect live workload, clocks, thermal/battery state, Smart evidence, smoothness and limit ownership. |
| **Config** | Change the 84 controls indexed above, with capability and reboot/apply feedback. |
| **Device** | Request read-only hardware, kernel, root and capability facts. |
| **Zygisk** | Opened from the Zygisk pill in every header: connection verdict, one mode control, activity and cost, observed apps and safe mode. One read (`asb_zygisk.sh link-status`). |
| **Reports** | Generate support diagnostics and user-triggered extended reports. |

The WebUI supports English, Russian, German, Spanish, French, Italian, Portuguese, Turkish, Ukrainian, Chinese, Indonesian, Arabic and Armenian. It provides dark, light and Liquid Glass presentation, with layouts intended for narrow phone viewports as well as larger screens.

### 🔍 11.2. Requested versus effective

A configuration card answers “what did the user select?” It cannot by itself answer “what is live?” Monitor, Action and diagnostics therefore use additional evidence:

- current sysfs/property/service values;
- writer status and observed disagreement;
- active vendor or lease ownership;
- capability manifests and exposed interfaces;
- pending reboot/apply state;
- confidence and freshness metadata.

A missing denominator must hide a normalised scale rather than produce an arbitrary percentage. Unknown or warming-up values remain neutral. Reverse scales are used where a larger number is not automatically better — for example, available headroom versus consumed resource.

### 👑 11.3. Limit ownership

“Who set the limit?” is a diagnostic attribution, not a moral judgement. The source can be ASB policy, shell/runtime policy, vendor/platform policy, thermal protection or an unknown state.

A vendor clamp can be protective and expected. An ASB cap can be deliberate because of Battery or a user ceiling. The correct response depends on the source and current scenario, not on always removing the lowest visible limit.

### 💾 11.4. Named configurations and backup

Named configurations are useful for repeatable testing, but they are not universal device images. Before importing a setup on different hardware or firmware:

1. export the current known-good configuration;
2. record model, firmware, kernel and root manager;
3. import without assuming unsupported values applied;
4. inspect capability and not-applied feedback;
5. regenerate or validate device-specific bounds where required;
6. test each affected subsystem independently.

### ⚡ 11.5. Why page switches do not wait for root shells (fix278)

KernelSU-family managers run `ksu.exec` synchronously on the WebView's JavaScript thread and start a new root shell for every call, so each call freezes taps, scrolling and the page slide for one shell start plus the command. The WebUI therefore follows four rules:

- **No root call on a tap.** Opening Monitor, Settings, the Zygisk page or Device starts its slide first; the reads run after the slide (the page's transition time + 30 ms).
- **One shell per screen read.** Reads that belong to one screen share one shell, with a per-session marker line between parts (`runBatch`): Settings (config, ledger, trials, LTPO, multimedia, LSPosed, package tweaks, device class) and every Monitor poll (state, learner, native status, recovery, LPM).
- **Fresh data is reused.** A Settings load younger than 30 s is not repeated, and a refresh that returns exactly what the page was drawn from repaints nothing; writes force a fresh read. The config is read once in the background 4 s after start-up, so the first visit draws real values. The Zygisk header pill is refreshed by Zygisk actions and otherwise at most every two minutes.
- **Layout is measured once, after motion.** The page-fit pass coalesces into one run after the slide; the tab-indicator boxes are measured once and re-measured only on resize, scale, language or fit-tier change.

Browser bench with the bridge modelled as blocking (60 ms per call), fix277 → fix278: Home → Monitor 7 → 1 root calls, Monitor → Settings 16 → 2, Home → Settings 11 → 0, Settings → Home 1 → 0, Zygisk pill 13 → 1, Monitor open for 9 s 19 → 3. These are call counts on a desktop host; the time each call costs depends on the phone and the manager.

On Device diagnostics the LSPosed hook evidence (logs, crash records, package and process lists) is collected from its own card on request (`asb_device_info.sh --lsposed`); asbdiag still collects it in full.

### 🔔 11.6. Notification fix and one battery-drain figure (fix279)

**Notification fix** (Config → Battery → Sleep & Background) is a per-app repair for notifications that arrive late — only once the app is opened, or only when the screen turns on. The user ticks the affected apps and taps *Fix notifications*; `runtime/asb_notif_fix.sh` then, for exactly those user apps:

- adds a user Doze exemption (`deviceidle whitelist +pkg`) where the app had none;
- sets `RUN_ANY_IN_BACKGROUND`, `RUN_IN_BACKGROUND` and `WAKE_LOCK` back to `allow` where a package or uid mode restricted them;
- removes the uid from the background-data denylist and, while Data Saver is on, adds it to the Data Saver allowlist;
- puts the app on ASB's own keep list, so Doze trimming, the wakelock watcher and background trim leave it alone, and lifts an ASB per-app wakelock limit on it.

Every original package mode, uid mode, exemption and list membership is recorded first (`/data/adb/asb/notif_fix`) and read back after the change; unticking an app, removing every app or uninstalling the module restores exactly what was there. The two early service ticks and the half-hourly tick re-apply a selection that the ROM's boot sweep reset. The notification permission itself and the ROM's own per-app switches (background activity, auto-launch) are reported, never changed. ASB settings that delay push for every app (strict Google services trim, HeyTap push off, the ROM's Athena killer) are listed with a one-tap change through the normal Settings path; savers are listed as information.

**Battery drain.** The Monitor screen-on tile, the profile card, the manager action headline and the time to empty all use one figure — the profile's long-term screen-on average from the drain meter. The governor's live window (the last ≥10 minutes with the screen on) is shown in the drain sheet as its own *Right now* line with its own time to empty, never in place of the average. The infinite-log report keeps its own window (the time of that recording) and names the profile average beside it. The current-sensor scale is written the same way everywhere (“reads about N× low”, rounded to one decimal).

## 🔐 12. Device information, privacy and evidence quality

### 🕵️ 12.1. Read-only, on-demand collection

Device discovery reads public runtime interfaces needed to describe capabilities and compatibility. It does not require a persistent inventory worker and must not modify the device while collecting facts.

Read-only collection can still produce an incomplete answer. SELinux, kernel configuration, mount namespaces, missing nodes and firmware abstractions can hide information from the current process.

### 🚫 12.2. Data excluded from reports

ASB diagnostics do not need and must not read:

- device serial numbers;
- IMEI or equivalent subscriber/device identifiers;
- account names or account contents;
- network identifiers such as MAC addresses or similar unique link identifiers.

Before sharing a report, the user should still review it. Environment details, installed package names or personally meaningful filenames can be sensitive in a particular support context even when they are not universal hardware identifiers.

### 🏷️ 12.3. Evidence labels

Use precise wording when extending diagnostics:

| Situation | Appropriate result |
|:---|:---|
| Interface absent after defined discovery | `not exposed` or `not runtime-discoverable`, with context. |
| Evidence contradictory or too old | `unknown` / low confidence, not a preferred guess. |
| Kernel config suggests a feature | Configuration evidence only; not proof of active runtime behaviour. |
| Standard BPF/FUSE interface exists | Does not prove a specialised feature such as FUSE-BPF. |
| A write request returned success | Request accepted; still verify effective state where possible. |
| No stock baseline readable | Unknown baseline; do not invent a “stock” value from another device. |

Kernel-origin classification is also indicative, not provenance proof. A stock-like configuration cannot establish who built the kernel.

### 🛰️ 12.4. Zygisk Process Observer and bounded lifecycle refresh

The observer is a native Zygisk module plus a root companion, not a Zygisk-detection label and not another governor. Its shipped defaults are:

```sh
zygisk_enabled=0
zygisk_mode=observer
zygisk_hints=0
```

The allowlist is empty. Enabling the setting without adding packages therefore selects no application processes. Only newly started, explicitly allowlisted ordinary apps are eligible; configuration changes do not kill or restart existing apps. Native validation rejects malformed names, process-suffix entries such as `:remote`, duplicates and more than 64 packages. `system_server`, SystemUI, package/permission/settings/phone components, root and LSPosed managers, and protected Qualcomm/vendor/safety-center families are excluded independently of the shell helper.

The implemented event path is deliberately narrow:

```text
preAppSpecialize: uid/app-zygote filter + generated zygisk/policy (allowlist/exclusion checks)
  → bounded companion connection and exemptFd()
postAppSpecialize: one PROCESS_START frame
  → peer credential + /proc/<pid>/stat start_ticks validation
  → bounded aggregate state
peer socket disconnect → process exit
```

There are no JNI or PLT hooks. A selected process retains the library only to own its process-lifetime socket. The fixed-size versioned frame has no policy opcode. Shared aggregation is mutex-protected; live state is capped at 64 processes, package history at 64 events per minute with a 60-second TTL, duplicate starts are suppressed, and same-package starts are rate-limited. Invalid, duplicate, rate-limited and capacity drops are counted separately. State publication uses a temporary file and atomic rename; arm64 and arm32 companions have separate state files. No per-app daemon, timer or polling loop exists.

With `zygisk_hints=1`, an accepted start/exit may additionally open a short datagram round trip to `/dev/.asb/ctl.sock`. Its only opcode is `zygisk-refresh`, with a 100 ms receive timeout and no package, PID, profile or tuning payload. A per-companion budget enforces 2-second spacing and 8 requests per rolling minute. The governor independently checks both opt-in keys, safe mode and screen-on state, then invalidates the foreground cache and schedules fresh metrics. It does not force a write, clear reassert dwell, select a profile or override thermal/vendor ownership. Screen-off requests are vetoed without a metrics probe; missing/old governors time out fail-open.

Lifecycle coverage is **process start and peer-disconnect exit only**. `is_top_app` is not persistent foreground tracking. Foreground/background, media, camera, audio and navigation events are `not exposed` in this stage. The safe-disable file is `/data/adb/asb/zygisk_observer/disable`; it is checked before companion connection. Failure to connect or publish state leaves application execution and governor policy unaffected.

Management is available in Device diagnostics or through the source-shipped helper:

```bash
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh list'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh set-packages com.example.app org.example.game'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh enable'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh disable'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh safe-mode on'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh safe-mode off'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh status'
```

`set-packages` with no names clears the list. Rejected updates preserve the previous list. Safe mode also sets `zygisk_enabled=0`; clearing safe mode does not re-enable observation automatically. The helper never manages applications, Zygisk, LSPosed or other modules.

Observer diagnostics keep configuration, installed ABI, runtime event state and actual validated live PIDs separate. `memory_kb` is the sum of current application VmRSS for those PIDs, **not pure observer overhead**. `ipc_cpu_ms` and `ipc_wakeups` describe companion receive/validation/state-write/hint-round-trip handling, not whole-app CPU. Event state older than five minutes with no validated live process is `stale_over_5_minutes`. Crash and ANR counts are `unknown` because attribution evidence is `not exposed`. `policy_hints` counts attempted refresh round trips; `hints_accepted` counts the governor's `ok`, while vetoed, unavailable and locally throttled requests have separate counters. Acceptance means only that fresh evidence will be evaluated, never that a cap changed or energy was saved.

#### 12.4.1. Dormant policy, cold-start lift and process-start ledger (fix272)

App processes no longer read `governor.conf`, the allowlist or anything under `/data/adb/asb`. `runtime/asb_zygisk.sh sync` (run by every helper command, by every WebUI Zygisk switch and in post-fs-data before zygote starts) writes one small file, `zygisk/policy`, inside the module directory:

```text
v=2  gen=<epoch>  observer=0|1  hints=0|1  launch=0|1  ledger=0|1  pkg=<allowlisted package>…
```

The file is **absent** whenever the master switch is off, safe mode is on or nothing is selected. The hot path is then: reject isolated, SDK-sandbox, system and app-zygote processes by uid before any syscall; one `open()` of the policy (ENOENT = dormant → `DLCLOSE`). If zygote may not traverse `/data/adb` (EACCES at `onLoad`), the loader's `getModuleDir()` fd is used instead of repeating a denied open. A malformed policy observes nothing. On the build host the dormant check measured ≈0.8 µs per fork against ≈70 µs for the previous parse of the 40 KB `governor.conf` (x86-64, not a phone figure).

The companion keeps its state in `/dev/.asb/zygisk/state.<abi>.tsv` (tmpfs, this boot only) and no longer `fsync`s to flash on every event. Governor round trips run outside the state lock.

`zygisk_launch=1` (opt-in): when zygote starts a new process flagged `is_top_app` for an ordinary app, one package-free frame reaches the companion, which forwards the fixed opcode `zygisk-launch` (≥1 s apart, ≤20/min). The governor checks `zygisk_enabled`, `zygisk_launch`, safe mode and the screen, then feeds the existing unlock lift: a running lift is carried `unlock_lift_s` past the start; with none running a new one is armed even inside the 5 s anti-chatter gap. Profile, thermal and warm-die gates are unchanged. State keys: `zygisk_launch_accepted`, `zygisk_launch_vetoed`, `unlock_cold_lifts`, `unlock_cold_extends`.

`zygisk_ledger=1` (opt-in): every ordinary app process start sends its base package; the companion counts starts per package with the screen off/on (from the governor's published `screen=`), bounded to 128 packages. Device diagnostics shows the top screen-off starters (`ledger_top_screen_off`). Nothing is restricted automatically.

Repeatable A/B for the cold-start lift (same profile, same app, phone cool, 10 runs each):

```bash
su -c 'am force-stop com.example.app; sleep 2; am start -W -n "$(cmd package resolve-activity --brief com.example.app | tail -n 1)"' | grep TotalTime
```

Device check that app processes can read the policy: after enabling a feature and opening one app, Device diagnostics should show `policy_seen_generation` equal to `policy_generation`. If it stays 0, look for denials with `su -c 'logcat -d | grep -i "avc.*zygote"'`.

#### 12.4.2. Restart loops and LSPosed hook evidence (fix277)

**Restart loops.** With `zygisk_ledger=1` the companion also keeps, per package, the screen-off start times of the last 5 minutes in a fixed 32-slot ring (256 bytes per package, at most 128 packages; no growing container). The `L` state row gains a sixth column, `burst_off`: the most screen-off starts seen inside any 5-minute window this boot. Device diagnostics shows packages with ≥6 as `ledger_restart_loops` (`pkg 9/5min`), and the Device page raises an insight. A user rarely opens an app with the screen off, so a high value points to a crash-restart loop, a sync storm or a wake chain — the case a whole-boot total hides. Nothing is restricted automatically.

**Companion overhead.** The companion rewrites its tmpfs state on every accepted frame. It used to re-read `/proc/<pid>/status` of every observed process for each rewrite, so a burst of process starts multiplied those reads; RSS is now cached per PID and process start time for 30 s (`rss_reads` in the companion state file counts the real reads). The Device page reads live RSS itself and uses the companion's value only as a fallback.

**LSPosed hooks: problems and battery evidence.** LSPosed does not count individual hook calls or their energy, and ASB adds no hook of its own to measure them (that would mean hooking ART inside every app — exactly the cost being looked for). The new read-only card joins evidence per hooked app instead:

| Key | Source |
|---|---|
| `modules`, `hooked_apps`, `system_scope`, `multi_hooked` | `asb --lspd modules` — read-only SQLite query of LSPosed's own `modules` + `scope` tables (disabled modules and malformed names skipped; `system`/`android`/`com.android.systemui` scope is listed apart because those hooks run in always-on processes) |
| `log_window_min`, `log_rate_kb_h`, `log_top`, `error_modules` | last 1 MB of the newest `modules_*.log` and `verbose_*.log`: bytes and E/F lines per app uid, rate per hour over each file's own time span, module packages seen in error stack frames |
| `crash_hooked` | `dumpsys dropbox` (`data_app_crash`, `system_app_crash`, `data_app_anr`, 4 s timeout each, last 600 KB): only entries whose stack passes through `LSPHooker_`/XposedBridge/LSPlant frames, with the module package named in the frames |
| `cpu_hooked_top` | `ps -A -o UID,TIME,NAME`: cumulative CPU time of hooked apps since their process start |
| `churn_hooked_top` | the Zygisk ledger (screen-off/on starts and bursts) of hooked apps |

`findings` counts what crosses a threshold: a hooked app with a hook-stacked crash/ANR, a module in ≥20 error stacks, an app writing ≥512 KB/h to LSPosed's logs, a hooked app with a ≥6/5 min screen-off burst. `findings_detail` names them (`crash:pkg errors:module log_spam:pkg loop:pkg`). asbdiag prints the same block with a verdict. A finding is a correlation: confirm it by disabling one module for that one app and comparing. The collector runs only when the Device page or asbdiag is opened; it writes nothing to LSPosed's directory or database.

### 📊 12.5. System-pressure scale

Device schema 5 adds an on-demand pressure heuristic. It reads procfs/sysfs only when the Device collector or the informational `asbdiag` section is requested; there is no background pressure sampler. Every available component is shown with its measured source value and actual weight:

| Component | Base weight | Component calculation |
|:---|:---:|:---|
| Load | 35 | `load_per_core = loadavg_1m / online_cpu_count`; `load_component = clamp(load_per_core × 50, 0, 100)` |
| Memory | 30 | `memory_used_pct = clamp((MemTotal − MemAvailable) × 100 / MemTotal, 0, 100)`; `memory_component = clamp((memory_used_pct − 40) × 2, 0, 100)` |
| CPU | 25 | Two `/proc/stat` reads around a 0.20-second sample; `busy = (Δtotal − Δ(idle+iowait)) × 100 / Δtotal` |
| GPU | 10 | A valid 0–100 percentage or numerator/denominator from a supported readable `gpu_busy` interface |

For available components only:

```text
score = Σ(component_i × base_weight_i) / Σ(base_weight_i)
coverage_pct = Σ(base_weight_i)
```

A missing or invalid component is `not exposed`, receives weight zero and is not replaced with an estimate. Coverage below 40 produces `score=unknown` and `band=unknown`; no marker is drawn for an unknown score. Valid bands are **0–24 light**, **25–49 moderate**, **50–74 high** and **75–100 very high**.

`loadavg` includes running/runnable and uninterruptible wait and is not CPU usage. Swap/zRAM occupancy is a supporting signal only: it is not scored and does not prove a problem by itself. Confidence is explicitly a **single on-demand snapshot** with no trend, baseline or A/B inference. The scale is not a device-health score and not an estimated battery or performance saving.

Host regressions exercise native aggregation and malformed/spoofed frames, exclusions, bounds, rate limits, safe mode, formula/coverage, stale state, PID reuse and WebUI command validation. They do not establish real Zygisk injection compatibility on OnePlus/ColorOS or another physical device; that requires an on-device test with the exact root/Zygisk implementation.

## 🩺 13. Diagnostics and command-line workflow

### ⌨️ 13.1. Everyday commands

```bash
su -c 'asb status'
su -c 'asb reload'
su -c 'asbdiag'
```

| Command | Use |
|:---|:---|
| `asb status` | Quick live status and native state information. |
| `asb reload` | Request a controlled configuration/policy reload; it is not a substitute for a required reboot. |
| `asbdiag` | Detailed support report covering configuration, effective values, capabilities, governor, thermal, audio, camera, network and apply evidence. |

The module card's **Action** screen is often the fastest first check. The WebUI support controls can generate diagnostics without manually typing shell commands.

### 🔧 13.2. Useful source-side inspection tools

The source archive contains focused tools for discovery, effective policy, device verification, state audit, report generation and capture comparison. Their exact arguments can evolve, so inspect the tool header or `--help` where implemented rather than assuming a stable scripting API.

Important files in a typical review include:

| Path | Purpose |
|:---|:---|
| `tools/asb_diag.sh` | Source of the installed `asbdiag`; the two delivered copies must match. |
| `tools/asb_discover.sh` | Read-only device capability and topology discovery. |
| `tools/asb_synthesize_bounds.sh` | Generates validated device-specific profile bounds. |
| `tools/asb_effective_policy.sh` | Helps compare requested and effective policy. |
| `tools/asb_audit_state.sh` | Audits runtime state and ownership evidence. |
| `tools/asb_verify_device.sh` | Device-side verification workflow. |
| `tools/asb_field_report.sh` / `tools/asb_field_report.py` | Field-report orchestration and analysis. |
| `tools/asb_capture_compare.py` | Comparable-capture analysis rather than single-log intuition. |

### 🧯 13.3. Reading a failure

A practical order is:

1. **Reproduce** the issue and note the exact scenario.
2. **Check profile state** and whether a profile switch is still running.
3. **Compare requested and effective** values.
4. **Check ownership** for vendor clamps, leases and another applier.
5. **Check capability evidence** without converting missing evidence into unsupported hardware.
6. **Check pending reboot** for mount-, mixer- or boot-integrated changes.
7. **Inspect logs at appropriate verbosity**, then restore ordinary log detail after testing.
8. **Return to Stock or defaults selectively** to isolate the responsible subsystem.

Do not publish secrets, credentials, private configuration files or personal identifiers with a support report.

## 🧪 14. Extended captures and defensible A/B testing

### 🧾 14.1. Facts, hypotheses, recommendations

Extended reports separate three layers:

- **Facts:** sampled values, counters, transitions and observed events.
- **Hypotheses:** plausible explanations consistent with those facts.
- **Recommendations:** a next experiment or mitigation, not a guaranteed result.

An application appearing near a drain event is not sufficient to prove causation. A wakelock can be legitimate work; a process restart can be the result of another constraint; a network radio can be responding to poor signal rather than an app defect.

### ⚖️ 14.2. Comparable capture design

For a meaningful A/B comparison:

| Dimension | Required control |
|:---|:---|
| **Device state** | Same phone, firmware, kernel and root environment. |
| **Configuration** | Change one policy or a clearly defined group; record all other relevant settings. |
| **Workload** | Same app, activity, duration and user sequence as closely as practical. |
| **Network** | Same route, comparable signal, server and VPN state. |
| **Audio** | Same output, codec/offload state, DSP route and volume. |
| **Thermal** | Comparable starting temperature and ambient conditions; allow cooldown between runs. |
| **Battery** | Comparable starting charge, charging state and battery condition. |
| **Display** | Comparable brightness, refresh behaviour and screen-on time. |
| **Background** | Avoid updates, restores, backups and other unrelated heavy activity. |
| **Duration** | Long enough to include representative idle and active phases, not just a favourable burst. |

Repeat runs. Report spread and anomalies rather than selecting the best-looking capture. For screen-off drain, ensure the compared windows really have similar audio, navigation, VPN, charging and network activity.

### 🚫 14.3. What not to claim

Do not derive a universal battery-saving percentage from one before/after log. Do not call a lower average clock proof of better efficiency when work completed more slowly. Do not call higher benchmark throughput proof of better sustained user experience without heat and frame stability.

A good result names its scope: device, firmware, scenario, configuration, sample count and uncertainty.


### ♻️ 14.4. Infinite log across an Android framework restart (fix279)

A field capture stopped at the moment the Android framework restarted (SystemUI, the launcher and Bluetooth all came back within two seconds, the kernel kept running): the recorder shared the root manager's process session and died with the app processes without finalising, and the reboot-only resume never ran because the boot id had not changed. The recorder now starts in its own session (`setsid`, recorded as `session=` in `_recorder_cgroup.txt`). A recorder lost within the same boot reads `status=resuming reason=restart`; the five-minute service tick or the next opening of the log menu continues it on the same folder (`full-day-revive`), and the report lists such restarts separately from reboots, with the gap counted in no phase. While running, the SystemUI watch tells a whole-framework restart (`sys.system_server.start_count` changed) from a SystemUI crash. asbdiag prints the framework start count and time and counts `SYSTEM_RESTART`, `system_server_native_crash`, `system_app_crash` and `system_app_native_crash`, with the newest app crashes and their first non-platform frame.

## 🗂️ 15. Source-tree guide

```text
AutoSystemBoost/
├── action.sh                  Module action/status interface
├── apply_profile.sh           Profile application entry point
├── service.sh                 Late-start service and runtime orchestration
├── post-fs-data.sh            Early boot integration
├── uninstall.sh               Owned-setting restoration
├── common/                    Installer logic and localisation
├── config/                    Governor, ownership and generated bounds
├── profiles/                  Static profile policy definitions
├── runtime/                   Feature appliers, arbitration and state helpers
├── system/bin/                Installed command launchers and diagnostics
├── src/                       Native governor and DSP source
│   ├── asb_governor.c
│   ├── asb_fsm.h
│   ├── asb_smart.h
│   ├── asb_writer.h
│   ├── zygisk/                  Observer-only Zygisk module and bounded protocol
│   ├── DSP/
│   └── DSP_AIDL/
├── tests/                     Shell, Smart, system, WebUI and Zygisk regressions
├── tools/                     Discovery, diagnostics, reports and validation
├── webroot/                   WebUI and capability/configuration manifests
├── docs/                      Focused technical references
├── README.md                  English quick start
├── README.ru.md               Russian quick start
├── README.advanced.md         This guide
└── README.advanced.ru.md      Russian advanced guide
```

When changing a feature, update every copy or counterpart owned by the delivery contract. For example, `tools/asb_diag.sh` and `system/bin/asbdiag` must remain identical. Generated bounds, WebUI manifests, localisation and runtime schemas may have explicit consistency tests.

## 🛠️ 16. Building and regression validation

### 📦 16.1. Source-only archive

Run the complete source-only entry point from the repository root:

```sh
bash tools/asb_source_regression.sh
```

This wrapper enables `ASB_DSP_REFERENCE_OPTIONAL=1` for the full runner. Only absent DSP reference prebuilts become optional. Native governor checks, shell tests, WebUI tests, schema checks, runtime checks and the warning policy remain mandatory.

Source-only mode is not a “skip failures” mode and does not claim that DSP reference binaries were rebuilt.

### 🧱 16.2. Strict tree with DSP references

For a complete tree containing the DSP reference prebuilts:

```sh
bash tools/asb_full_regression.sh
sh tools/asb_tree_check.sh check --strict
```

The full runner prints its validation mode and DSP-reference strictness. Native warnings are checked against a warning budget/baseline so new warnings cannot be hidden casually.

### 🧼 16.3. Clean-archive verification

A final archive should be tested after restoring it into a clean directory, not only in the working tree:

```sh
unzip -tq AutoSystemBoost-source.zip
unzip -q AutoSystemBoost-source.zip -d clean-tree
cd clean-tree/AutoSystemBoost-main
sh tools/asb_tree_check.sh check --strict
bash tools/asb_source_regression.sh
```

Preserve executable permissions when constructing the source ZIP. Verify the file set, hashes and executable modes against the tested tree. A successful regression in another directory does not validate an archive that is missing files.

### ⚙️ 16.4. Native and DSP workflows

The governor and DSP have different build requirements:

- governor build/test workflows use the native sources under `src/`;
- the NDK release build compiles the observer/lifecycle `zygisk/arm64-v8a.so` and `zygisk/armeabi-v7a.so` from `src/zygisk/` and verifies both entry exports;
- DSP legacy/AIDL components use their own sources and build integration;
- AOSP/AIDL builds are separate from ordinary governor validation;
- do not label reference DSP binaries as locally rebuilt when they were not;
- do not weaken native warning checks to make a delivery pass.

### 🌐 16.5. WebUI checks

WebUI validation should cover real controls and visible pages, not hidden offscreen containers. At minimum, exercise:

- all five profiles;
- dark, light and their Liquid Glass variants;
- 320, 360 and 412 CSS-pixel phone widths;
- actual Config OFF/ON cards and switches;
- no horizontal overflow on visible content;
- no JavaScript runtime errors;
- settled computed styles after transitions, not intermediate animation frames.

A selector that does not exist or a page that was never made visible can produce a deceptively green harness. Tests must prove that they interacted with the intended element.

## ✅ 17. Contribution and regression checklist

Before submitting a behavioural change:

1. **State the contract.** What should happen, under which evidence, and what must remain unchanged?
2. **Identify the owner.** Avoid adding a second writer to an existing native, vendor or shell-owned path.
3. **Preserve profile identity.** Do not turn Battery, Balanced and Performance into aliases of Smart.
4. **Validate all input.** Check range and overflow before arithmetic; handle stale and duplicated samples.
5. **Handle missing evidence honestly.** Use unknown/not exposed semantics instead of confident guesses.
6. **Avoid universal device assumptions.** Do not introduce an SoC-specific writer or app-specific policy from one capture without sufficient evidence.
7. **Keep collection bounded.** No new persistent polling worker for device inventory or extended diagnostics.
8. **Protect privacy.** Never add serial, IMEI, account or network-identifier collection.
9. **Test success and refusal.** Include supported, missing, read-only, vendor-limited, overflow and stale-identity cases.
10. **Test atomic state changes.** Where publication uses temp-write plus rename, test replacement rather than only direct overwrite.
11. **Run the full regression.** Focused tests are useful during development, not a final substitute.
12. **Verify the exact archive.** Strict manifest, clean extraction, hashes, executable modes and regression must all agree.

Documentation changes should also preserve language parity, working cross-links, simple quick-start language and a clear separation between stable architecture and release history.

## 🔬 18. Field-test playbooks

A focused playbook turns a vague impression into a falsifiable result. Each test below starts with a known-good backup and ends by restoring ordinary log verbosity and any temporary experimental setting.

### 🧠 18.1. Smart and smoothness

1. Select Smart and allow enough ordinary use to establish a stable baseline.
2. Choose one repeatable interactive scenario, such as a fixed feed scroll or application launch sequence.
3. Record the native state, scenario, thermal condition, charge state and relevant feedback counters.
4. Produce a bounded jank condition if the scenario permits it; do not inject random settings writes to simulate learning.
5. Verify whether the hint was fresh and eligible, whether a native A/B window ran, and whether real frame evidence was re-read.
6. Repeat the same hint delivery to test deduplication and confirm that one window is not counted multiple times.
7. Test an atomically replaced feedback body and an unchanged body separately; compare checks, reads, changes and unchanged counters.
8. Attempt a fresh comparison during an ineligible thermal/charging/plateau condition and verify refusal rather than forcing a transition.

Pass criteria are not “Smart always boosts”. A correct result can be no change when evidence is insufficient, duplicated, stale or unsafe.

### 🧬 18.2. Topology and generated bounds

Test the discovery/synthesis/import path on 2-, 3- and 4-policy fixtures as well as a real device. Check every physical policy, not only the three familiar roles. A 2-policy big cluster must remain big, not become `extra`.

Change one provenance element at a time: full cluster signature, logical role, physical policy ID, writer slot, hardware maximum, OPP count and OPP endpoints. Both shell and native import must reject stale identity. Also test an absent OPP table represented by `0/0/0`; the result must remain explicit rather than becoming automatic unsupported hardware.

For synthesis, verify that ceilings never snap above the requested target and that inverted or malformed ranges fail closed. Do not use a production device as the first place to test malformed fixtures.

### 🌡️ 18.3. Thermal and writer ownership

Start at a comparable cool temperature and apply a repeatable sustained workload. Record state transitions, requested ceilings, effective ceilings, thermal source/confidence and vendor-owner evidence.

A useful test includes three phases: initial ramp, sustained operation and cooldown. Verify that `SUSTAINED` produces stable behaviour rather than continuous oscillation, that a stricter vendor clamp is not fought, and that ordinary policy resumes only when its gates permit.

If a lease or vendor backoff is active, do not interpret the lack of an ASB rewrite as a crashed governor. Capture the ownership state and wait for the defined handover/recheck path.

### 🔋 18.4. Battery and night behaviour

Compare equivalent screen-off windows with the same audio, navigation, VPN, charging and network conditions. Record starting/ending charge, temperature and duration, then inspect deep-idle classification and wake activity before changing Doze or wakelock policy.

Enable one aggressive control at a time. Test notifications, fitness tracking, background media, navigation and Google-dependent functions that matter to the user. Lower drain accompanied by broken required behaviour is not a successful universal recommendation.

For Auto Battery, cross the low-charge condition, charge again and verify previous-profile restoration without creating a profile-switch loop. For Charge-Aware, repeat while warm to ensure the thermal gate still wins.

### 🎧 18.5. DSP and audio routes

Test speaker, wired and Bluetooth independently. For each route, record `audio_profile`, `dsp_outputs`, loudness, tone settings, compressor/headroom, offload state and attach/ABI evidence.

Use the same audio material and comparable system/headset volume. Verify that `dsp_outputs=off` releases processing while preserving parameters, and that `eq_compat` leaves the stream to the external processor. Test first-enable reboot requirements separately from live parameter updates.

A screen-off Bluetooth battery test must be compared against the same Bluetooth route without ASB DSP. Otherwise a change in offload/CPU wake behaviour can be misattributed to the headphone, codec or music application.

### 🌐 18.6. Network and camera

For networking, select one route, disable unrelated background transfers and compare the same server and workload. Confirm the effective congestion control/qdisc on the actual interface. Include signal changes and VPN use as explicit variables, not footnotes.

For camera grading, reboot when required and capture a fixed scene set: daylight detail, portrait edges, macro texture, low light and high-contrast highlights. Look for halos, banding and unnatural colour as well as preferred sharpness. Camera performance hold should be evaluated during bursts/video without confusing image quality with capture responsiveness.

### 🔄 18.7. Update, Stock and uninstall

Before an update, export configuration and record learning/state expectations. Update through the normal manager path, reboot and verify compatible configuration migration, generated-bounds identity and pending-reboot indicators.

Switch to Stock and verify withdrawal of profile policy without assuming unrelated explicit tweaks were reset. Finally, test uninstall restoration in a controlled environment: owned baselines should be restored, mount-integrated behaviour should return after reboot, and no background diagnostic collector should remain.

### 🛰️ 18.8. Zygisk observer and pressure evidence

Start with `zygisk_enabled=0`, an empty allowlist and safe mode off. Add one non-critical test app, enable the observer, then start that app newly and inspect Device diagnostics: installed ABI, event state, validated live PID, start/disconnect counters and freshness must be described independently. Close the app and verify exit through peer disconnect; do not treat an immediately vanished process as an error in the collector. Repeat with safe mode on, an empty allowlist, a protected package and a stopped companion to verify fail-open behaviour without app or governor changes.

To evaluate the performance/energy role, keep the observer enabled in both arms and compare `zygisk_hints=0` against `1` on the same build, profile, app set and repeatable workload. Alternate A/B order, allow comparable thermal/battery starting conditions, and record launch/exit responsiveness, jank, temperatures, drain, `hints_accepted`, probe misses and ASB wakeups. Use repeated runs and medians rather than one attractive result; include the extra refresh/probe cost. Stop on worse smoothness, heat, drain or background behaviour. No universal saving percentage follows from the host tests or a single before/after capture.

For pressure, capture idle and repeatable busy states without leaving a collector running. Check the raw values, available weights, coverage and formula rather than only the colour. Hide or invalidate CPU/GPU fixtures in host tests to confirm renormalisation and the below-40 unknown result. A higher snapshot is not proof of poor device health, and before/after scores are not an A/B battery or performance measurement.

Host success is not sufficient for injection sign-off. Record the physical device, firmware, root/Zygisk implementation, ABI and reproducible result; use `unknown` or `not exposed` when those facts cannot be established.

## 🧯 19. Troubleshooting by subsystem

| Symptom | First checks |
|:---|:---|
| Selected cap is not the live clock | Governor state, thermal cap, vendor owner, OPP snapping, active lease and profile-switch settling. |
| Smart does not react to one jank event | Freshness, deduplication, scenario/charging/thermal gates, cooldown, plateau and native frame-window eligibility. |
| Battery feels slow in games | `bat_suppress_gaming`, Battery's own ranges, performance ceiling and thermal policy — this can be intended behaviour. |
| DSP setting has no audible effect | `dsp_loudness`, selected `dsp_outputs`, current route, `audio_profile=eq_compat`, attach/ABI evidence and required reboot. |
| Bluetooth playback drains more with DSP | Selected Bluetooth DSP route and A2DP offload/CPU processing state. |
| Camera change is saved but not visible | Pending reboot, mount namespace, generated tone table and camera-HAL effective file. |
| Network option does nothing | Actual route/interface, kernel algorithm/qdisc support, effective value and VPN state. |
| Notifications arrive late | Doze level/exemptions, wakelock/GPS action, background trimming, GMS and process-limit settings. |
| Device page lacks a capability fact | Treat as not exposed/not runtime-discoverable until stronger read-only evidence exists. |
| Report identifies a correlation only | Keep it a hypothesis; design a controlled repeat capture instead of assigning blame. |

## 🤝 20. Support and responsible disclosure

- 💬 [Telegram](https://t.me/DKomsomol)
- 🐛 [GitHub issues](https://github.com/krilikd-factory/AutoSystemBoost/issues)
- ⭐ [Project repository](https://github.com/krilikd-factory/AutoSystemBoost)

For a useful report, include the model, firmware, kernel, root manager, selected profile, changed settings, reproduction steps and `asbdiag`. For a performance or battery claim, include comparable captures and environmental conditions.

Never include passwords, authentication tokens, private keys, account data or personal hardware/network identifiers. Review generated reports before sharing them publicly.

<p align="center">
  <a href="https://paypal.me/lugaru46">
    <img src="https://img.shields.io/badge/PayPal-Support%20the%20project-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Support the project">
  </a>
</p>

## 🛡️ 21. Final boundary

ASB changes system behaviour on a rooted device. No adaptive policy can guarantee identical performance, temperature or battery results across devices and workloads. The module's serious features are not only its appliers: they are also its ownership rules, evidence gates, restore paths, diagnostics and willingness to report **unknown**.

<p align="center"><i>Measure the device. Own the change. Verify the result. Preserve the way back.</i></p>
