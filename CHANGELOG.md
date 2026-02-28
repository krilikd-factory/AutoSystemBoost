# ASB V13.8 - Changelog

- Improved Telegram notifications: Telegram is added to Doze whitelist.
- Battery-friendly change: removed Google Play services (GMS) from Doze whitelist to reduce background wakeups.
- Audio keep-alive is enabled statically for better BT stability (no periodic dumpsys monitoring).
- UCLAMP tuning remains (works on stock kernels; on some custom WALT kernels it may be a harmless no-op).

  ------------------------------------------------------------------------

## Smart UCLAMP (Balanced)
- Foreground clamp is now balanced (not 0 / not 15) for better UI smoothness without constant boosting.
- Top-app clamp is set higher for responsive games/apps, background stays at 0.

------------------------------------------------------------------------

## Conditional Audio Keep-Alive
- Audio keep-alive is enabled only when BT A2DP is connected AND media is playing.
- When not playing, keep-alive is disabled to reduce background drain.

------------------------------------------------------------------------
