# Playback screenshot audit

This is an app-side experimental path for explicitly selected applications. It does
not weaken DRM, protected buffers, TEE, HWC, HDCP, or protected composition. A black
video alone does not establish which boundary caused it.

## AOSP source evidence

The audit uses the fixed tags `android-15.0.0_r1`, `android-16.0.0_r1`, and
`android-17.0.0_r1`, not a moving branch:

- [Android 15 SurfaceControl.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/core/java/android/view/SurfaceControl.java), [SurfaceView.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/core/java/android/view/SurfaceView.java), [JNI registration](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/core/jni/android_view_SurfaceControl.cpp), [IWindowSession.aidl](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/core/java/android/view/IWindowSession.aidl), [WindowManager.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/core/java/android/view/WindowManager.java).
- [Android 16 SurfaceControl.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/view/SurfaceControl.java), [SurfaceView.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/view/SurfaceView.java), [JNI registration](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/jni/android_view_SurfaceControl.cpp), [IWindowSession.aidl](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/view/IWindowSession.aidl), [WindowManager.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/view/WindowManager.java).
- [Android 17 SurfaceControl.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/core/java/android/view/SurfaceControl.java), [SurfaceView.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/core/java/android/view/SurfaceView.java), [JNI registration](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/core/jni/android_view_SurfaceControl.cpp), [IWindowSession.aidl](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/core/java/android/view/IWindowSession.aidl), [WindowManager.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/core/java/android/view/WindowManager.java), [ViewRootImpl.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/core/java/android/view/ViewRootImpl.java).

| AOSP path | Audit result |
| --- | --- |
| Builder nativeCreate | All three versions register `(Landroid/view/SurfaceSession;Ljava/lang/String;IIIIJLandroid/os/Parcel;)J`; existing hook covers it. |
| Transaction setSecure / setSkipScreenshot | All three versions call nativeSetFlags `(JJII)V`; existing hook covers the Java/JNI path. SurfaceView applies setSecure to its BLAST layer. No separate registered JNI secure/skip setter was found in these source files. |
| Window add and relayout | SDK 35/36 declared methods taking attrs are already included. SDK 37 adds relayout2 and relayoutAsync2; ViewRootImpl calls them when `WindowManager.useClientSurface()` is true. This change includes those exact transaction fields on SDK 37 only. |
| LayoutParams serialization | At all three tags `writeToParcel` starts with width, height, x, y, type, flags in that order. That supports the field order, but does not prove OEM Binder object/token offsets or physical-device interception. Existing bounded parser and checks remain unchanged. |
| Native/OEM/protected playback | Not established by these Java/JNI sources. No additional backend is added without evidence. |

## Controlled checks

The optional source-only fixture at `tests/fixtures/screenshot_android` provides a
normal window, dynamic FLAG_SECURE, ordinary local video, secure SurfaceView at
creation, and repeated transaction calls where hidden API access is available. It
also starts the same activity as `package:player`. It has not been built or run here.
Hidden-API restrictions may reject its reflective SurfaceControl probes; the UI
reports this as unavailable, never as a passed test. No APK is bundled with ASB.

On a physical Android 15–17 phone: establish negative controls with the fix off;
select the fixture, force-stop it and cold-start it; exercise each window/layer
control before and during unprotected local video, including the secondary process;
then disable the fix, force-stop and retest. Separately check Netflix static UI,
paused playback, and active playback after a cold start, then repeat after another
cold start. Record each case only as `saved`, `denied`, `black_video_only`,
`black_entire_image`, `error`, or `unknown`. Do not attach Netflix frames to reports.
Neither a saved screenshot nor a black video proves a particular DRM path. No
physical ColorOS or Netflix result is claimed by these host tests.
