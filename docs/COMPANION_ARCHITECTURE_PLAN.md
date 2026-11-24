# ChromaScan Companion Architecture Plan (Mac Studio Host + iPhone Lite Client)

## Overview

Instead of running heavy 1200 DPI RAW scanning and image processing directly on an iPhone (where ~1.6–2.2 GB transient memory spikes risk iOS Jetsam kills and iOS app suspension breaks multi-minute Wi-Fi eSCL streams), ChromaScan will adopt a **Host + Lite Companion** model:

- **Mac Studio Host (`ChromaScan`):** Owns Bonjour eSCL scanner discovery, raw uncompressed `application/octet-stream` downloads, full-resolution pixel buffers (`~404 MB` at 1200 DPI Letter RGB24), `Accelerate`/`vImage` Display P3 conversion, and archival TIFF/PNG/JPEG/HEIC export directly to local disk.
- **iPhone Lite Client (`ChromaScanRemote`):** Discovers the Mac Studio automatically over Bonjour (`_chromascan._tcp`), displays a color-managed Display P3 preview with touch crop handles, triggers Preview / Scan / Export, syncs settings bidirectionally with the Mac window, and fetches crisp 1:1 viewport tiles on demand when pinch-zooming.

### Key Benefits
- **Low iPhone RAM (~30–60 MB):** Only lightweight proxies (`~150–350 KB` HEIC/JPEG) and visible 1:1 cropped tiles cross the LAN.
- **Survives iPhone Screen Lock:** The Mac Studio owns the HTTP stream to the scanner; you can pocket or lock the iPhone during a 2–6 minute 1200 DPI scan and reconnect seamlessly.
- **Better Physical Workflow:** Stand at the flatbed scanner with your iPhone to frame artwork, crop, and trigger 1200 DPI scans while files land directly in your Mac Studio archive folder.
- **Zero Third-Party Dependencies:** Built purely on Apple frameworks (`Network`, `Foundation`, `CoreGraphics`, `ImageIO`, `Accelerate`, `AppKit`, `SwiftUI`/`UIKit`).

---

## Target Project Structure (`project.yml`)

Reorganize sources into three clean groups managed by XcodeGen so macOS and iOS targets share models, protocol definitions, and image pipeline code without duplication:

```text
Sources/
  Core/                         # Shared by macOS + iOS targets
    Models.swift                # Add Codable to shared value types
    ImagePipeline.swift         # Full pipeline on Mac; optional local proxy LUT/P3 on iOS
    CompanionProtocol.swift     # Shared JSON messages + binary frame header + constants

  MacHost/                      # macOS target (ChromaScan)
    ESCLClient.swift
    ESCLXMLParser.swift
    BonjourScannerBrowser.swift
    AppPreferences.swift        # + companionServerEnabled, pairingPIN, keepRunningInMenuBar
    ScanSessionEngine.swift     # Headless @MainActor state machine extracted from MainWindowController
    CompanionServer.swift       # NWListener + NWProtocolWebSocket + _chromascan._tcp Bonjour advertiser
    AppDelegate.swift           # + optional NSStatusItem menu bar mode
    MainWindowController.swift  # Thin AppKit observer/controller bound to ScanSessionEngine
    InspectorViewController.swift
    PreviewCanvasView.swift
    StatusFooterView.swift
    main.swift

  iOSCompanion/                 # iOS 17+ target (ChromaScanRemote)
    ChromaScanRemoteApp.swift
    HostBrowser.swift           # NWBrowser for _chromascan._tcp + manual host/IP fallback
    CompanionClient.swift       # Persistent NWConnection WebSocket client + auto-reconnect
    RemoteSessionStore.swift    # @Observable @MainActor mirror of Mac SessionSnapshot
    RemoteCanvasView.swift      # UIScrollView + UIImageView (120 Hz ProMotion) + touch crop handles
    RemoteControlsSheet.swift   # Bottom sheet mirroring Capture, Tone, Color & Output controls
    PairingView.swift           # 6-digit PIN entry + Keychain token storage

Tests/
  ChromaScanTests.swift
  CompanionProtocolTests.swift
  ScanSessionEngineTests.swift
```

