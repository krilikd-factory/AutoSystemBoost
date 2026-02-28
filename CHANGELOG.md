# ASB V13.7 - Changelog

## Audio Improvements
Enabled high-quality PSD resampler for 44.1kHz content (better resampling to 48kHz).
Enabled 24-bit software decoders for AAC/FLAC/MP3/OPUS (where supported by the audio stack).
Enabled extended resampler and custom stereo features.
Enabled audio keep-alive and HAL output suspend support for faster and more reliable BT/TWS routing.
Increased offload pause timeout (0 → 3s) to reduce audio session drops during device switching.

## GPU / Idle Behavior
Removed forced GPU min_pwrlevel override to avoid potential kernel/ROM-specific side effects.

## Notes
Audio changes may slightly increase power usage during playback, while improving BT stability and sound quality.
