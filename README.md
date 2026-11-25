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

## iOS Companion & Scan Completion Notifications

ChromaScan includes an iOS Companion target (`ChromaScanRemote`) that connects to your Mac over local Bonjour (`_chromascan._tcp`).

1. **Signing for your own iPhone:** Update `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` for `ChromaScanRemote` in `project.yml` (or in Xcode → Signing & Capabilities) to your own Apple Developer team and a unique bundle ID, then run `xcodegen generate` and build `ChromaScanRemote` to your iPhone.
2. **Local notifications (zero setup):** Out of the box, `ChromaScanRemote` fires a local notification when a scan finishes while the app is open or within iOS's ~30-second background grace period.
3. **Lock-screen push notifications (Direct Mac → APNs, optional):** For multi-minute 1200 DPI scans while your iPhone is locked, the Mac app can push directly to Apple's APNs HTTP/2 API using `CryptoKit` (no cloud server required):
   - Create an **Apple Push Notifications service (APNs)** `.p8` key at **Apple Developer → Certificates, Identifiers & Profiles → Keys** and download `AuthKey_<KEYID>.p8`.
   - **Option A (UI):** Click the **iPhone Companion** toolbar button in ChromaScan on your Mac → **Configure APNs…**, select your `.p8` file (Key ID auto-fills from the filename; Bundle ID auto-detects from your paired iPhone), enter your 10-character Apple Team ID, and click **Save**.
   - **Option B (`~/.apns/` auto-load, zero UI clicks):** Place `AuthKey_<KEYID>.p8` and a 1-line `~/.apns/apns.env` file (`APNS_TEAM_ID=<YOUR_TEAM_ID>`) in `~/.apns/` (`chmod 600`). ChromaScan automatically detects and uses them on launch without storing the key in git or the app bundle.
   - Click **Send Test Push** in the Companion popover to verify delivery.
