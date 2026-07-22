# Flutter Web fallback fonts

These 724 Noto WOFF2 files mirror the fallback URLs embedded in Flutter 3.44.2. The Roboto file is the CanvasKit default font from the same Flutter SDK. Keep the versioned paths unchanged because Flutter requests them directly below `fontFallbackBaseUrl`.

When upgrading Flutter, refresh this directory from the SDK's `font_fallback_data.dart` and `_robotoUrl`, then regenerate `SHA256SUMS`. The fonts are licensed under the included SIL Open Font License files.
