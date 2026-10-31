<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🇬🇧%20English-16a34a?style=flat-square" alt="English"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺%20Русский-1f2937?style=flat-square" alt="Русский"></a>
</p>

<h1 align="center">AutoSystemBoost</h1>

<p align="center">
  <img src="https://raw.githubusercontent.com/krilikd-factory/AutoSystemBoost/main/banner.png" alt="AutoSystemBoost" width="82%">
</p>

<p align="center"><strong>Fast when you need it. Cool and efficient the rest of the time.</strong></p>
<p align="center">Adaptive performance, thermal awareness, battery tools, a built-in DSP, camera tuning and honest diagnostics for rooted OnePlus devices.</p>

<p align="center">
  <img src="https://img.shields.io/badge/PROFILES-5-16a34a?style=for-the-badge" alt="Five profiles">
  <img src="https://img.shields.io/badge/GOVERNOR-NATIVE-0f766e?style=for-the-badge" alt="Native governor">
  <img src="https://img.shields.io/badge/SMART-ADAPTIVE-0ea5e9?style=for-the-badge" alt="Adaptive Smart">
  <img src="https://img.shields.io/badge/DSP-BUILT--IN-dc2626?style=for-the-badge" alt="Built-in DSP">
  <img src="https://img.shields.io/badge/WEBUI-INCLUDED-f59e0b?style=for-the-badge" alt="Integrated WebUI">
</p>

<p align="center">
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/releases/latest"><img src="https://img.shields.io/github/v/release/krilikd-factory/AutoSystemBoost?style=for-the-badge&logo=github&label=Latest%20release" alt="Latest release"></a>
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/releases"><img src="https://img.shields.io/github/downloads/krilikd-factory/AutoSystemBoost/total?style=for-the-badge&logo=github&label=Downloads" alt="Downloads"></a>
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/stargazers"><img src="https://img.shields.io/github/stars/krilikd-factory/AutoSystemBoost?style=for-the-badge&logo=github&label=Stars" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/🚀_Quick_Start-16a34a?style=for-the-badge&logo=github&logoColor=white" alt="Quick start"></a>
  <a href="README.advanced.md"><img src="https://img.shields.io/badge/🧠_Advanced_Guide-0f766e?style=for-the-badge&logo=github&logoColor=white" alt="Advanced guide"></a>
  <a href="README.ru.md"><img src="https://img.shields.io/badge/🇷🇺_Быстрый_старт-1f2937?style=for-the-badge&logo=github&logoColor=white" alt="Быстрый старт"></a>
  <a href="README.advanced.ru.md"><img src="https://img.shields.io/badge/🇷🇺_Подробное_руководство-334155?style=for-the-badge&logo=github&logoColor=white" alt="Подробное руководство"></a>
</p>

## ⚡ What is ASB?

**AutoSystemBoost is not a pack of random “speed” tweaks.** It is a root module that watches workload, temperature, battery level, charging and screen state, then applies behaviour appropriate to the moment.

Think of ASB as the **adaptive control layer at the heart of your OnePlus**: it connects profiles, the native governor, thermal policy, audio, camera, network, battery tools, the WebUI and diagnostics into one coordinated system instead of leaving you with a drawer of unrelated switches.

While the phone is idle, ASB tries to avoid unnecessary energy use. During games, camera work and demanding tasks, it keeps useful performance available. When the device becomes hot or the firmware does not expose a setting, ASB acts conservatively and reports the limitation instead of pretending that everything worked.

> **The goal:** not maximum speed at any cost, but a controllable balance between responsiveness, heat and battery life — with evidence you can inspect.

## ✨ Everything in one place

