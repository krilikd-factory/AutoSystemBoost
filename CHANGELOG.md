# ASB V13.3

## Camera Fix - Flash Fully Stable

Camera flash is now completely fixed.

In previous builds: Flash sometimes caused camera crashes -

In V13.3: - No crashes - No green tint - Full image quality preserved

The internal Turbo RAW processing is kept for proper color and detail,
but the unstable flash bracketing mode has been safely removed.

Result: Stable flash and correct colors.

------------------------------------------------------------------------

## Custom Kernel (OP-WILD) Improvements

-   Automatic BBR detection
    -   Custom kernel -\> BBR enabled
    -   Stock kernel -\> cubic used automatically
-   sched_util_clamp_min is safely re-applied
    -   Prevents overheating caused by forced CPU boosting
    -   Restores proper dynamic frequency scaling

Idle temperature improvement observed: \~97C -\> \~40C (custom kernel)

------------------------------------------------------------------------

## Battery and Heat Improvements

-   Faster GPU power-save transition (idle_timer tuned)
-   Removed ineffective scheduler writes
-   Improved overall background efficiency

Real-world results: - Lower idle drain - Cooler device - More stable
performance

------------------------------------------------------------------------

## Harmful System Tweaks Removed

Several properties that were hurting performance or stability were
removed:

-   GPU texture upload override (was increasing heat)
-   Broken per-app memory tracking
-   Disabled GL thread boost
-   Over-sensitive touch parameter
-   Incorrect FUSE passthrough configuration (now fixed)

This makes the system cleaner and more stable.

------------------------------------------------------------------------

## Internal Cleanup

-   Removed dead code
-   Improved kernel parameter enforcement reliability
-   Minor stability adjustments

------------------------------------------------------------------------

## Summary

ASB V13.3 focuses on:

-   Stable camera flash
-   Proper image colors
-   Lower temperatures
-   Better battery behavior
-   Cleaner system configuration

This version is safe for daily use.
