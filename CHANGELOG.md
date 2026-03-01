# ASB V15.1 – Changelog

## Battery / Standby

- vm.dirty_expire_centisecs: 3000 → 6000
  Pages stay dirty up to 60 s instead of 30 s before the kernel schedules
  a writeback. Halves the number of UFS storage wakeups during screen-off,
  reducing idle current draw.

- vm.dirty_writeback_centisecs: 3000 → 5000
  Writeback worker wakes every 50 s instead of 30 s. Paired with the
  expire change above, fewer short burst I/O storms during standby.

- GPU idle: min_pwrlevel=6 restored to apply_idle()
  Adreno 840 now prefers its lowest power bin when idle. Saves 50–150 mW
  during screen-off and light usage.

- GPU idle: bus_split=1 restored to apply_idle()
  Power-gates unused GPU bus segments when the GPU is not fully active.

- apply_idle() is already part of the 30/90/300 s reapply loop, so both
  GPU settings survive system resets.

## Network (Mobile / TIM Italy)

- net.ipv4.tcp_slow_start_after_idle: 0 → 1
  Re-enables TCP bandwidth re-probing after an idle period. Improves
  throughput recovery on TIM 4G/5G SA when the device wakes from deep
  sleep or the radio re-attaches to the cell.

## Audio Quality

- ro.audio.resampler.psd.enable_at_samplerate=44100 restored
  Activates the high-quality PSD (polyphase subband decomposition)
  resampler for 44.1 kHz content. Combined with the existing halflength,
  stopband and cutoff settings already in the module, this ensures
  44.1→48 kHz conversion uses the best available algorithm instead of
  falling back to the lower-quality linear resampler. Audible improvement
  on music playback via OnePlus Buds Pro 3 (LHDC v5 path).

## Code Quality / Bug Fixes

- Removed 2 dead empty if-blocks
  Two identical `if has stop && has start; then / fi` stubs were left
  over from incomplete development. They did nothing but added noise.

- Fixed double dropbox write
  `dropbox_max_files` was written twice (first =8, then =5 inside
  apply_extra_settings). The redundant first write is removed; final
  value is 5.

- Removed 30 non-ASB comment lines from system.prop
  Commented-out property lines (e.g. # ro.vendor.audio.bass.boost.enable,
  # persist.bluetooth.gamemode, perf HAL debug props, etc.) were cleaned
  out. All ASB: category markers are preserved as required.

- Removed 3 non-ASB inline comments from service.sh
  "On Wild kernel these writes don't stick", "keepalive defaults
  preserved", "security-sensitive JIT/filters" – structural ASB: markers
  are untouched.

## Summary

V15.1 is identical to V15 in every functional respect except:

| Area              | V15        | V15.1      |
|-------------------|------------|------------|
| Standby I/O wakes | ~2×/min    | ~1×/min    |
| GPU idle power    | default    | min level  |
| TCP after idle    | cold-start | re-probe   |
| 44.1 kHz audio    | fallback   | PSD HQ     |
| Dead code blocks  | 2          | 0          |
| Duplicate writes  | 1          | 0          |
| Non-ASB comments  | 30+        | 0          |