| Area | What ASB gives you |
|:---|:---|
| 🧠 **Smart adaptation** | Learns from validated usage scenarios, smoothness, time, charge and temperature; rechecks conclusions instead of trusting one lucky result. |
| 🎯 **Five profiles** | Smart, Performance, Balanced, Battery and Stock — from automatic adaptation to a clean firmware-controlled baseline. |
| ⚙️ **Native governor** | Six workload states, smooth transitions and device-specific CPU bounds rather than one fixed frequency table for every phone. |
| 🌡 **Thermal awareness** | Adaptive performance budgets, cooler sustained operation and explicit priority for the phone's own thermal protection. |
| 🔋 **Battery & sleep** | Automatic low-battery switching, charging-aware behaviour, Doze, wakelock, background GPS, memory and night-time controls. |
| 🎮 **Games & heavy work** | Responsive performance under real load, optional cool gaming, bounded prime-core boosts and camera performance hold. |
| 🎧 **Built-in DSP** | Loudness, bass, voice tone, clarity, stereo width, sub-bass filtering, compression, limiting and selectable output routes. |
| 🎵 **Playback & Bluetooth** | Audio profiles, Hi-Fi path, media loudness and volume steps, resampling, Bluetooth volume, link stability and audio offload. |
| 📷 **Camera** | Image grade, contrast and colour depth, natural grain, portrait processing, macro/low-light sharpening and capture responsiveness. |
| 🌐 **Network & Wi-Fi** | Per-route TCP and packet queues, buffers, transmit queues, packet distribution, Wi-Fi scans, power saving and bad-network fallback. |
| ✨ **Interface & haptics** | Animation speed, visual effects, blur, LTPO behaviour, vibration strength and touch feedback. |
| 🧩 **System controls** | Optional vendor-service, process-limit, scheduler-accounting, telemetry and diagnostic-log controls. |
| 📊 **Monitoring & reports** | Live state, effective limits, smoothness, drain, heat, night activity and extended on-demand reports. |
| 💾 **Configurations** | Named setups, backup, export, reset and separate management of Smart learning. |
| 🎨 **Polished WebUI** | Dark and light themes, Liquid Glass, 13 languages and phone-friendly layouts. |
| 🛡 **Safety & privacy** | Reversible changes, read-only on-demand device discovery and no serial number, IMEI, account or network identifiers in reports. |

## 🎯 Five clear profiles

| Profile | Choose it when… | What to expect |
|:---|:---|:---|
| ✨ **Smart** | You want ASB to adapt automatically. | Behaviour follows the scenario and evidence. It can become more responsive or more economical, but heat and safety gates still win. |
| 🔥 **Performance** | Maximum responsiveness matters most. | More headroom for demanding work and games, with potentially higher heat and battery use. It is not a promise to bypass hardware or firmware limits. |
| ⚖️ **Balanced** | You want a predictable everyday mode. | A practical mix of responsiveness and efficiency without constantly chasing maximum clocks. |
| 🔋 **Battery** | Battery life and lower heat are the priority. | Unnecessary performance peaks are restrained. Heavy tasks can take longer; Battery keeps its own policy rather than becoming another Smart mode. |
| 📱 **Stock** | You want a firmware baseline or a fair comparison. | ASB profile policy is withdrawn and the ROM's own behaviour is used. Explicit unrelated tweaks should be reviewed separately. |

**A good starting point:** choose **Balanced** for predictable behaviour or **Smart** for automatic adaptation. Use **Battery** when endurance matters more than speed.

## 🧠 Smart: the adaptive brain of ASB

Smart is not a timer that alternates between “fast” and “slow”. It is a layered decision system: it recognises the current situation, compares it with relevant history, estimates how much that history can be trusted, blends performance with efficiency and then lets live thermal and safety checks approve or overrule the result.

> **Smart does not merely select a profile name.** It can continuously shape the policy between Battery-like restraint and Balanced-like headroom, add a separate interactive allowance when it is justified, and withdraw that allowance as conditions change.

### 🛰 What Smart notices

