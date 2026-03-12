Prebuilt governor binaries are produced by GitHub Actions.
Release zips should contain:
  bin/arm64-v8a/asb_governor
During install the module copies the matching prebuilt to:
  bin/asb_governor
If no prebuilt is present, ASB falls back to shell mode.
