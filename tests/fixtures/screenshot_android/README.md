# ASB screenshot test app (source only)

Requires a locally installed Android SDK platform 35, a compatible JDK, and Gradle
8.9 with Android Gradle Plugin 8.7.3. From this directory run `gradle :app:assembleDebug`;
install the resulting debug APK only on a test device. This directory is not a module
payload and no prebuilt APK is supplied. Network access may be needed for Gradle.

Use an ordinary local, unprotected video chosen via the system picker. Establish a
baseline with the fix off. Select this app in ASB, force-stop it from Android settings,
then cold-start it. Check the normal window, toggle FLAG_SECURE, choose video, and
exercise the secure SurfaceView and transaction controls, including during playback.
Open the secondary player process and repeat. The reflection-based transaction probes
may be blocked by Android hidden-API rules and report unavailable; unavailable is not
a pass. `SurfaceView.setSecure` is intentionally set before view attachment.

Record only saved / denied / black_video_only / black_entire_image / error / unknown.
The test app does not capture or export screenshots, video, accounts, or identifiers.