| Signal or context | How Smart uses it |
|:---|:---|
| 🕐 **Six parts of the day** | Sleep, wake-up, morning, daytime, evening and late-night use can have genuinely different needs. |
| 📅 **Weekday or weekend** | The same hour on a workday and on a weekend is not automatically treated as the same scenario. |
| 🧭 **Workload and app context** | Idle, interaction, sustained work, games, camera and media receive different treatment; hints are checked against real activity. |
| 📱 **Screen state and off-time** | A brief screen-off pause, a longer inactive period and an extended idle stretch are different decisions, not one generic “screen off” action. |
| 🎞 **Smoothness evidence** | Fresh, relevant frame evidence can open a controlled A/B investigation instead of causing an immediate settings rewrite. |
| 🔋 **Battery level and drain history** | Low charge and repeatedly high drain can shift the balance towards efficiency, with hysteresis to avoid flapping. |
| 🔌 **Charging state and power class** | Charging can change the performance decision, but the type of charging and the current temperatures still matter. |
| 🌡 **Battery, SoC and surface temperatures** | Current heat can reduce or veto extra performance even when a learned scenario previously favoured it. |
| 📈 **Heating trend** | Rapid warming matters before a final temperature limit is reached; Smart can lean cooler early rather than waiting for an emergency. |
| 🧬 **The device's own thermal norm** | “Warm” and “cool” are judged relative to this device's sufficiently populated history, not one absolute temperature copied to every OnePlus. |
| 🔥 **Per-app heat and drain memory** | Repeatedly demanding app behaviour can inform bounded future decisions; old influence decays instead of becoming a permanent accusation. |
| 🧱 **Vendor clamps and previous sessions** | Platform limits, thermal debt and earlier sustained/clamped work can make the next decision more conservative. |
| ✅ **Confidence and freshness** | Smart asks not only “what happened?” but also “how often, how recently and how comparable was it?”. |

### 🎛 What Smart actually decides

| Decision layer | What can change |
|:---|:---|
| ⚖️ **Performance–efficiency blend** | Smart blends Battery-like and Balanced-like bounds instead of making a crude two-position jump. |
| 👆 **Interactive headroom** | Scrolling, launches and other interactive work can receive a separate bounded allowance without raising idle performance. |
| 😴 **Idle and sleep policy** | Idle bias and sleep bias help distinguish useful background work from unnecessary activity. |
| 🌐 **Network conservatism** | The learned efficiency preference can make related runtime policy more restrained when the scenario supports it. |
| 🏋 **Sustained pace** | Long workloads can favour a level the phone can maintain rather than repeated short bursts followed by harsh thermal correction. |
| 🚀 **Bounded prime-core escape** | A justified responsiveness escape can remain available within its gates; it is not an unlimited maximum-frequency mode. |
| 🛡 **Safety overrides** | Night, low-battery, hot-charging, plugged screen-off cooling, thermal-veto and recovery layers can narrow or cancel the performance request. |

### 🗂 How Smart learns without becoming superstitious

Smart keeps **12 scenario buckets**: six dayparts multiplied by weekday/weekend. Each bucket can remember effective observations and bounded tendencies for efficiency, interaction, idle, sleep and network conservatism, together with idle quality, wake activity, drain and maximum-temperature history.

An exact matching bucket is preferred. If it is not reliable enough, Smart deliberately falls back through broader context — daypart, weekday/weekend class, global history and finally a safe neutral baseline. It does not force a precise answer from insufficient data.

| Learning safeguard | Why it matters |
|:---|:---|
| 🧮 **Effective observations** | Repeated useful evidence carries more weight than a single encounter. |
| ⏳ **Freshness and decay** | Old behaviour gradually loses influence; a habit from weeks ago does not rule today's phone indefinitely. |
| 🌡 **Device-relative comparison** | Thermal history is compared with the same device's normal behaviour, reducing false conclusions from another model's “normal”. |
| 🧊 **Bounded influence** | Learned values move a decision within defined limits; they cannot erase hard thermal or vendor constraints. |
| 🔁 **Continuous revalidation** | A learned preference is a starting hypothesis for a similar scenario, not an unquestionable permanent rule. |

### 🎬 What this looks like in real life

