# AutoSystemBoost --- V15.9 Changelog

**Device:** OnePlus 15 (CPH2745 · SM8750 · Adreno 840 · Android 16 /
OxygenOS 15)\
**Base:** V15.7 Stable\
**Release Type:** XML Refinement\
**Layer Modified:** Bluetooth stack only

------------------------------------------------------------------------

## V15.9 --- Bluetooth PCM Stack Stabilization

### Focus

Second-stage stabilization after the V15.7 power baseline.\
No scheduler edits. No VM edits. No Doze edits.\
Strictly Bluetooth XML correction and compatibility refinement.

------------------------------------------------------------------------

## Modified Files

### system/vendor/etc/bluetooth_qti.conf

### system/vendor/etc/a2dp_audio_policy_configuration.xml

------------------------------------------------------------------------

## Changes (XML Audio Layer)

  --------------------------------------------------------------------------
  Parameter / Section               Before       After       Purpose
  --------------------------------- ------------ ----------- ---------------
  PCM_24_BIT_PACKED profile         Not declared Enabled     Proper packed
                                                             24‑bit stream
                                                             handling

  Device port mapping               Partial      Expanded (3 Prevents
                                                 per         fallback &
                                                 profile)    renegotiation
                                                             loops

  Stream format negotiation         Implicit     Explicit    Cleaner HAL
                                                             routing
                                                             behavior
  --------------------------------------------------------------------------

------------------------------------------------------------------------

## Technical Explanation

OxygenOS Bluetooth stack may renegotiate stream format if packed 24‑bit
profile is not explicitly defined.

Adding proper PCM_24_BIT_PACKED entries:

-   Reduces fallback loops
-   Avoids unnecessary stream reconfiguration
-   Improves stability on high‑bitrate A2DP devices
-   Stabilizes BT DAC / LDAC / high‑quality sessions

This does NOT:

-   Increase volume
-   Modify DSP gain
-   Alter latency model
-   Change audio tuning

It is strictly a format‑handling correctness patch.

------------------------------------------------------------------------

## Confirmed Unchanged From V15.7

  Area                        Status
  --------------------------- -----------
  service.sh                  Unchanged
  Scheduler (WALT / uclamp)   Unchanged
  VM tuning                   Unchanged
  ZRAM configuration          Unchanged
  Doze model                  Unchanged
  Wi‑Fi DTIM logic            Unchanged
  GPS configuration           Unchanged
  GPU idle behavior           Unchanged
  statsd / stop‑list          Unchanged

------------------------------------------------------------------------

## Estimated Battery Impact (Mixed Day)

  Source                        Estimated Δ mAh/h
  ----------------------------- --------------------------------
  Fewer renegotiation wakeups   −0.1 to −0.3
  Reduced BT format fallback    −0.05 to −0.1
  **Total estimate**            **Negligible (\< −0.3 mAh/h)**

No measurable regression expected.

------------------------------------------------------------------------

## Version Progression Summary

  Version     Mixed Day       Full Charge      Key Focus
  ----------- --------------- ---------------- --------------------------
  V15.6       \~152 mA        \~45.6 h         Scheduler + DTIM
  V15.7       140.9 mA        49.2 h           Stability hotfix
  V15.8       \~139--140 mA   \~49.5--50.5 h   Wi‑Fi + GPS XML
  **V15.9**   \~139--140 mA   \~49--50 h       Bluetooth XML refinement

------------------------------------------------------------------------

## Bottom Line

V15.9 is a clean Bluetooth stack refinement on top of the V15.7 stable
baseline.

No experimental tuning.\
No aggressive power edits.\
No scheduler surprises.

Pure compatibility and format correctness improvement.
