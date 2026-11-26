<img src="Resources/Assets.xcassets/AppIcon.appiconset/pigment-pass-256.png" width="128" height="128" alt="ChromaScan app icon">

# ChromaScan

A lightweight, pure **AppKit** macOS scanner app built for direct Wi-Fi **eSCL (AirScan)** scanning with full control over resolution (up to 1200 DPI), uncompressed RAW pixel streaming, hardware Brightness/Contrast, software tone curves, and **Display P3 / sRGB** ICC color management.

## Why ChromaScan?

macOS Image Capture tags scans from many AirScan printers (like the HP OfficeJet 3830) with legacy `Generic RGB Profile` (gamma 1.80) and pushes highlights brighter, making artwork and watercolors look washed out. ChromaScan talks directly to your scanner's eSCL endpoint:

- Streams uncompressed `application/octet-stream` RGB24 pixel data (zero JPEG compression artifacts) with `Intent=Photo`
- Uses `Accelerate` (`vImage` SIMD) + `ImageIO` to process 134 MP (1200 DPI) scans in tens of milliseconds
- Supports **Display P3 (Convert from sRGB)**, **Display P3 (Assign — Vivid)**, and **sRGB IEC61966-2.1**
- Exports 3-channel RGB24 (no wasted alpha channel) to **TIFF (LZW / Uncompressed)**, **PNG**, **JPEG**, and **HEIC** with proper DPI and ICC profile metadata

## Building & Self-Signing

ChromaScan keeps all personal signing details in a gitignored `Config/Local.xcconfig` file (included optionally by `Config/Base.xcconfig`), so you can fork and sign everything with your own Apple account without editing tracked files or causing merge conflicts.

### 1. macOS App Only (Zero Apple Account Needed)

Open `ChromaScan.xcodeproj` in Xcode and run the **ChromaScan** scheme, or build from the command line:

```bash
xcodebuild -project ChromaScan.xcodeproj -scheme ChromaScan -configuration Release build
```

*(If you modify `project.yml`, regenerate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen): `xcodegen generate`.)*

### 2. Mac + iOS Companion (Free Apple ID or Paid Account)

ChromaScan includes an iOS Companion target (`ChromaScanRemote`) that connects to your Mac over local Bonjour (`_chromascan._tcp`) and fires local scan-completion notifications out of the box.

Run the interactive signing helper (or copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`):

```bash
./scripts/setup-signing.sh
```

What this configures in gitignored `Config/Local.xcconfig`:

- `CHROMASCAN_TEAM_ID` — your 10-character Apple Team ID (auto-detected from Keychain if signed into Xcode)
- `CHROMASCAN_BUNDLE_ID_PREFIX` — a globally unique reverse-DNS prefix for your fork (e.g. `com.yourname.chromascan`)
- `CHROMASCAN_MAC_CODE_SIGN_IDENTITY` — defaults to `Apple Development` when a Team ID is set so macOS Keychain and Local Network permissions persist across rebuilds
- `CHROMASCAN_IOS_ENTITLEMENTS` — **left blank for free Apple IDs** ("Personal Teams"), because Apple only allows Push Notifications (`aps-environment`) on paid memberships

Then open `ChromaScan.xcodeproj`, select your iPhone, and build **ChromaScanRemote**. *(Note: Apple requires re-signing free-account iOS builds every 7 days.)*

### 3. Lock-Screen Push Notifications (Direct Mac → APNs, Paid Apple Developer Account)

For multi-minute 1200 DPI scans while your iPhone is locked, the Mac app can push directly to Apple's APNs HTTP/2 API using `CryptoKit` — no cloud server required:

1. **Enable the Push entitlement** in `Config/Local.xcconfig` (or answer Yes in `./scripts/setup-signing.sh`):
   ```xcconfig
   CHROMASCAN_IOS_ENTITLEMENTS = Resources/ChromaScanRemote.entitlements
   ```
   With Automatic Signing enabled, Xcode automatically registers your custom App ID with the Push Notifications capability — you do **not** need to manually create App IDs or provisioning profiles in the Apple Developer Portal.
2. **Create or reuse an APNs `.p8` key** at **Apple Developer → Certificates, Identifiers & Profiles → Keys** and download `AuthKey_<KEYID>.p8`. *(Apple caps teams at 2 APNs keys; reusing an existing APNs key from your team works seamlessly.)*
3. **Install the key on your Mac** (choose either option):
   - **Option A (CLI, zero UI clicks):**
     ```bash
     ./scripts/setup-apns.sh ~/Downloads/AuthKey_<KEYID>.p8
     ```
     This installs the key to `~/.config/chromascan/apns/` (`chmod 600`) outside git (legacy `~/.apns/` is also still supported as a fallback).
   - **Option B (Mac UI):** Click the **iPhone Companion** toolbar button → **Configure APNs…** and choose your `.p8` file. Key ID auto-fills from the filename; Team ID and iOS Bundle ID auto-fill from your signed build and paired iPhone.
4. Rebuild **ChromaScanRemote** to your physical iPhone, pair with your Mac, and click **Send Test Push** in the Companion popover to verify delivery.