| Situation | Smart's reasoning |
|:---|:---|
| ⏸ **Screen turns off briefly** | Avoid treating a short pause as proof of deep sleep; preserve a sensible return to interaction. |
| 🌙 **Long unplugged night idle** | When night context, screen-off state, battery level and absence of heavy work agree, favour a safer efficiency-oriented policy. |
| 🔻 **Battery becomes low** | Shift towards endurance with hysteresis, rather than switching back and forth around one percentage. |
| ❄️ **Cool device on a charger** | Charging-aware headroom may be allowed when the charging and thermal gates agree. |
| 🔥 **Phone gets hot while charging** | Hot-charge and plugged screen-off guards can remove extra headroom; charge assist never overrides safety floors. |
| 🎮 **Game starts heating rapidly** | Consider both current temperature and heating speed, then favour a sustainable rail before harsher correction is needed. |
| 🌆 **Similar evening usage repeats** | Relevant history can provide a better starting point, but only at the confidence and freshness the evidence deserves. |
| 🎞 **One isolated jank appears** | Deduplicate and qualify the hint; do not immediately rewrite policy or count the same observation repeatedly. |

### 🧘 Why Smart does not overreact

Smart combines **hysteresis, dwell time, cooldowns, confidence thresholds, freshness checks, evidence deduplication, scenario matching and plateau detection**. This is intentional intelligence: sometimes the smartest action is to hold a stable decision, wait for corroboration or admit that the answer is **unknown**.

Safety always outranks learning. Camera work and active games are not ordinary idle time; music, charging, navigation and VPN activity are not called deep sleep merely because the screen is off. Missing evidence produces **unknown**, **not exposed** or **not runtime-discoverable**, never an invented success.

Smart manages its performance/efficiency policy and related runtime decisions. It does **not** randomly rewrite your explicit DSP, camera or other user settings. You can also set a manual **Performance Ceiling** to lower the selected profile's upper limit without abandoning that profile.

## 🔋 Battery, sleep and background apps

| Tool | What it does | What to watch |
|:---|:---|:---|
| 🔻 **Auto Battery Profile** | Switches to Battery at low charge and can restore the previous profile after charging. | A profile switch changes performance behaviour, not only a menu label. |
| 🧭 **Smart Battery Bias** | Lets you ask Smart for a stronger efficiency preference. | More restraint can reduce peak responsiveness. |
| 🔌 **Charge-Aware Mode** | Allows more headroom while charging when thermal conditions permit. | Heat still limits behaviour. |
| 😴 **Deep Sleep / Doze** | Offers stock, night, moderate and aggressive idle timing. | Aggressive Doze can delay background work and notifications. |
| ✅ **Doze exemptions** | Can trim exemptions for eligible user apps. | Messaging, health and automation apps may need their exemptions. |
| ⏱ **Wakelocks & fitness** | Observes wake activity and offers optional action, with separate fitness-app handling. | Limiting the wrong app can break tracking, media or background tasks. |
| 📍 **Background GPS** | Can reduce unnecessary background location access. | Navigation and fitness apps need location when genuinely in use. |
| 🌙 **Quiet Night** | Reduces ASB's own optional work during the night window. | It does not mean disabling the phone's essential connectivity. |
| 📻 **Quiet Radio at Night** | Optional cellular/radio restraint during the configured night behaviour. | Connectivity and message delivery may change. |
| 🧹 **Memory & Google Services** | Controls cached-app retention, background trimming and selected Google components. | Stronger cleanup can cause reloads or delayed Google-app functions. |

These are tools for specific behaviour, not a list of switches everyone should enable. Start with defaults and change one group at a time.

## 🎧 Audio and the built-in DSP

ASB includes its own audio engine as well as system playback controls.

| Control group | Available options |
|:---|:---|
| 🔊 **Loudness & dynamics** | DSP loudness, compressor, peak limiting and adjustable output headroom. |
| 🎚 **Tone** | Bass boost, voice tone, clarity and an optional sub-bass filter. |
| 🎧 **Space** | Stereo-width processing for stereo content. |
| 🔀 **DSP Outputs** | Off, all, speaker, wired, Bluetooth or selected combinations — other tone settings are preserved when outputs are off. |
| 🎼 **Audio path** | Stock, external-EQ-compatible and Hi-Fi profiles, plus a separate Hi-Fi DAC mixer option where supported. |
| 🔉 **System volume** | Media loudness curves and media-volume step count. |
| 🎛 **Conversion quality** | Stock, high and maximum resampler settings for material that needs sample-rate conversion. |
| 🔗 **Bluetooth** | Shared or independent volume behaviour, link stability and automatic, hardware-offloaded or CPU audio encoding. |
| 🦻 **Listening safety** | The system headphone-volume limit remains untouched unless you explicitly change its separate setting. |