---

## Step 1: Extract Headless `ScanSessionEngine` (Mac Refactor)

Currently, `MainWindowController` directly owns scanner discovery, capabilities, image buffers (`rawPreviewBuffer`, `rawScanBuffer`, `rawScanProxyBuffer`, `renderedFullScanImage`), and scan/export tasks.

Extract a headless `@MainActor final class ScanSessionEngine` that becomes the single source of truth for **both** the AppKit UI and `CompanionServer`:

- **Owned State:**
  - `scanners: [DiscoveredScanner]`, `selectedScannerID: String?`, `capabilities: ScannerCapabilities?`, `scannerStatus: ScannerStatus?`
  - `settings: ScanSessionSettings` (source, resolution, colorMode, intent, transferFormat, rotation, hardwareBrightness/Contrast, colorProfile, outputFormat, quality, previewCompressionEnabled, toneAdjustments, baseFilename, autoIncrement)
  - `cropRect: NormalizedCropRect`, `viewMode: CanvasViewMode`, `isBusy: Bool`, `lastSavedURL: URL?`
  - `rawPreviewBuffer`, `rawScanBuffer`, `rawScanProxyBuffer`, `renderedFullScanImage`, `fullScanRenderSignature`
- **Owned Operations:**
  - `refreshScanners()`, `selectScanner(id:)`, `addManualScanner(host:port:useTLS:)`
  - `updateSettings(_ patch:)`, `setCropRect(_:)`, `setViewMode(_:)`
  - `startPreview()`, `startScan()`, `cancelActiveOperation()`, `exportCurrentScan(to customURL:)`
  - `encodeActiveProxy(maxDimension:format:quality:) async -> EncodedCompanionImage?`
  - `encodeHighResTile(normalizedRect:maxPixelWidth:) async -> EncodedCompanionImage?`
- **Power & Sleep Protection:**
  - Wrap active scans/exports with `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "ChromaScan active scan")` so macOS App Nap or idle sleep never interrupts a scan started from the iPhone.
- **Live Bidirectional Sync:**
  - Expose an event stream (`AsyncStream<SessionEvent>` or delegate/observer list) so both `MainWindowController` and `CompanionServer` immediately reflect changes regardless of which device triggered them.

---

## Step 2: Discovery, Transport & Wire Protocol (`CompanionProtocol.swift`)

### Discovery
- **Service Type:** `_chromascan._tcp` in domain `local.`
- **Mac Studio:** Advertised automatically via `NWListener.Service(name: hostName, type: "_chromascan._tcp", txtRecord: ...)`, using an OS-assigned ephemeral port (no port conflicts).
  - TXT record metadata: `v=1`, `id=<hostUUID>`, `scanner=<selectedScannerName>`
- **iPhone:** Discovered via `NWBrowser(for: .bonjourWithTXTRecord(type: "_chromascan._tcp", domain: "local."))`, plus a manual `host:port` fallback for Tailscale/VPN use.
- **Info.plist Requirements:**
  - macOS: Add `_chromascan._tcp` alongside `_uscan._tcp` and `_uscans._tcp` in `NSBonjourServices`.
  - iOS: Set `NSLocalNetworkUsageDescription`, `NSBonjourServices: ["_chromascan._tcp"]`, and `NSAppTransportSecurity.NSAllowsLocalNetworking = true`.

### Transport
- Single persistent WebSocket connection using Apple's native **`NWProtocolWebSocket`** over `NWListener` (macOS) and `NWConnection` (iOS).
- Set `maximumMessageSize = 16 * 1024 * 1024` (16 MB) to comfortably carry high-quality Display P3 proxy/tile frames.
- **Pairing & Auth:**
  - Mac Studio generates a 6-digit pairing PIN (displayed in a toolbar Companion popover).
  - On first connect, iPhone sends `hello(pin:)` → Mac validates PIN and returns a persistent random 256-bit `authToken` stored in Keychain for frictionless future reconnects.
  - Phase 2 hardening: Wrap the socket in `NWProtocolTLS` using PSK derived from the shared pairing secret so scan previews are encrypted on shared Wi-Fi networks.

