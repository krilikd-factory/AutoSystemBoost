# AutoSystemBoost — Changelog

<p align="center">
  <img src="https://img.shields.io/badge/Release-V53-16a34a?style=for-the-badge" alt="V53">
  <img src="https://img.shields.io/badge/Previous-V52-6b7280?style=for-the-badge" alt="V52">
  <img src="https://img.shields.io/badge/versionCode-530-0ea5e9?style=for-the-badge" alt="versionCode">
</p>

---

## V53 — *compatibility & cleanup*

A focused follow-up to V52: fixes a boot regression on OnePlus devices that share a flagship's chip, resolves an LSPosed conflict, and tidies the learner readout. No setting changes — flash over V52 and reboot.

### 🛠️ Boot fix for SoC-siblings (Ace 6 & others)
- V52's new per-device tuning matched purely on the SoC, so any OnePlus on the same chip as the 15/13/12 was handed the flagship's vendor overlay. On a different device (e.g. **OnePlus Ace 6**, codename `ktm`, same SM8750 as the 13) that overlay mismatched the HALs and **bootlooped** — which is why every pre-V52 build worked.
- Detection is now an **allowlist**: only the real `canoe` / `sun` / `pineapple` families get a device overlay. Every other OnePlus on those chips (Ace 6, Ace 5/3 family, 13T/13s, 15R/15T…) falls through to the generic-safe path — full governor tuning, no overlay, **boots on any sibling**.

### 🧩 LSPosed compatibility
- Removed the USAP app-process-pool props (`usap_pool_enabled` & friends). Force-enabling the pool makes processes fork past the zygote hook point, which sent **LSPosed into safe mode**. With them gone, LSPosed and ASB run together cleanly.

### 📊 WebUI learner readout
- The learner no longer shows "learning 0%" after a reboot. Session history was already restored, but the displayed confidence was only written on a live session commit; it's now seeded on load from the best persisted bucket, so the readout stays continuous.

> Cumulative on top of V52 — nothing removed. All settings and learned data carry across the update.