Compression and peak limiting help control extra gain. More bass still consumes headroom, and a sample-peak ceiling is not the same thing as an oversampled true-peak meter. DSP availability depends on the firmware, audio interface and current route: ASB checks the result rather than declaring an effect active from a configuration value alone.

> **A sensible start:** select only the output you use, then try moderate loudness and bass. Bluetooth processing can keep the CPU awake during screen-off playback. Sustained loud listening can permanently damage hearing.

## 📷 Camera

Camera grading starts from the phone's own stock files rather than values copied from another model.

- **Camera Grade** controls the overall processing strength.
- **Contrast & Colour Depth** changes the image's tonal character.
- **Film Grain** can restore some natural texture after heavy denoising.
- **Portrait AI** adjusts portrait-oriented processing.
- **Macro & Low-light Sharpening** is controlled separately from the general look.
- **Hold Performance While Camera Runs** helps preserve responsiveness during bursts and video.

Strong processing can reveal halos, banding, harsh edges or unnatural colour. Change settings gradually and compare the same scenes. Camera-file changes can require a reboot because mounted files cannot always be replaced live.

## 🌐 Network and Wi-Fi

| Area | What you can adjust |
|:---|:---|
| 🚀 **Download ramp** | Automatic, BBR or CUBIC TCP congestion control for Wi-Fi, mobile and other links when the kernel supports it. |
| 📦 **Packet queues** | Automatic, `fq`, `fq_codel` or `cake` queue selection per network type where available. |
| 🧠 **Network work** | Receive-packet distribution across CPU cores and transmit-queue length. |
| 🗄 **Buffers & recovery** | Conservative or aggressive network buffers and optional TCP MTU recovery. |
| 📶 **Wi-Fi** | Scan-rate restraint, power saving, region selection and optional fallback away from weak or unusable Wi-Fi. |
| 📱 **Mobile network** | Explicit radio controls, screen-off LTE behaviour, need-based 5G policy and quiet night operation. |

Automatic modes leave the decision to the firmware. ASB checks for a real interface and a supported value before changing it; submitting a command is not treated as proof of success. Network results still depend on the kernel, carrier, signal, router and remote server.

## ✨ Interface, haptics and system options

The **Interface** and **System** sections cover details that are easy to overlook:

- animation speed and touch timings, with an optional animation restart;
- blur and system animation effects;
- LTPO refresh behaviour and a low-refresh video option;
- vibration and touch-feedback strength;
- optional management of supported OEM RAM, battery and heat toggles;
- Athena background-killer behaviour, background process limits and multimedia telemetry;
- optional HeyTap MCS / OPPO Push disable, with notification risk and one ART compilation after the next reboot;
- a separate one-time DocumentsUI / DSU picker repair; ColorOS File Manager returns when the fix is turned off;
- scheduler debug accounting, ASB log detail and LSPosed verbose logging.

Availability depends on the device. A visible setting is a request, while diagnostics and effective values show what the system actually accepted.

## 🛰 Zygisk observer, lifecycle refresh and system pressure

**Observation and lifecycle hints are separate opt-in switches, both disabled by default.** The allowlist is empty, so no app process is selected until you explicitly add ordinary application packages and enable the observer. Selection affects newly started processes only; ASB does not kill or restart existing apps. Protected system, root-manager, LSPosed-manager and vendor processes are excluded.

The observer reports process start and exit derived from peer-socket disconnect. It does **not** install JNI/PLT hooks or claim foreground, media, camera, audio or navigation tracking: those events are `not exposed`. It does not manage apps, Zygisk, LSPosed or modules, and it has no frequency writer or application-policy opcode. Broker failure leaves the app and governor unaffected.

