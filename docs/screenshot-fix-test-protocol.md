# Screenshot fix: controlled device checks

This protocol is a manual test, not evidence that any particular device passed it.
Use an Android 15–17 device, an enabled ASB Zygisk provider and a test application
owned by the tester. No capture image, account details or protected media contents
should be added to diagnostics. The current WebUI shows publication of the saved
policy; it cannot establish whether a process installed any JNI hook.

1. With the fix disabled, check that an ordinary window and ordinary local video in
   a `SurfaceView` can still be captured. Record this as the negative control.
2. In the owned test app exercise `FLAG_SECURE`, dynamic on/off changes, secure and
   skip-screenshot SurfaceControl layers, repeated flag changes during playback,
   and the same cases in `package:player`. Record baseline outcomes.
3. Select the test app in ASB, verify the policy is published, force-stop the app
   explicitly from Android settings, and cold-start it. Repeat every case. Do not
   regard a selected package as proof of injection or hook installation.
4. Disable the fix, explicitly force-stop and cold-start the app again; repeat the
   controls. Repeat with Safe mode. Existing windows can retain prior state until
   the application is restarted.
5. Separately, after selecting Netflix and performing a cold start, check the static
   UI, paused playback and active playback, then repeat after another cold start.
   Do not attach or export Netflix frames to ASB diagnostics.

For each case record only `saved`, `denied`, `black_video_only`,
`black_entire_image`, `error`, or `unknown`, together with device model, Android
version, ASB version and the policy-publication indicator. `saved` does not prove
that the video content was captured. A black rectangle alone does not prove DRM:
protected buffers, an app-side path outside these hooks, and OEM behavior all need
separate evidence. Do not attempt to weaken DRM, TEE, Widevine, HWC or protected
buffers. A physical ColorOS result must never be inferred from host tests.

No standalone controlled Android application is supplied by this change. A future
fixture needs source and build instructions for the cases in step 2; no prebuilt
APK should be shipped in the ASB module.
