# ASB V13.9 - Changelog

-   Telegram Doze whitelist removed for cleaner Doze policy (ACTIVE
    bucket + OEM rules are sufficient).

-   Refined VM writeback behavior for smoother idle current curve.

-   Network stack cleanup to reduce stale connection overhead.

-   No changes to audio pipeline, performance tuning, or camera
    behavior.

    ------------------------------------------------------------------------

## I/O Writeback Refinement

-   vm.dirty_expire_centisecs reduced (6000 → 3000).
-   vm.dirty_writeback_centisecs reduced (5000 → 3000).
-   Smaller writeback batches for smoother power draw during idle.

------------------------------------------------------------------------

## Network Stack Optimization

-   tcp_slow_start_after_idle disabled (1 → 0) for faster connection
    resume.
-   nf_conntrack_tcp_timeout_established reduced (600 → 300) for quicker
    stale connection cleanup.
-   tcp_fin_timeout reduced (60 → 30) for faster TIME_WAIT socket
    release.

------------------------------------------------------------------------

## Storage Read-Ahead Adjustment

-   read_ahead_kb for sd\* reduced (256 → 128).
-   Optimized for UFS storage: less unnecessary prefetch I/O without
    impacting performance.

------------------------------------------------------------------------
