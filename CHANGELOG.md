# ASB V15 - Changelog

This release refines V14 by improving stability, removing risky radio/Dolby forcing,
cleaning vendor config duplication, and focusing on predictable standby behavior
without sacrificing audio performance.

------------------------------------------------------------------------

## Audio

- Removed forced Dolby (music-oriented) property overrides.
  Surround / Spatializer flags remain enabled.

- Enabled Audio Keep-Alive for better Bluetooth stability:
  - vendor.audio.keep_alive.disabled: true -> false
  - vendor.audio.feature.keep_alive.enable: true

- 24-bit software decoders remain enabled (AAC / FLAC / MP3 / OPUS).

- MB DRC remains disabled for stronger peak dynamics.

- Game audio pipeline flags preserved.

------------------------------------------------------------------------

## Radio / IMS (Stability-Oriented Cleanup)

- Removed forced IMS / VoLTE / iWLAN / QoS property overrides.
- Removed vendor radio forcing flags from V14.
- Retained only safe data connection recovery flag.

Effect:
- Lower modem wakeups risk
- Better carrier-managed behavior
- Reduced standby instability risk

------------------------------------------------------------------------

## Wi-Fi

- Removed bundled vendor Wi-Fi configuration overrides (WCNSS / supplicant overlays).
- Preserved feature-level flags only:
  - MIMO
  - signal optimized
  - multi-P2P
  - supplicant_scan_interval=300

Effect:
- Better regulatory compliance
- Lower standby drain risk
- Fewer ROM conflicts

------------------------------------------------------------------------

## VM / I/O

- vm.dirty_expire_centisecs tuned: 6000 -> 3000
- vm.dirty_writeback_centisecs tuned: 5000 -> 3000

Effect:
- Smoother background writeback
- Reduced burst I/O spikes

------------------------------------------------------------------------

## Networking

- net.ipv4.tcp_slow_start_after_idle: 1 -> 0
- net.ipv4.tcp_fin_timeout: set to 30
- net.core.bpf_jit_enable: enabled

Effect:
- Faster network resume after idle
- Reduced connection tail latency

------------------------------------------------------------------------

## Vendor / ODM Consistency Fix (fix2)

- Unified duplicated vendor/odm config files:
  - audio_effects_config.xml aligned to ODM version
  - media_profiles_V1_0.xml aligned to ODM version

Effect:
- Eliminates config divergence risk
- Ensures consistent behavior across SKU paths

------------------------------------------------------------------------

## Cleanup

- Removed legacy packaging assets
- Removed unnecessary commentary blocks
- Module structure streamlined

------------------------------------------------------------------------
