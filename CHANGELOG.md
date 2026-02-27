# ASB V13.5

## ðŸ“¸ Camera Fix -- Flash Fully Stable

Good news: camera flash is now completely fixed.

In previous builds: - V13.2 â†’ Flash sometimes caused camera crashes -
V13.4 â†’ Crash fixed, but flash photos had green tint

In V13.5: - No crashes - No green tint - Full image quality preserved

The internal Turbo RAW processing is kept for proper color and detail,
but the unstable flash bracketing mode has been safely removed.

Result: Stable flash + correct colors.

------------------------------------------------------------------------

## âš™ï¸ Custom Kernel (OP-WILD) Improvements

-   Automatic BBR detection
    -   Custom kernel â†’ BBR enabled
    -   Stock kernel â†’ cubic used automatically
-   sched_util_clamp_min is safely re-applied
    -   Prevents overheating caused by forced CPU boosting
    -   Restores proper dynamic frequency scaling

Idle temperature improvement observed: \~97Â°C â†’ \~40Â°C (custom kernel)

------------------------------------------------------------------------

## ðŸ”‹ Battery & Heat Improvements

-   Faster GPU power-save transition (idle_timer tuned)
-   Removed ineffective scheduler writes
-   Improved overall background efficiency

Real-world results: - Lower idle drain - Cooler device - More stable
performance

------------------------------------------------------------------------

## ðŸ§¹ Harmful System Tweaks Removed

Several properties that were hurting performance or stability were
removed:

-   GPU texture upload override (was increasing heat)
-   Broken per-app memory tracking
-   Disabled GL thread boost
-   Over-sensitive touch parameter
-   Incorrect FUSE passthrough configuration (now fixed)

This makes the system cleaner and more stable.

------------------------------------------------------------------------

## ðŸ›  Internal Cleanup

-   Removed dead code
-   Improved kernel parameter enforcement reliability
-   Minor stability adjustments

------------------------------------------------------------------------

## Summary

ASB V13.5 focuses on:

-   Stable camera flash
-   Proper image colors
-   Lower temperatures
-   Better battery behavior
-   Cleaner system configuration

This version is safe for daily use.
