# ASB-V15.3 — Changelog

---

## [V15.3] — 2026-03-02

### 🐛 Bug Fixes

| # | File | Change |
|---|------|--------|
| 1 | `service.sh` | **`apply_uclamp()`** — added `/sys/fs/cgroup/` write path for kernel 6.12+ (Android 15+). Retries 3→5, back-off 0.25→0.3 s. Fixes `top-app uclamp.min=45` not applying. |

### ⚡ Performance & Memory

| # | File | Parameter | Old → New | Reason |
|---|------|-----------|-----------|--------|
| 2 | `service.sh` | `vm.vfs_cache_pressure` | `70` → `50` | Reduces inode eviction, better cache hit for gaming/browser |
| 3 | `service.sh` | ZRAM `disksize` | `~7.4 GB` (dynamic) → `8192 MB` (fixed) | Consistent 8 GB ZRAM on 16 GB RAM; `zstd` preferred |

### 🌐 Network

| # | File | Change |
|---|------|--------|
| 4 | `service.sh` | `network_recommendations_enabled=0` re-applied at 30 s / 90 s / 300 s after boot (was boot-only — GMS could restore it) |

### ✅ Non-regressions (confirmed unchanged)

- `vm.dirty_expire_centisecs=6000`, `vm.dirty_writeback_centisecs=5000`
- `tcp_slow_start_after_idle=0`, `tcp_congestion_control=bbr`, `tcp_fastopen=3`
- `nf_conntrack_tcp_timeout_established=600`
- Dolby Audio pipeline props (37 entries from V15.2)
- Radio/IMS log-suppression props (V15.2)
- `midasd` + `batterysecret` in stop-list (V15.2)

### 📊 Statistics

```
service.sh:  697 → 715 lines  (+18)
Patches:     4 total
Syntax:      PASS (bash -n)
```

---

## [V15.2] — 2026-03-02

### Bug Fixes
- `tcp_slow_start_after_idle` reverted `1 → 0`
- GPU: removed `kgsl-3d0/min_pwrlevel=6` and `kgsl-3d0/bus_split=1`

### New Parameters (`service.sh`)
- Network: `bpf_jit_harden=0`, `bpf_jit_kallsyms=1`, `rp_filter=0`, `ip_nonlocal_bind=1`
- CPU: foreground `uclamp.min` 8→15, top-app `uclamp.min` 12→45
- Stop-list: added `midasd`, `batterysecret`

### New `system.prop` (+37 entries)
- 21 Dolby Audio props (`vendor.audio.dolby.*`, `ro.dolby.*`)
- 16 Radio/IMS props (`persist.radio.*`, `persist.ims.*`)

### Statistics
```
service.sh:   693 → 697 lines  (+4)
system.prop:  1255 → 1297 lines (+42)
Unique props: 1187 → 1224       (+37)
```

---
