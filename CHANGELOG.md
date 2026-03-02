# 🔧 ASB-15.9 — Changelog

> ✅ **Scope:** only **XML / INI / conf** files were changed.  
> 🚫 `service.sh` (runtime tweaks) **was NOT modified** in this update.

---

## 📌 Summary
V15.9 is basically:
- **All V15.7 connectivity + GPS refinements** (Wi‑Fi DTIM + GPS WIPER/outage behavior)
- **Plus a targeted Bluetooth audio upgrade**: adds `PCM_24_BIT_PACKED` profiles for wider device/port compatibility.

---

## 🗂️ Files changed
| File | Area | What changed |
|------|------|--------------|
| `module.prop` | Meta | Version bump to **V15.9** |
| `system/vendor/etc/a2dp_audio_policy_configuration.xml` | Bluetooth A2DP | Added `PCM_24_BIT_PACKED` profiles (per device port) |
| `system/vendor/etc/bluetooth_qti_audio_policy_configuration.xml` | Bluetooth (QTI) | Added `PCM_24_BIT_PACKED` profiles (per device port) |
| `system/vendor/etc/wifi/wcn7750/WCNSS_qcom_cfg.ini` | Wi‑Fi (wcn7750) | Telescopic DTIM + scan timer + runtime PM delay tuning |
| `system/vendor/odm/vendor/etc/wifi/WCNSS_qcom_cfg.ini` | Wi‑Fi (ODM) | Same Wi‑Fi tuning as vendor copy |
| `system/vendor/etc/gps.conf` | GNSS | WIPER disabled + outage window increased |
| `system/vendor/odm/etc/gps.conf` | GNSS (ODM) | Same GNSS tuning as vendor copy |

---

## 📶 Wi‑Fi (wcn7750): `WCNSS_qcom_cfg.ini` (both copies)
| Parameter | Before | After | Effect |
|----------|--------|-------|--------|
| `gEnableTelescopicDTIM` | `0` | **`1`** | More aggressive DTIM behavior **only when suspended** (helps standby drain without hurting screen‑on latency) |
| `gNeighborScanTimerPeriod` | `60000` | **`120000`** | Neighbor scan interval 60s → 120s (fewer periodic wakeups while connected) |
| `gRuntimePMDelay` | `5000` | **`2000`** | Faster runtime PM entry (less time idling in high-power “awake” state after activity) |

> ⚠️ **Safety note:** This is intended to be “standby‑leaning” and relies on your existing guard logic (`enable_mod_dtim_on_system_suspend=1`) so it doesn’t tank performance during active use.

---

## 🛰️ GPS: `gps.conf` (vendor + ODM)
| Parameter | Before | After | Effect |
|-----------|--------|-------|--------|
| `ENABLE_WIPER` | `1` | **`0`** | Disables WIPER (Wi‑Fi scan assist) → fewer Wi‑Fi → GPS cross‑wakeups |
| `GNSS_OUTAGE_DURATION` | `5` | **`30`** | Allows longer GNSS “off window” between fixes → fewer re-acquisitions / wakeups |

> **Note on `WIPER=0`:** Cold-fix may be ~1–2s slower in dense city environments. Navigation apps should remain fine (SUPL/PSDS still active).

---

## 🎧 Bluetooth audio: `PCM_24_BIT_PACKED` profiles (A2DP + QTI)
### What changed
Added **`PCM_24_BIT_PACKED`** profile blocks for **each** device port:
- `a2dp_in` (A2DP policy)
- `hearing_aid_in`, `bt_ble_in`, `bt_sco_in` (QTI policy)

### Why it exists
Some stacks/devices expose 24‑bit audio as **packed** instead of **24‑in‑32**. Without explicit profiles, Android may:
- fall back to a lower format,
- or do unnecessary conversions,
- or expose weird compatibility edge cases with certain BT pipelines.

### Expected result
- Better compatibility with more BT paths (especially QTI stack variants)
- Fewer format negotiation surprises
- Potentially cleaner path for high‑resolution audio where supported

---

## 🔋 Expected impact (realistic, not fairy tales)
| Scenario | Expected change |
|---------|------------------|
| **Night / screen-off standby** | **Better** (Wi‑Fi + GNSS periodic wakeups reduced) |
| **Daily mixed use** | **Neutral → slightly better** (no runtime behavior changed, mostly fewer background ticks) |
| **Bluetooth listening** | **More stable negotiation** (format support widened; battery impact negligible) |

---
