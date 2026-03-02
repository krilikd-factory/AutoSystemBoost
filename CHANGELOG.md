# AutoSystemBoost — Changelog

---

## [V15.2] — 2026-03-02

### 🐛 Bug Fixes
- **`tcp_slow_start_after_idle` 1 → 0** — restores TCP cwnd after idle; faster 5G SA reconnect with BBR
- **Removed `kgsl-3d0/min_pwrlevel=6`** — unblocks Adreno 840 deep-idle states (levels 7–8)
- **Removed `kgsl-3d0/bus_split=1`** — was absent in V13.3/V13.4; `idle_timer=80 ms` preserved

### ⚡ Network
- **`bpf_jit_harden=0` + `bpf_jit_kallsyms=1`** — restored from V13.4; zero-overhead BPF JIT for BBR/XDP
- **`rp_filter=0`** (all + default) — fixes CGNAT asymmetric-route drops on TIM Italy 5G SA
- **`ip_nonlocal_bind=1`** (IPv4 + IPv6) — completes rp_filter; enables Zapret / DPI bypass

### 🎮 CPU / Scheduler
- **`foreground uclamp.min` 8 → 15** — minimal UI floor, negligible battery cost
- **`top-app uclamp.min` 12 → 45** — V13.4 gaming floor; consistent 144 fps in CODM

### 🔇 Services (stop-list additions)
- **`midasd`** — Qualcomm analytics daemon, persistent wakelock eliminated
- **`batterysecret`** — OEM battery telemetry daemon, removes background I/O drain

### 🎵 Dolby Audio Pipeline (system.prop, +21 props)
Restored from V13.9 + new V14 spatial/game flags:
`vendor.audio.dolby.ds2.enabled`, `ro.dolby.music_stream`, `ro.vendor.audio.dolby.surround.enable`,
`ro.vendor.audio.dolby.spatial.profile=music`, `ro.vendor.audio.dolby.dax.game.enable`, and 16 others.

### 📡 Radio / IMS / PM (system.prop, +16 props)
- **Radio** `persist.radio.{power_save,add_power_save,data_no_toggle,NO_STAPA}=1`
- **IMS logs disabled** — 5 flags; saves background CPU on VoLTE standby
- **BT + Audio offload** — `persist.bluetooth.sbc_hd_higher_bitrate=1`, `audio.offload.min.duration.secs=31`
- **Charge / Display / PM** — `persist.vendor.accelerate.charge=true`, `ro.vendor.display.vivid_calibration.enable=1`, `dev.pm.dyn_samplingrate=0`

### ✅ Confirmed unchanged (not regressions)
| Parameter | Value | Note |
|-----------|-------|------|
| `vm.dirty_expire_centisecs` | 6000 | fewer writeback wakeups vs 3000 |
| `vm.dirty_writeback_centisecs` | 5000 | same rationale |
| `nf_conntrack_tcp_timeout_established` | 600 | stock default since V13.3 |

### 📊 File stats
| File | V15.1 | V15.2 | Δ |
|------|-------|-------|---|
| `service.sh` | 693 | 697 | +4 |
| `system.prop` | 1255 | 1297 | +42 |
| Unique prop keys | 1187 | 1224 | +37 |
| Duplicate props | 0 | 0 | ✅ |

---
