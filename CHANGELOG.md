# ASB V13.4

## Camera Stability Improvement

-   Fixed issue where "Document Scanner" mode would freeze after taking
    a photo.
-   Text Scanner mode remains fully functional.
-   No changes to core image quality pipeline.

This resolves the post-capture processing hang without affecting other
camera modes.

------------------------------------------------------------------------

## CPU and Thermal Adjustments

-   Improved uclamp tuning for better balance between performance and
    stability.
-   Added safe re-application of `sched_util_clamp_min=0` (only if supported by the kernel).
-   Prevents forced clamp-boost behavior on certain custom kernels.

Result: - More consistent frequency scaling - Reduced unnecessary heat
spikes - Better idle stability

------------------------------------------------------------------------

## GPU Optimization

-   Tuned `kgsl idle_timer` (when available).
-   Allows GPU to enter power-save state faster when idle.

Improves efficiency during light usage.

------------------------------------------------------------------------

## Summary

ASB V13.4 focuses on:

-   Fixing Document Scanner freeze
-   Improving thermal behavior on custom kernels
-   Maintaining overall system stability

Recommended for daily use.
