ASB V13.4 Changelog
Camera Flash Crash Fix
Replaced oplus_camera_preview_decision_config.json — fixes camera crash when taking photos with flash enabled
Custom Kernel Compatibility (OP-WILD)
sched_util_clamp_min=0 reapplied every 20/60/180s — the #1 optimization (drops temps from ~97°C to ~40°C on custom kernel by restoring dynamic CPU frequency scaling). Guarded against PerfHAL resets.
BBR auto-detected — custom kernel has BBR, ASB uses it. Stock kernel uses cubic.
Battery/Heat Optimizations
GPU idle_timer 58ms (was 80ms stock) — GPU enters power-save 27% faster when unused
Removed dead WALT migration threshold writes — sched_group_upmigrate/downmigrate had no effect on either kernel (confirmed by diagnostics)
System.prop Deep Audit — Harmful Props Removed
Removed hwui.use_gpu_pixel_buffers=false — was forcing CPU texture uploads instead of GPU PBO DMA on Adreno 840v2. This wasted CPU cycles AND increased heat for zero benefit
Removed ro.config.per_app_memcg=false — was breaking per-app memory cgroup tracking, making PSI-based lmkd kill decisions less accurate
Fixed persist.sys.fuse.passthrough.enable — changed false→true. FUSE passthrough bypasses the FUSE daemon for direct filesystem reads, reducing IPC overhead on every file read
Removed persist.sys.gl_thread.boost.enable=false — was forcefully disabling OxygenOS GL render thread priority boost, potentially causing UI jank
Removed view.touch_slop=8 — 8 raw pixels at 3.5x density = 2.3dp, much more sensitive than stock 8dp=28px. Caused accidental/phantom touches
Code Cleanup
Removed broken migration threshold detection loop (dead code)
reapply_kernel_critical() function for periodic enforcement
sched_util_clamp_min retry count 1→3
Diagnostic Confirmation (Custom Kernel OP-WILD + ASB)
Temps: 93-97°C → 37-41°C (idle)
Current draw: 1689mA → 396mA (4.3x reduction)
Processes: 1303 → 1030 (-21%)
GMS: 44 → 22 (-50%)
Network: BBR + fq_codel active
ZRAM: lz4 → zstd
VM: dirty_background_bytes=16MB confirmed working
Usage stats: null (SuperQi fix confirmed)