**Zygisk Lifecycle Refresh** gives those events a bounded performance/efficiency role without creating a second governor. An accepted start/exit can send the fixed `zygisk-refresh` request to the existing governor while the screen is on. The governor invalidates stale foreground evidence and re-evaluates the current profile; all dwell, thermal and vendor gates still decide the result. Requests are at least 2 seconds apart and capped at 8 per minute **per active companion**. No package name or frequency target is sent. This can reduce stale-input delay at lifecycle edges, but a hint acknowledgement is not a boost or proof of energy savings. LSPosed is never secretly killed, frozen, hidden or throttled; any saving requires comparable on-device A/B measurements.

You can manage it from **Device → Zygisk Observer**, or with these commands:

```bash
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh set-packages com.example.app'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh enable'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh status'
su -c 'sh /data/adb/modules/AutoSystemBoost/runtime/asb_zygisk.sh safe-mode on'
```

Use `safe-mode off` only to clear the emergency disable file; it does not re-enable the observer automatically. `disable` turns selection off for new processes, `list` shows the allowlist, and `set-packages` with no package names clears it.

**Device → System Pressure** shows a coloured 0–100 scale together with the actual measurements, formula, coverage and limitations:

| Component | Base weight | Measured component before weighting |
|:---|:---:|:---|
| Load average per online CPU | 35 | `clamp((loadavg_1m / online_cpus) × 50, 0, 100)` |
| Memory use | 30 | `memory_used = clamp((MemTotal − MemAvailable) × 100 / MemTotal, 0, 100)`; `clamp((memory_used − 40) × 2, 0, 100)` |
| CPU busy | 25 | Busy delta from two `/proc/stat` reads around a 0.20-second on-demand sample |
| GPU busy | 10 | A valid percentage or numerator/denominator from a supported readable `gpu_busy` interface |

The final score is `sum(component × available_weight) / sum(available_weights)`. Missing components receive zero weight rather than an invented value; coverage is the sum of available base weights. Below **40% coverage**, the score and band are `unknown`. Bands are **0–24 light**, **25–49 moderate**, **50–74 high**, and **75–100 very high**. Load average includes running/runnable and uninterruptible wait, so it is not CPU usage. Swap/zRAM occupancy is shown only as a supporting signal and is not scored.

This is a **single-snapshot pressure heuristic**, not a device-health score, trend or estimated battery/performance saving. Observer RSS is current application RSS for validated live PIDs, not pure observer overhead; `ipc_cpu_ms` covers companion receive/validation/state-write/hint-round-trip work, not whole-app CPU. Hint counters distinguish attempted, acknowledged, vetoed, unavailable and rate-limited requests. Crash and ANR counts remain `unknown` because attribution evidence is not exposed. Host regression tests validate the implementation contracts, but real Zygisk injection still requires testing on the target device and root implementation.

## 📊 WebUI: your control centre

| Page | What you will find |
|:---|:---|
| 🏠 **Profiles** | Profile selection, current state and quick access to the main behaviour. |
| 📈 **Monitor** | Workload, clocks, temperature, battery, Smart state, smoothness and the source of an effective limit. |
| ⚙️ **Config** | Audio, camera, interface, network, battery and system settings, grouped into readable sections. |
| 📱 **Device** | Processor, memory, root, kernel and capability information gathered read-only when requested. |
| 🧾 **Reports** | Diagnostic output and extended capture tools with facts, hypotheses and recommendations kept separate. |

The interface includes **13 languages**, dark and light themes, and **Liquid Glass**. Layouts are designed for narrow phones as well as larger screens. Metric colours indicate meaning, not decoration: unknown or warming-up data stays neutral instead of being painted as a success or failure.

Named configurations, backups, export to **Downloads** or **Documents**, and separate resets for settings and Smart learning are built in.

## 🧾 Reports that do not jump to conclusions

On demand, you can record an extended session and inspect smoothness, drain, night activity, heat and ASB's own cost. The report distinguishes:

1. **Facts** — values and events actually observed.
2. **Hypotheses** — possible explanations that still need confirmation.
3. **Recommendations** — next steps, not guaranteed fixes.