### Message Framing

#### 1. JSON Text Frames (`ClientMessage` → Host)
```json
{ "type": "hello", "protocolVersion": 1, "clientName": "Chris's iPhone", "pin": "482910" }
{ "type": "selectScanner", "scannerID": "..." }
{ "type": "refreshScanners" }
{ "type": "updateSettings", "patch": { "resolution": 1200, "colorProfile": "p3_convert" } }
{ "type": "setCropRect", "cropRect": { "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.7 } }
{ "type": "setViewMode", "mode": "scan" }
{ "type": "triggerPreview" }
{ "type": "triggerScan" }
{ "type": "triggerExport" }
{ "type": "cancel" }
{ "type": "requestTile", "requestID": 42, "normalizedRect": { "x": 0.35, "y": 0.40, "width": 0.15, "height": 0.20 }, "maxPixelWidth": 1600 }
```

#### 2. JSON Text Frames (`HostMessage` → Client)
```json
{ "type": "welcome", "protocolVersion": 1, "hostName": "Mac Studio", "authToken": "...", "snapshot": { ... } }
{ "type": "authRequired" }
{ "type": "snapshot", "snapshot": { ... } }
{ "type": "progress", "operation": "scan", "bytesReceived": 184549376, "expectedBytes": 423624704, "elapsedSeconds": 72.4, "statusText": "Scanning 1200 DPI · 176.0 / 404.0 MB (72s)" }
{ "type": "imageReady", "kind": "scanProxy", "generation": 7, "requestID": 0, "width": 1698, "height": 2200, "trueWidth": 10200, "trueHeight": 13200, "dpi": 1200, "summaryText": "Live: Display P3 (Accurate) · TIFF (LZW Lossless) · ~385 MB raw" }
{ "type": "scanCompleted", "filename": "scan-004.tiff", "pixelWidth": 10200, "pixelHeight": 13200, "fileSizeBytes": 214958080, "elapsedSeconds": 168.2 }
{ "type": "error", "title": "Scan Failed", "message": "..." }
```

#### 3. Binary Image Frames (Host → Client)
Immediately following `imageReady`, the host sends a single binary WebSocket frame:

| Offset | Size | Field |
| :--- | :--- | :--- |
| `0` | 1 byte | `frameKind` (`1` = previewProxy, `2` = scanProxy, `3` = highResTile) |
| `1` | 4 bytes | `generation` (`UInt32` big-endian; lets iOS discard stale out-of-order frames) |
| `5` | 4 bytes | `requestID` (`UInt32` big-endian; matches `requestTile.requestID` or `0` for proxy) |
| `9` | N bytes | ImageIO-encoded **HEIC** (or **JPEG @ 0.90**) with embedded **Display P3 / sRGB ICC profile** |

### Rendering Modes
- **MVP (Server-Rendered Proxy):** Mac Studio renders `rawScanProxyBuffer` (`≤2200 px`) in `~10 ms`, hardware-encodes HEIC/JPEG (`~150–350 KB`, `~5 ms`), and pushes over LAN (`~10 ms`) → **~25–40 ms total round-trip**.
- **1:1 Zoomed Tile Peeping:** When the iPhone user pinches past proxy resolution and gesture settles (`~90 ms` debounce), iPhone sends `requestTile(visibleNormalizedRect)`. Mac crops only those visible 1:1 pixels from `renderedFullScanImage`, optionally applies lossy JPEG/HEIC compression simulation, and returns a ~250–400 KB Display P3 tile in **~25–50 ms**.
- **Optional Phase 4 Upgrade (Hybrid Local Sliders):** Mac pushes the unadjusted `2200 px` proxy once on scan completion so the iPhone can run `ImagePipeline.renderCGImage` locally in `<5 ms` for 120 Hz tone/profile slider dragging while keeping Mac as the export authority.

---

## Phased Implementation Roadmap

