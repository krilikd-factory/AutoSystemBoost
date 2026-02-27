# ASB V13.1 Changelog

## Bug Fixes
- **Fixed document scanner freeze** — disabled aggressive camera memory compaction (`micompactmemory`) that was blocking the document rectification pipeline after capture
- Fixed ACDB scheme prop (changed to false — debug feature, not needed for production)
- Added MTU cleanup in post-fs-data to let kernel auto-negotiate (prevents cellular data issues)
- Added A2DP offload unblock and media resolution limit removal in post-fs-data
- Removed hidden API policy settings (For banking apps)

## Battery Improvements
- **Radio power save** — modem power management and signal optimization
- **BT sniff mode** — reduces BT idle power consumption
- **BT LE scan throttling** — less BLE wake-ups during background scanning
- **Audio DSP offload power save** — offloads audio processing to DSP, saves CPU power
- **ZRAM zstd compression** — better compression ratio, less I/O, less battery drain
- **Fuel gauge telemetry reset** — persistent background loop to prevent telemetry re-enable
- **Disabled netstats/app_usage** — reduces background stat collection overhead
- **LMK PSI-based tuning** — smarter memory management, less aggressive killing

## Audio Quality Improvements
- **DTS Eagle spatial audio** — hardware-accelerated spatial processing
- **Ultra-low latency priority** — real-time priority for ULL playback
- **SBC HD & lossless BT** — higher bitrate SBC and lossless A2DP support
- **LHDC v5 support** — latest LHDC codec version
- **AptX Adaptive R2** — R2.1/R2.2/R2.3 support for compatible headphones
- **Super Wide Band BT calls** — better call quality on supported headsets
- **ABR disabled** — maximum constant bitrate for BT audio quality
- **Codec latency optimization** — A2DP latency-aware routing
- **Safe media bypass** — removes volume warning for headphones
- **Stagefright media pipeline** — deep/direct audio, HW codec thumbnails
- **Spatial audio** — spatializer support with speaker output
- **BT profiles** — comprehensive profile support (A2DP, AVRCP, HFP WBS, LE Audio, etc.)

## Network Improvements
- **IPv6 privacy extensions** — multicast/anycast ignore, proxy NDP, source route blocking
- **Hidden API unlock** — better app compatibility
