<img src="Resources/Assets.xcassets/AppIcon.appiconset/pigment-pass-256.png" width="128" height="128" alt="ChromaScan app icon">

# ChromaScan

A lightweight, pure **AppKit** macOS scanner app built for direct Wi-Fi **eSCL (AirScan)** scanning with full control over resolution (up to 1200 DPI), uncompressed RAW pixel streaming, hardware Brightness/Contrast, software tone curves, and **Display P3 / sRGB** ICC color management.

## Why ChromaScan?

macOS Image Capture tags scans from many AirScan printers (like the HP OfficeJet 3830) with legacy `Generic RGB Profile` (gamma 1.80) and pushes highlights brighter, making artwork and watercolors look washed out. ChromaScan talks directly to your scanner's eSCL endpoint:

- Streams uncompressed `application/octet-stream` RGB24 pixel data (zero JPEG compression artifacts) with `Intent=Photo`
- Uses `Accelerate` (`vImage` SIMD) + `ImageIO` to process 134 MP (1200 DPI) scans in tens of milliseconds
- Supports **Display P3 (Convert from sRGB)**, **Display P3 (Assign — Vivid)**, and **sRGB IEC61966-2.1**
- Exports 3-channel RGB24 (no wasted alpha channel) to **TIFF (LZW / Uncompressed)**, **PNG**, **JPEG**, and **HEIC** with proper DPI and ICC profile metadata

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open ChromaScan.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project ChromaScan.xcodeproj -scheme ChromaScan -configuration Release build
```
