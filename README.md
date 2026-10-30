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
  <strong>📖 Documentation:</strong>
  <a href="README.md">Quick start</a> ·
  <a href="README.advanced.md">Advanced guide</a> ·
  <a href="README.ru.md">Быстрый старт</a> ·
  <a href="README.advanced.ru.md">Подробное руководство</a>
</p>

## ⚡ What is ASB?

**AutoSystemBoost is not a pack of random “speed” tweaks.** It is a root module that watches workload, temperature, battery level, charging and screen state, then applies behaviour appropriate to the moment.

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

## 🧠 How Smart works

Smart is more than a “fast / slow” switch. It combines workload evidence with app smoothness and previous comparable scenarios, then changes behaviour gradually.

| Smart considers… | Why it matters |
|:---|:---|
| 🕐 **Time and scenario** | Similar usage can repeat, but one time slot is never treated as proof on its own. |
| 📱 **Screen and workload** | Idle, scrolling, sustained work, gaming and camera use need different behaviour. |
| 🎞 **Smoothness** | Frame data can trigger a bounded comparison; a single jank hint does not directly rewrite system settings. |
| 🔋 **Charge and charging** | Low charge can favour efficiency, while a cool phone on a charger may safely have more headroom. |
| 🌡 **Temperature and thermal history** | A hot device needs restraint even if an older scenario favoured performance. |
| ✅ **Fresh, repeatable evidence** | Stale, duplicated or contradictory observations are not promoted into permanent rules. |

Safety outranks learning. Camera work and active games are not ordinary idle time; music, charging, navigation and VPN activity are not called deep sleep merely because the screen is off; missing evidence produces an **unknown** state, not an invented answer.

You can also set a manual **Performance Ceiling** to lower the selected profile's upper limit without abandoning that profile.

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
- scheduler debug accounting, ASB log detail and LSPosed verbose logging.

Availability depends on the device. A visible setting is a request, while diagnostics and effective values show what the system actually accepted.

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

Read **[README.advanced.md](README.advanced.md)** for the governor states, Smart evidence gates, device-bounds schema, thermal and writer ownership, the complete setting index, DSP architecture, diagnostics, source layout and regression workflow.

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