ASB does not blame an app because of one coincidence or promise a battery-saving percentage without comparable field measurements. Detailed collection is user-triggered; there is no permanent extended-capture process running in the background.

## 🛡 Safety and privacy

- **The platform stays in charge.** Stock thermal protection and platform limits are not disabled.
- **Changes are reversible.** ASB stores baselines and restores its owned settings when uninstalled.
- **No system-partition writes.** Work uses root-module mechanisms and exposed system interfaces.
- **No borrowed frequency tables.** Capabilities and bounds are derived from the current device and validated before use.
- **No false success.** Requested, effective, unavailable and unknown states are different things.
- **Updates preserve choices.** Compatible configurations migrate with a backup.
- **Device discovery is read-only and on demand.** It does not create a persistent device-inventory collector.
- **Unnecessary identifiers stay out.** Serial numbers, IMEI, account data and network identifiers are not read for reports.

## 📱 Compatibility

ASB is designed for **OnePlus, including Ace models**, with root access and a compatible module manager: **Magisk, KernelSU, APatch** and supported derivatives.

Recent OnePlus devices have the most field validation. On other models, feature availability depends on firmware, kernel, exposed interfaces and the current route or service. If evidence is not exposed, ASB should say **unknown**, **not exposed** or **not runtime-discoverable** — that is not proof that the hardware itself is unsupported.

## 📦 Installation and first steps

1. Download the regular **Release ZIP** from the releases page.
2. Install it in your module manager and reboot.
3. Open the module's **WebUI**.
4. Choose **Balanced** or **Smart**.
5. Keep optional settings at their defaults and observe the phone first.
6. Change one group at a time and check **Monitor**, **Action** or an extended report.
7. Save a named configuration once you have a setup worth keeping.

<p align="center">
  <a href="https://github.com/krilikd-factory/AutoSystemBoost/releases/latest">
    <img src="https://img.shields.io/badge/⬇️_Download_Release-0969da?style=for-the-badge&logo=github&logoColor=white" alt="Download AutoSystemBoost">
  </a>
</p>

> Do not install multiple ASB builds at the same time. Use the normal module-update path when testing another build.

## 🩺 If something goes wrong

Open **Action** on the module card to see live status and settings that were not applied. For a detailed diagnostic report, use **Reports** in the WebUI or `asbdiag`.

```bash
su -c 'asb status'
su -c 'asb reload'
su -c 'asbdiag'
```

If a result looks wrong, check whether it is **requested**, **effective**, **temporarily vendor-limited**, **not exposed** or **unknown**. When asking for support, include the phone model, firmware, root manager, a reproducible description and the diagnostic report. Do not publish personal information.

## 🧑‍💻 Want the technical details?

Open the advanced guide for the governor states, Smart decision layers and evidence gates, device-bounds schema, thermal and writer ownership, the complete setting index, DSP architecture, diagnostics, source layout and regression workflow.

<p align="center">
  <a href="README.advanced.md"><img src="https://img.shields.io/badge/🧠_Open_the_Advanced_Guide-0f766e?style=for-the-badge&logo=github&logoColor=white" alt="Open the advanced guide"></a>
</p>

For source archives, the main validation entry point is:

```sh
bash tools/asb_source_regression.sh
```

## ⭐ Support the project

- 💬 [Telegram](https://t.me/DKomsomol)
- 🐛 [Report an issue on GitHub](https://github.com/krilikd-factory/AutoSystemBoost/issues)
- ⭐ Star the repository

<p align="center">
  <a href="https://paypal.me/lugaru46">
    <img src="https://img.shields.io/badge/PayPal-Support%20the%20project-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Support the project">
  </a>
</p>

## ⚠️ Important

This module changes system behaviour on a rooted device. Use it at your own risk. Results depend on the phone, firmware, apps, signal quality, temperature and usage pattern. ASB does not promise the same battery or performance improvement on every device.

<p align="center"><i>No magic and no random tweaks — adaptation, control and verifiable results.</i></p>