### Phase 1 — Extract `ScanSessionEngine` (Mac-only, zero UX regression)
1. Add `Codable` conformance to shared value types in `Sources/Core/Models.swift`.
2. Create `ScanSessionEngine.swift` by lifting scanner discovery, capabilities, buffers, scan/export tasks, and live rendering state out of `MainWindowController.swift`.
3. Rebind `MainWindowController` and `InspectorViewController` to observe/drive `ScanSessionEngine`.
4. Add `ProcessInfo` sleep-prevention activity during active scans/exports.
5. Run existing `ChromaScanTests` + verify full flatbed preview, 1200 DPI RAW scan, live preview, and re-export on the Mac Studio.

### Phase 2 — Mac `CompanionServer` & Protocol Tests
1. Implement `Sources/Core/CompanionProtocol.swift` (message types, binary frame pack/unpack helpers).
2. Implement `Sources/MacHost/CompanionServer.swift` (`NWListener` + `NWProtocolWebSocket` + `_chromascan._tcp` Bonjour + PIN/token auth + broadcast of snapshots, progress, proxies, and 1:1 tiles).
3. Add a Companion status toolbar item/popover in `MainWindowController` (enable/disable server, display 6-digit pairing PIN, show connected iPhone, revoke paired devices) and optional menu bar background mode in `AppDelegate`.
4. Add `CompanionProtocolTests` and a loopback WebSocket integration test verifying auth, snapshot sync, settings mutation, and binary proxy framing.

### Phase 3 — iOS Lite Companion App (`ChromaScanRemote`) MVP
1. Add the `ChromaScanRemote` iOS (`17.0+`) target to `project.yml` sharing `Sources/Core/`.
2. Build `HostBrowser` (`NWBrowser` for `_chromascan._tcp`) + `PairingView` + `CompanionClient` with automatic reconnect on foregrounding (`scenePhase == .active`).
3. Build `RemoteCanvasView` using `UIScrollView` + `UIImageView` (120 Hz GPU pinch/pan, native Display P3 rendering) with touch-friendly crop handles (large hit targets, rule-of-thirds grid, rotation-aware coordinate mapping matching `PreviewCanvasView`).
4. Build `RemoteControlsSheet` with Preview / Scan / Cancel / Export actions, scanner picker, Capture settings, Hardware Tone sliders, Color Profile / Format / Quality / Filename controls, and live progress bar.

### Phase 4 — 1:1 Tile Peeping & Polish
1. Wire `requestTile` on `UIScrollViewDelegate.scrollViewDidEndZooming` / `scrollViewDidEndDecelerating` to display crisp 1:1 cropped tiles over the proxy image.
2. Optional: Hybrid local LUT/P3 proxy rendering on iPhone for 120 Hz slider dragging.
3. Optional: iOS **Live Activity** (Lock Screen & Dynamic Island) showing live MB/progress during long 1200 DPI scans.
4. Optional: On-demand **"Save Copy to iPhone Photos"** button (asks Mac to export a Display P3 HEIC/JPEG copy and streams it to `PHPhotoLibrary`).

---

## Optional Mac Studio Upgrade: Direct USB Scanning (IPP-over-USB / eSCL)

### Current Status
ChromaScan currently only discovers and talks to scanners over Wi-Fi/LAN TCP/IP (`_uscan._tcp` / `_uscans._tcp` in `BonjourScannerBrowser.swift` + `URLSession` in `ESCLClient.swift`). It does **not** talk over USB yet.

### Why Direct IPP-USB Is Worth Adding on the Mac Studio
- **Same Exact eSCL Protocol:** Virtually all modern AirScan/AirPrint printers (including HP OfficeJet, Canon, Epson, Brother) expose USB interfaces with class `0x07` (Printer), subclass `0x01`, protocol `0x04` (**IPP-over-USB**). Those USB Bulk IN/OUT pipes literally speak standard **HTTP/1.1 eSCL** (`GET /eSCL/ScannerCapabilities`, `POST /eSCL/ScanJobs`, `GET .../NextDocument`)—returning the exact same XML and uncompressed RGB24 raw byte stream!
- **Why NOT `ImageCaptureCore` (`ICScannerDevice`):** Routing USB through macOS's `ImageCaptureCore` hands control back to Apple's `AirScanScanner` / vendor ICA driver, re-introducing the washed-out `Generic RGB` (gamma 1.80) highlight push that ChromaScan was created to bypass.
- **Massive Speed & Reliability Win:** Over 2.4 GHz Wi-Fi, a 404 MB 1200 DPI RAW scan typically transfers at ~1.5–3 MB/s (2–5+ minutes). Over **USB 2.0 High-Speed** via IPP-USB, transfer bandwidth is ~25–35 MB/s—eliminating Wi-Fi bottlenecks so scans run at full optical carriage speed.

### How to Integrate USB Cleanly Into `ChromaScan`
1. **USB Discovery (`USBScannerBrowser.swift` using `IOKit` / `IOUSBHost`):**
   - Watch for USB devices advertising at least one interface with `bInterfaceClass == 0x07`, `bInterfaceSubClass == 0x01`, `bInterfaceProtocol == 0x04` (IPP-USB).
   - Surface them alongside Wi-Fi scanners in `ScanSessionEngine` (e.g., `"HP OfficeJet 3830 (USB)"`, deduplicated by serial/UUID with Wi-Fi and preferring USB when plugged in).
2. **Local Loopback IPP-USB Bridge (`IPPUSBBridge.swift`):**
   - Claim the printer's IPP-USB `IOUSBHostInterface` bulk IN/OUT pipes (IPP-USB printers expose 2–3 identical `07/01/04` interfaces so concurrent HTTP connections like `ScannerStatus` + `NextDocument` don't block each other).
   - Expose a tiny `127.0.0.1:<ephemeralPort>` TCP relay inside the Mac app that forwards HTTP/1.1 bytes straight over the USB bulk pipes.
   - **Zero changes to `ESCLClient.swift`:** `DiscoveredScanner.baseURL` simply points to `http://127.0.0.1:<port>/eSCL`, so `URLSession` streaming, progress reporting, `ScanImageInfo`, cancellation `DELETE`, and the iPhone Companion app all work over USB automatically!
3. **Note on macOS Coexistence:**
   - Ensure the Mac app is not App-Sandboxed (already `ENABLE_HARDENED_RUNTIME: NO` in `project.yml`) and release the USB interface when idle (or after a short idle timeout) so macOS CUPS printing over the same USB cable never contends for the interface.

---

## End-to-End Verification Checklist (Mac Studio + iPhone)

- [ ] **Discovery & Pairing:** Mac Studio appears automatically on iPhone over Wi-Fi/Ethernet LAN; 6-digit PIN pairs once and reconnects automatically after force-quitting the iPhone app.
- [ ] **Preview & Crop Parity:** Flatbed preview appears on iPhone with accurate Display P3 colors; dragging crop handles on iPhone updates dimensions and mirrors live on the Mac Studio canvas across all 4 rotations (`0°`, `90°`, `180°`, `270°`).
- [ ] **1200 DPI RAW Scan & Lock-Screen Resilience:** Triggering a 1200 DPI RAW scan from iPhone streams directly from scanner → Mac Studio; locking the iPhone for 2+ minutes mid-scan does not interrupt the scan, and unlocking the iPhone immediately resumes live progress or shows the finished scan.
- [ ] **Cancellation:** Tapping Cancel on iPhone cancels the active eSCL transfer and sends `DELETE` to the scanner job cleanly.
- [ ] **1:1 Pixel Inspection & Re-Export:** Pinch-zooming past proxy resolution loads a crisp 1:1 Display P3 tile with exact coordinate alignment; changing Color Profile / Tone / Format on iPhone updates both displays and exports the full-res file on the Mac Studio with embedded ICC profile and DPI metadata.
- [ ] **Memory & Stability:** Verify iPhone memory stays under ~80 MB throughout preview, 1200 DPI scan, 1:1 zoom peeping, and re-export.
