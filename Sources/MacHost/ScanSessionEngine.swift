import Foundation
import CoreGraphics

enum SessionEngineEvent: Sendable {
    case snapshotChanged(SessionSnapshot)
    case displayImageUpdated(
        image: CGImage,
        truePixelSize: CGSize,
        summary: String,
        generation: UInt32,
        kind: CompanionImageKind,
        dpi: Int
    )
    case fullScanImageReady(CGImage)
    case progress(
        operation: CompanionOperation,
        bytesReceived: Int64,
        expectedBytes: Int64,
        elapsedSeconds: Double,
        statusText: String,
        estimatedRemainingSeconds: Double? = nil
    )
    case scanCompleted(
        url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int64,
        elapsedSeconds: Double
    )
    case exportCompleted(
        url: URL,
        fileSizeBytes: Int64,
        elapsedSeconds: Double
    )
    case error(title: String, message: String)
}

/// Headless single source of truth for scanner discovery, capabilities, settings, raw buffers,
/// scan/export jobs, sleep prevention, and Display P3 proxy/tile rendering.
/// Observed simultaneously by `MainWindowController` (AppKit) and `CompanionServer` (iPhone).
@MainActor
final class ScanSessionEngine {

    let preferences: AppPreferences
    let undoManager = UndoManager()
    private let browser: ScannerBrowserProtocol
    private let client: ESCLClientProtocol

    // MARK: - Owned State

    private(set) var scanners: [DiscoveredScanner] = []
    private(set) var selectedScannerID: String?
    private(set) var capabilities: ScannerCapabilities?
    private(set) var scannerStatus: ScannerStatus?
    private(set) var settings: ScanSessionSettings
    private(set) var saveFolderURL: URL
    private(set) var cropRect: NormalizedCropRect = .full
    private(set) var scanTrimRect: NormalizedCropRect = .full
    private(set) var viewMode: CanvasViewMode = .preview
    private(set) var isBusy: Bool = false
    private(set) var activeOperation: CompanionOperation?
    private(set) var statusText: String = "Searching for scanners…"
    private(set) var isErrorStatus: Bool = false
    private(set) var outputPreviewSummary: String = ""
    private(set) var lastSavedURL: URL?
    private(set) var platenAspectRatio: Double = 2550.0 / 3508.0

    // Raw & rendered image buffers
    private(set) var rawPreviewBuffer: RawImageBuffer?
    private(set) var rawScanBuffer: RawImageBuffer?
    private(set) var rawScanProxyBuffer: RawImageBuffer?
    private(set) var renderedDisplayImage: CGImage?
    private(set) var renderedDisplayTrueSize: CGSize = .zero
    private(set) var renderedDisplayDPI: Int = 100
    private(set) var renderedFullScanImage: CGImage?
    /// Seeded from the clock (tenths of a second since 2025-01-01) instead of 0 so generations keep
    /// increasing across app relaunches. Companion clients drop proxy frames older than the newest
    /// generation they've seen; a counter restarting at 0 made a still-connected iPhone discard every
    /// new preview after the Mac app restarted.
    private(set) var activeImageGeneration: UInt32 = ScanSessionEngine.launchImageGenerationSeed()

    nonisolated static func launchImageGenerationSeed(now: Date = Date()) -> UInt32 {
        let tenths = (now.timeIntervalSince1970 - 1_735_689_600) * 10 // 2025-01-01T00:00:00Z
        return UInt32(clamping: max(0, Int64(tenths)))
    }

    private var defaultHardwareBrightness: Int = 1000
    private var defaultHardwareContrast: Int = 1000
    private var fullScanRenderSignature: RenderSignature?

    private var activeTask: Task<Void, Never>?
    /// Bytes received so far by the active capture, and an ID so a stale "waiting" watchdog from a
    /// previous capture can't overwrite the status of a newer one.
    private var captureBytesReceived: Int64 = 0
    private var captureID = UUID()
    /// When image data first arrived for the active capture (for the slow-USB check).
    private var captureFirstByteTime: CFAbsoluteTime?
    private var captureSlowUSBWarned = false
    private var captureSpeedEstimator = ScanTransferSpeedEstimator()

    /// Hint appended to the progress status when a USB transfer is stuck far below normal speed.
    static let slowUSBHint = "USB unusually slow — power-cycle the printer or use Wi-Fi"

    /// The HP OfficeJet 3830 can get stuck in a printer-side USB slow mode (~0.19 MB/s instead of
    /// ~1.6 MB/s) that only a printer power cycle clears; Wi-Fi is unaffected. Flag raw USB scans at
    /// ≥300 DPI that have streamed for ≥8 s at under 0.5 MB/s (the rate is steady, so 8 s is plenty
    /// and users tend to cancel a visibly slow scan within ~10–15 s). Previews (100 DPI, scan-head bound)
    /// and JPEG transfers are normally slow, so they are excluded.
    nonisolated static let slowUSBMinStreamingSeconds: Double = 8

    nonisolated static func isSlowUSBTransfer(
        transport: ScannerTransport,
        isPreview: Bool,
        resolution: Int,
        transferFormat: TransferFormat,
        bytesReceived: Int64,
        streamingSeconds: Double
    ) -> Bool {
        guard transport == .usb, !isPreview, resolution >= 300,
              transferFormat == .rawOctetStream, streamingSeconds >= slowUSBMinStreamingSeconds else { return false }
        let mbPerSecond = Double(bytesReceived) / 1e6 / streamingSeconds
        return mbPerSecond < 0.5
    }
    private var previewRenderTask: Task<Void, Never>?
    private var fullScanRenderTask: Task<Void, Never>?
    private var trimTask: Task<Void, Never>?
    private var activePowerActivity: NSObjectProtocol?
    private var previewBufferID = UUID()
    private var scanBufferID = UUID()
    private var capabilityLoadGeneration: UInt64 = 0
    private var needsSelectionReconcileAfterBusy = false

    private var observers: [UUID: @MainActor (SessionEngineEvent) -> Void] = [:]

    private struct RenderSignature: Equatable {
        let trimRect: NormalizedCropRect
        let rotation: ScanRotation
        let colorProfile: ColorProfileMode
        let toneAdjustments: ToneAdjustments
    }

    var isScanTrimmed: Bool {
        rawScanBuffer != nil && !scanTrimRect.isFull
    }

    var selectedScanner: DiscoveredScanner? {
        guard let selectedScannerID else { return nil }
        return scanners.first(where: { $0.id == selectedScannerID })
    }

    var effectiveHardwareBrightness: Int? {
        guard capabilities?.brightnessRange != nil else { return nil }
        return settings.hardwareBrightness == defaultHardwareBrightness ? nil : settings.hardwareBrightness
    }

    var effectiveHardwareContrast: Int? {
        guard capabilities?.contrastRange != nil else { return nil }
        return settings.hardwareContrast == defaultHardwareContrast ? nil : settings.hardwareContrast
    }

    // MARK: - Init

    init(
        preferences: AppPreferences = AppPreferences(),
        browser: ScannerBrowserProtocol = CompositeScannerBrowser(),
        client: ESCLClientProtocol = ESCLClient()
    ) {
        self.preferences = preferences
        self.browser = browser
        self.client = client
        self.saveFolderURL = preferences.saveFolderURL
        self.settings = ScanSessionSettings(
            inputSource: .platen,
            resolution: preferences.resolution,
            colorMode: preferences.colorMode,
            intent: preferences.intent,
            transferFormat: preferences.transferFormat,
            rotation: preferences.rotation,
            autoTrimEmptySpace: preferences.autoTrimEmptySpace,
            hardwareBrightness: 1000,
            hardwareContrast: 1000,
            colorProfile: preferences.colorProfile,
            outputFormat: preferences.outputFormat,
            quality: preferences.quality,
            previewCompressionEnabled: true,
            toneAdjustments: ToneAdjustments(),
            baseFilename: preferences.baseFilename,
            autoIncrement: preferences.autoIncrement
        )

        browser.onScannersChanged = { [weak self] found in
            self?.handleDiscoveredScanners(found)
        }
    }

    // MARK: - Observation & Snapshot

    @discardableResult
    func addObserver(_ handler: @escaping @MainActor (SessionEngineEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func makeSnapshot() -> SessionSnapshot {
        let scanW: Int?
        let scanH: Int?
        let scanDPI: Int?
        if let rawScan = rawScanBuffer {
            let bounds = ImagePipeline.croppedPixelBounds(of: rawScan, normalizedRect: scanTrimRect)
            let rotated = (settings.rotation == .deg90 || settings.rotation == .deg270)
            scanW = rotated ? bounds.height : bounds.width
            scanH = rotated ? bounds.width : bounds.height
            scanDPI = rawScan.dpi
        } else {
            scanW = nil
            scanH = nil
            scanDPI = nil
        }

        return SessionSnapshot(
            scanners: scanners,
            selectedScannerID: selectedScannerID,
            capabilities: capabilities,
            scannerStatus: scannerStatus,
            settings: settings,
            cropRect: cropRect,
            viewMode: viewMode,
            isBusy: isBusy,
            activeOperation: activeOperation,
            statusText: statusText,
            isErrorStatus: isErrorStatus,
            hasPreviewImage: rawPreviewBuffer != nil,
            hasScanImage: rawScanBuffer != nil,
            platenAspectRatio: platenAspectRatio,
            lastSavedFilename: lastSavedURL?.lastPathComponent,
            saveFolderDisplayName: saveFolderURL.lastPathComponent,
            outputPreviewSummary: outputPreviewSummary,
            activeImageGeneration: activeImageGeneration,
            scanPixelWidth: scanW,
            scanPixelHeight: scanH,
            scanDPI: scanDPI,
            isScanTrimmed: isScanTrimmed
        )
    }

    private func emit(_ event: SessionEngineEvent) {
        for handler in observers.values {
            handler(event)
        }
    }

    private func broadcastSnapshot() {
        emit(.snapshotChanged(makeSnapshot()))
    }

    // MARK: - Discovery & Scanner Selection

    func startDiscovery() {
        statusText = "Searching for scanners…"
        isErrorStatus = false
        browser.start()
        broadcastSnapshot()
    }

    func stopDiscovery() {
        browser.stop()
    }

    func refreshScanners() {
        // Never interrupt an active scan/preview/export by restarting discovery.
        guard !isBusy else { return }
        if let scanner = selectedScanner {
            loadCapabilities(for: scanner)
        }
        browser.refresh()
    }

    func selectScanner(id: String) {
        guard !isBusy,
              let chosen = scanners.first(where: { $0.id == id }),
              chosen.id != selectedScannerID else { return }
        selectedScannerID = chosen.id
        capabilities = nil
        scannerStatus = nil
        broadcastSnapshot()
        loadCapabilities(for: chosen)
    }

    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String = "eSCL") {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return }
        browser.addManualScanner(host: cleanHost, port: port, useTLS: useTLS, rootPath: rootPath)
        let expectedID = "manual:\(cleanHost):\(port):\(useTLS)"
        if let added = scanners.first(where: { $0.id == expectedID }) ?? scanners.last {
            selectedScannerID = added.id
            capabilities = nil
            scannerStatus = nil
            broadcastSnapshot()
            loadCapabilities(for: added)
        }
    }

    private var lastLoggedFallbackEndpoint: String?

    /// Logs (once per change) which Wi-Fi endpoint a slow USB scan would fall back to, so the
    /// fallback can be verified without waiting for the printer's USB slow mode.
    private func logUSBFallbackEndpointIfChanged() {
        guard let scanner = selectedScanner, scanner.transport == .usb else { return }
        let target = browser.networkCounterpart(for: scanner)
        let desc = target.map { "\($0.host):\($0.port)\($0.useTLS ? " (TLS)" : "")" } ?? "none"
        guard desc != lastLoggedFallbackEndpoint else { return }
        lastLoggedFallbackEndpoint = desc
        transferLog.notice("USB scanner \(scanner.displayTitle, privacy: .public): Wi-Fi fallback endpoint \(desc, privacy: .public)")
    }

    private func handleDiscoveredScanners(_ found: [DiscoveredScanner]) {
        let prevID = selectedScannerID
        let prevSelected = selectedScanner
        self.scanners = found
        defer { logUSBFallbackEndpointIfChanged() }

        if let prevID, let currentSelected = found.first(where: { $0.id == prevID }) {
            // Keep existing selection; if its endpoint URL changed (e.g. USB bridge -> macOS ippusbd
            // port handoff or port refresh), reload capabilities once idle.
            if prevSelected?.baseURL != currentSelected.baseURL {
                if isBusy {
                    needsSelectionReconcileAfterBusy = true
                } else {
                    loadCapabilities(for: currentSelected)
                }
            }
        } else if isBusy {
            // Never disrupt an in-flight scan/preview if a cable is plugged/unplugged mid-operation,
            // but mark for immediate reconciliation once the active operation finishes.
            needsSelectionReconcileAfterBusy = true
        } else if selectedScannerID == nil, let first = found.first {
            selectedScannerID = first.id
            loadCapabilities(for: first)
        } else if found.isEmpty {
            selectedScannerID = nil
            capabilities = nil
            scannerStatus = nil
            statusText = "No scanners found"
            isErrorStatus = false
        } else if let first = found.first {
            selectedScannerID = first.id
            capabilities = nil
            scannerStatus = nil
            loadCapabilities(for: first)
        }

        broadcastSnapshot()
    }

    private func reconcileSelectionIfNeededAfterBusy() {
        guard !isBusy, needsSelectionReconcileAfterBusy else { return }
        needsSelectionReconcileAfterBusy = false

        if let selID = selectedScannerID,
           let current = scanners.first(where: { $0.id == selID }) {
            // Selected scanner still exists (e.g. its USB port changed mid-scan) -> refresh capabilities
            loadCapabilities(for: current)
        } else if let first = scanners.first {
            selectedScannerID = first.id
            capabilities = nil
            scannerStatus = nil
            broadcastSnapshot()
            loadCapabilities(for: first)
        } else {
            selectedScannerID = nil
            capabilities = nil
            scannerStatus = nil
            statusText = "No scanners found"
            isErrorStatus = false
            broadcastSnapshot()
        }
    }

    private func loadCapabilities(for scanner: DiscoveredScanner) {
        capabilityLoadGeneration &+= 1
        let requestGen = capabilityLoadGeneration
        let targetURL = scanner.baseURL

        if !isBusy {
            statusText = "Connecting to \(scanner.displayTitle)…"
            isErrorStatus = false
            broadcastSnapshot()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let caps: ScannerCapabilities
                let status: ScannerStatus
                if scanner.transport == .usb {
                    // Over IPP-USB, run initial capabilities + status sequentially on a single
                    // USB bulk interface so firmware / macOS ippusbd never stalls a secondary slot.
                    caps = try await client.fetchCapabilities(from: scanner)
                    status = try await client.fetchStatus(from: scanner)
                } else {
                    async let capsTask = client.fetchCapabilities(from: scanner)
                    async let statusTask = client.fetchStatus(from: scanner)
                    (caps, status) = try await (capsTask, statusTask)
                }
                guard self.capabilityLoadGeneration == requestGen,
                      self.selectedScannerID == scanner.id,
                      self.selectedScanner?.baseURL == targetURL else { return }
                self.capabilities = caps
                self.scannerStatus = status
                self.reconcileSettingsWithCapabilities(caps)
                if let platen = caps.platen, platen.maxHeight > 0 {
                    self.platenAspectRatio = Double(platen.maxWidth) / Double(platen.maxHeight)
                }
                if !self.isBusy {
                    let transportBadge = scanner.transport == .usb ? " · USB" : ""
                    self.statusText = "Ready · \(caps.makeAndModel)\(transportBadge) (\(status.state))"
                    self.isErrorStatus = false
                }
                self.broadcastSnapshot()
            } catch {
                guard self.capabilityLoadGeneration == requestGen,
                      self.selectedScannerID == scanner.id,
                      self.selectedScanner?.baseURL == targetURL else { return }
                self.capabilities = nil
                self.scannerStatus = nil
                if !self.isBusy {
                    self.statusText = "Could not reach scanner: \(error.localizedDescription)"
                    self.isErrorStatus = true
                }
                self.broadcastSnapshot()
            }
        }
    }

    private func reconcileSettingsWithCapabilities(_ caps: ScannerCapabilities) {
        // Source
        var availableSources: [ScanInputSource] = []
        if caps.platen != nil { availableSources.append(.platen) }
        if caps.adf != nil { availableSources.append(.feeder) }
        if !availableSources.isEmpty && !availableSources.contains(settings.inputSource) {
            settings.inputSource = availableSources[0]
        }

        let inputCaps = caps.caps(for: settings.inputSource) ?? caps.platen
        if let resList = inputCaps?.discreteResolutions, !resList.isEmpty, !resList.contains(settings.resolution) {
            settings.resolution = resList.last ?? 300
            preferences.resolution = settings.resolution
        }

        if let modes = inputCaps?.colorModes, !modes.isEmpty {
            let supported = ScanColorMode.allCases.filter { modes.contains($0.rawValue) }
            if !supported.isEmpty && !supported.contains(settings.colorMode) {
                settings.colorMode = supported[0]
                preferences.colorMode = settings.colorMode
            }
        }

        if let inputCaps {
            var formats: [TransferFormat] = []
            if inputCaps.supportsRawOctetStream { formats.append(.rawOctetStream) }
            if inputCaps.supportsJPEG { formats.append(.jpeg) }
            if !formats.isEmpty && !formats.contains(settings.transferFormat) {
                settings.transferFormat = formats[0]
                preferences.transferFormat = settings.transferFormat
            }
        }

        if let br = caps.brightnessRange {
            defaultHardwareBrightness = br.normal
            settings.hardwareBrightness = br.normal
        }
        if let cr = caps.contrastRange {
            defaultHardwareContrast = cr.normal
            settings.hardwareContrast = cr.normal
        }
    }

    // MARK: - Settings, Crop & View Mode Mutations

    func updateSettings(_ patch: ScanSettingsPatch) {
        let oldSettings = settings

        // Capture settings cannot mutate while busy (except live display/output adjustments)
        if !isBusy {
            if let source = patch.inputSource {
                settings.inputSource = source
                if let caps = capabilities {
                    let inputCaps = caps.caps(for: source) ?? caps.platen
                    if let resList = inputCaps?.discreteResolutions, !resList.isEmpty, !resList.contains(settings.resolution) {
                        settings.resolution = resList.last ?? 300
                        preferences.resolution = settings.resolution
                    }
                }
            }
            if let res = patch.resolution, res > 0 {
                settings.resolution = res
                preferences.resolution = res
            }
            if let mode = patch.colorMode {
                settings.colorMode = mode
                preferences.colorMode = mode
            }
            if let intent = patch.intent {
                settings.intent = intent
                preferences.intent = intent
            }
            if let tf = patch.transferFormat {
                settings.transferFormat = tf
                preferences.transferFormat = tf
            }
            if let autoTrim = patch.autoTrimEmptySpace {
                settings.autoTrimEmptySpace = autoTrim
                preferences.autoTrimEmptySpace = autoTrim
            }
            if patch.resetHardwareTone == true {
                settings.hardwareBrightness = defaultHardwareBrightness
                settings.hardwareContrast = defaultHardwareContrast
            } else {
                if let b = patch.hardwareBrightness {
                    if let range = capabilities?.brightnessRange {
                        settings.hardwareBrightness = max(range.min, min(range.max, b))
                    } else {
                        settings.hardwareBrightness = b
                    }
                }
                if let c = patch.hardwareContrast {
                    if let range = capabilities?.contrastRange {
                        settings.hardwareContrast = max(range.min, min(range.max, c))
                    } else {
                        settings.hardwareContrast = c
                    }
                }
            }
            if let name = patch.baseFilename {
                settings.baseFilename = name
                preferences.baseFilename = name
            }
        }

        if let rot = patch.rotation {
            settings.rotation = rot
            preferences.rotation = rot
        }
        if let profile = patch.colorProfile {
            settings.colorProfile = profile
            preferences.colorProfile = profile
        }
        if let fmt = patch.outputFormat {
            settings.outputFormat = fmt
            preferences.outputFormat = fmt
        }
        if let q = patch.quality {
            let clamped = max(0.5, min(1.0, q))
            settings.quality = clamped
            preferences.quality = clamped
        }
        if let previewComp = patch.previewCompressionEnabled {
            settings.previewCompressionEnabled = previewComp
        }
        if patch.resetSoftwareTone == true {
            settings.toneAdjustments = ToneAdjustments()
        } else if let tone = patch.toneAdjustments {
            settings.toneAdjustments = ToneAdjustments(
                blackPoint: max(0.0, min(0.25, tone.blackPoint)),
                whitePoint: max(0.75, min(1.0, tone.whitePoint)),
                gamma: max(0.5, min(2.0, tone.gamma))
            )
        }
        if let autoInc = patch.autoIncrement {
            settings.autoIncrement = autoInc
            preferences.autoIncrement = autoInc
        }

        guard settings != oldSettings else { return }
        broadcastSnapshot()

        if patch.affectsDisplayRendering {
            reRenderActiveView()
        }
    }

    func setSaveFolderURL(_ url: URL) {
        saveFolderURL = url
        preferences.saveFolderURL = url
        broadcastSnapshot()
    }

    func setCropRect(_ rect: NormalizedCropRect) {
        let clamped = rect.clamped()
        guard clamped != cropRect else { return }
        cropRect = clamped
        broadcastSnapshot()
    }

    func resetCrop() {
        setCropRect(.full)
    }

    func undo() {
        guard !isBusy, undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard !isBusy, undoManager.canRedo else { return }
        undoManager.redo()
    }

    func trimEmptySpace() {
        guard !isBusy else { return }
        trimTask?.cancel()

        switch viewMode {
        case .preview:
            guard let previewBuf = rawPreviewBuffer else { return }
            let bufID = previewBufferID
            let previousCrop = cropRect
            trimTask = Task.detached(priority: .userInitiated) { [weak self] in
                let detected = ImagePipeline.detectContentBounds(in: previewBuf)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, !self.isBusy, self.previewBufferID == bufID else { return }
                    if let detected, detected != previousCrop {
                        self.applyPreviewCropWithUndo(
                            detected,
                            previousCrop: previousCrop,
                            bufferID: bufID,
                            actionName: "Trim Empty Space"
                        )
                    } else {
                        self.statusText = "No empty border detected"
                        self.isErrorStatus = false
                        self.broadcastSnapshot()
                    }
                }
            }

        case .scan:
            guard let scanBuf = rawScanBuffer, scanTrimRect.isFull else { return }
            let bufID = scanBufferID
            let previousTrim = scanTrimRect
            trimTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let detected = ImagePipeline.detectContentBounds(in: scanBuf) else {
                    if Task.isCancelled { return }
                    await MainActor.run { [weak self] in
                        guard let self, !self.isBusy, self.scanBufferID == bufID else { return }
                        self.statusText = "No empty border detected"
                        self.isErrorStatus = false
                        self.broadcastSnapshot()
                    }
                    return
                }
                if Task.isCancelled { return }
                let trimmedRaw = ImagePipeline.cropRawBuffer(scanBuf, to: detected)
                let trimmedProxy = ImagePipeline.makeProxyBuffer(from: trimmedRaw, maxDimension: 2200)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, !self.isBusy, self.scanBufferID == bufID else { return }
                    self.applyScanTrimRect(
                        detected,
                        previousTrim: previousTrim,
                        bufferID: bufID,
                        actionName: "Trim Empty Space",
                        precomputedProxy: trimmedProxy
                    )
                }
            }
        }
    }

    private func applyPreviewCropWithUndo(
        _ newCrop: NormalizedCropRect,
        previousCrop: NormalizedCropRect,
        bufferID: UUID,
        actionName: String
    ) {
        guard !isBusy, previewBufferID == bufferID else { return }
        cropRect = newCrop
        statusText = newCrop.isFull ? "Selection reset to full flatbed" : "Trimmed selection to content"
        isErrorStatus = false
        broadcastSnapshot()

        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.applyPreviewCropWithUndo(
                    previousCrop,
                    previousCrop: newCrop,
                    bufferID: bufferID,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)
    }

    private func applyScanTrimRect(
        _ newTrim: NormalizedCropRect,
        previousTrim: NormalizedCropRect,
        bufferID: UUID,
        actionName: String,
        precomputedProxy: RawImageBuffer? = nil
    ) {
        guard !isBusy, let scanBuf = rawScanBuffer, scanBufferID == bufferID else { return }
        trimTask?.cancel()

        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.applyScanTrimRect(
                    previousTrim,
                    previousTrim: newTrim,
                    bufferID: bufferID,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)

        scanTrimRect = newTrim
        renderedFullScanImage = nil
        fullScanRenderSignature = nil

        let rotation = settings.rotation
        let bounds = ImagePipeline.croppedPixelBounds(of: scanBuf, normalizedRect: newTrim)
        let rotated = (rotation == .deg90 || rotation == .deg270)
        let outW = rotated ? bounds.height : bounds.width
        let outH = rotated ? bounds.width : bounds.height

        if newTrim.isFull {
            statusText = "Restored full scan (\(outW)×\(outH))"
        } else {
            statusText = "Trimmed empty space (\(outW)×\(outH)) — Export to save"
        }
        isErrorStatus = false

        if let precomputedProxy {
            rawScanProxyBuffer = precomputedProxy
            broadcastSnapshot()
            if viewMode == .scan {
                reRenderActiveView()
            }
            return
        }

        broadcastSnapshot()
        trimTask = Task.detached(priority: .userInitiated) { [weak self] in
            let effective = newTrim.isFull ? scanBuf : ImagePipeline.cropRawBuffer(scanBuf, to: newTrim)
            let proxy = ImagePipeline.makeProxyBuffer(from: effective, maxDimension: 2200)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.scanBufferID == bufferID, self.scanTrimRect == newTrim else { return }
                self.rawScanProxyBuffer = proxy
                if self.viewMode == .scan {
                    self.reRenderActiveView()
                }
            }
        }
    }

    func setViewMode(_ mode: CanvasViewMode) {
        if mode == .scan && rawScanBuffer == nil { return }
        guard mode != viewMode else { return }
        viewMode = mode
        broadcastSnapshot()
        reRenderActiveView()
    }

    // MARK: - Scan, Preview, Export & Cancellation

    func startPreview() {
        startCapture(isPreview: true)
    }

    func startScan() {
        startCapture(isPreview: false)
    }

    /// Per-attempt state shared between the download task and its progress callbacks.
    @MainActor
    private final class DownloadAttempt {
        var task: Task<ScanDownloadResult, Error>?
        var switchToNetworkRequested = false
    }

    /// Runs the scan download and, if a USB transfer is stuck in the printer's slow mode (see
    /// `isSlowUSBTransfer`) while the same printer is advertised on Wi-Fi, cancels the USB job once and
    /// restarts the same scan over Wi-Fi (~0.3–0.43 MB/s there vs ~0.19 MB/s in USB slow mode).
    /// Without a Wi-Fi endpoint it keeps the USB transfer and shows `slowUSBHint` instead.
    private func downloadWithUSBFallback(
        scanner: DiscoveredScanner,
        request: ScanJobRequest,
        isPreview: Bool,
        resolution: Int,
        operation op: CompanionOperation,
        labelPrefix: String,
        startTime: CFAbsoluteTime,
        captureID: UUID
    ) async throws -> ScanDownloadResult {
        var current = scanner
        var fallbackAllowed = scanner.transport == .usb && !isPreview
        var viaFallback = false

        while true {
            let attemptScanner = current
            let fallbackTarget = fallbackAllowed ? browser.networkCounterpart(for: attemptScanner) : nil
            if fallbackAllowed {
                let desc = fallbackTarget.map { "\($0.host):\($0.port)" } ?? "none"
                transferLog.notice("USB scan starting; Wi-Fi fallback endpoint if slow: \(desc, privacy: .public)")
            }
            let attemptViaFallback = viaFallback
            let attempt = DownloadAttempt()
            captureFirstByteTime = nil
            captureSlowUSBWarned = false
            captureSpeedEstimator.reset()

            let client = self.client
            attempt.task = Task {
                try await client.performScan(scanner: attemptScanner, request: request) { [weak self] recv, expected in
                    let now = CFAbsoluteTimeGetCurrent()
                    let elapsed = now - startTime
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy, self.captureID == captureID,
                              !attempt.switchToNetworkRequested else { return }
                        self.captureBytesReceived = max(self.captureBytesReceived, recv)
                        if recv > 0, self.captureFirstByteTime == nil {
                            self.captureFirstByteTime = now
                        }
                        if recv > 0 {
                            self.captureSpeedEstimator.record(bytesReceived: recv, at: now)
                        }
                        if !self.captureSlowUSBWarned, let first = self.captureFirstByteTime,
                           Self.isSlowUSBTransfer(
                               transport: attemptScanner.transport,
                               isPreview: isPreview,
                               resolution: resolution,
                               transferFormat: request.transferFormat,
                               bytesReceived: recv,
                               streamingSeconds: now - first
                           ) {
                            self.captureSlowUSBWarned = true
                            let streamed = now - first
                            if let target = fallbackTarget {
                                transferLog.notice("SLOW-USB detected: \(Double(recv) / 1e6, format: .fixed(precision: 1)) MB in \(streamed, format: .fixed(precision: 0))s — switching to network endpoint \(target.host, privacy: .public):\(target.port)")
                                attempt.switchToNetworkRequested = true
                                attempt.task?.cancel()
                                return
                            }
                            transferLog.notice("SLOW-USB detected: \(Double(recv) / 1e6, format: .fixed(precision: 1)) MB in \(streamed, format: .fixed(precision: 0))s — no network endpoint, showing power-cycle hint")
                        }
                        let eta = self.captureSpeedEstimator.estimatedRemainingSeconds(
                            bytesReceived: recv,
                            expectedBytes: expected
                        )
                        let recvMB = Double(recv) / (1024.0 * 1024.0)
                        var status: String
                        if expected > 0 {
                            let expMB = Double(expected) / (1024.0 * 1024.0)
                            if let eta {
                                let etaStr = ScanLiveActivityContentState.formatRemainingSeconds(eta)
                                status = String(format: "%@ · %.1f / %.1f MB · %@", labelPrefix, recvMB, expMB, etaStr)
                            } else {
                                status = String(format: "%@ · %.1f / %.1f MB (%.0fs)", labelPrefix, recvMB, expMB, elapsed)
                            }
                        } else {
                            status = String(format: "%@ · %.1f MB (%.0fs)", labelPrefix, recvMB, elapsed)
                        }
                        if attemptViaFallback {
                            status += " · via Wi-Fi (USB was slow)"
                        } else if self.captureSlowUSBWarned {
                            status += " · " + Self.slowUSBHint
                        }
                        self.statusText = status
                        self.emit(.progress(
                            operation: op,
                            bytesReceived: recv,
                            expectedBytes: expected,
                            elapsedSeconds: elapsed,
                            statusText: status,
                            estimatedRemainingSeconds: eta
                        ))
                    }
                }
            }

            do {
                let task = attempt.task!
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                guard attempt.switchToNetworkRequested, let target = fallbackTarget, !Task.isCancelled else {
                    throw error
                }
                // The USB job was cancelled (ESCLClient sent DELETE). Restart the same scan over Wi-Fi.
                fallbackAllowed = false
                viaFallback = true
                current = target
                let expectedBytes = request.transferFormat == .rawOctetStream ? request.expectedRawByteCount : 0
                let status = "\(labelPrefix) · USB slow — switching to Wi-Fi…"
                statusText = status
                emit(.progress(operation: op, bytesReceived: 0, expectedBytes: expectedBytes,
                               elapsedSeconds: CFAbsoluteTimeGetCurrent() - startTime, statusText: status))
                await waitForScannerIdle(target, timeout: 20)
                try Task.checkCancellation()
            }
        }
    }

    /// Polls ScannerStatus until the scanner reports Idle (e.g. after cancelling a job), up to `timeout`.
    private func waitForScannerIdle(_ scanner: DiscoveredScanner, timeout: TimeInterval) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline, !Task.isCancelled {
            if let status = try? await client.fetchStatus(from: scanner), status.state == "Idle" { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        transferLog.notice("SLOW-USB fallback: scanner not Idle after \(Int(timeout))s; starting Wi-Fi scan anyway")
    }

    /// Normally image data starts within ~10 s (1200 DPI warm-up is ~8 s). If nothing has arrived after
    /// 15 s, say so instead of sitting silently at 0% — on Mac and on the companion via `.progress`.
    private func startWaitingForScannerWatchdog(captureID: UUID, operation op: CompanionOperation, labelPrefix: String, startTime: CFAbsoluteTime, expectedBytes: Int64) {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.captureID == captureID, self.isBusy,
                      self.activeOperation == op, self.captureBytesReceived == 0 else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                guard elapsed >= 15 else { continue }
                let status = String(format: "%@ · waiting for scanner to respond (%.0fs)…", labelPrefix, elapsed)
                self.statusText = status
                self.emit(.progress(operation: op, bytesReceived: 0, expectedBytes: expectedBytes, elapsedSeconds: elapsed, statusText: status))
            }
        }
    }

    func cancelActiveOperation() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func beginPowerAssertion(reason: String) {
        endPowerAssertion()
        activePowerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    private func endPowerAssertion() {
        if let activity = activePowerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            activePowerActivity = nil
        }
    }

    private func startCapture(isPreview: Bool) {
        guard !isBusy, let scanner = selectedScanner else { return }

        let source: ScanInputSource = isPreview ? .platen : settings.inputSource
        let inputCaps = capabilities?.caps(for: source) ?? capabilities?.platen
        let maxW = inputCaps?.maxWidth ?? 2550
        let maxH = inputCaps?.maxHeight ?? 3300

        let resolution: Int
        if isPreview {
            let available = inputCaps?.discreteResolutions ?? [75, 100, 200, 300]
            resolution = available.contains(100) ? 100 : (available.first ?? 75)
        } else {
            resolution = settings.resolution
        }

        let crop: NormalizedCropRect = (isPreview || source == .feeder) ? .full : cropRect
        let region = crop.toESCLRegion(maxWidth: maxW, maxHeight: maxH)

        let transfer: TransferFormat
        if isPreview {
            transfer = (inputCaps?.supportsRawOctetStream ?? true) ? .rawOctetStream : .jpeg
        } else {
            transfer = settings.transferFormat
        }

        let request = ScanJobRequest(
            version: capabilities?.version ?? "2.5",
            inputSource: source,
            resolution: resolution,
            colorMode: settings.colorMode,
            intent: settings.intent,
            isPreview: false,
            transferFormat: transfer,
            region: region,
            brightness: effectiveHardwareBrightness,
            contrast: effectiveHardwareContrast
        )

        let capturedSettings = settings
        let folderURL = saveFolderURL
        let makeAndModel = capabilities?.makeAndModel ?? scanner.displayTitle
        let op: CompanionOperation = isPreview ? .preview : .scan

        isBusy = true
        activeOperation = op
        isErrorStatus = false
        let startTime = CFAbsoluteTimeGetCurrent()
        let labelPrefix = isPreview ? "Previewing" : "Scanning \(resolution) DPI"
        statusText = "\(labelPrefix)…"
        beginPowerAssertion(reason: isPreview ? "ChromaScan flatbed preview" : "ChromaScan active scan (\(resolution) DPI)")
        broadcastSnapshot()
        emit(.progress(operation: op, bytesReceived: 0, expectedBytes: request.transferFormat == .rawOctetStream ? request.expectedRawByteCount : 0, elapsedSeconds: 0, statusText: statusText))

        captureBytesReceived = 0
        captureFirstByteTime = nil
        captureSlowUSBWarned = false
        let thisCaptureID = UUID()
        captureID = thisCaptureID
        startWaitingForScannerWatchdog(captureID: thisCaptureID, operation: op, labelPrefix: labelPrefix, startTime: startTime,
                                       expectedBytes: request.transferFormat == .rawOctetStream ? request.expectedRawByteCount : 0)

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.endPowerAssertion()
                self.reconcileSelectionIfNeededAfterBusy()
            }
            do {
                let download = try await self.downloadWithUSBFallback(
                    scanner: scanner,
                    request: request,
                    isPreview: isPreview,
                    resolution: resolution,
                    operation: op,
                    labelPrefix: labelPrefix,
                    startTime: startTime,
                    captureID: thisCaptureID
                )

                try Task.checkCancellation()

                if isPreview {
                    self.statusText = "Rendering preview…"
                    self.emit(.progress(operation: .preview, bytesReceived: Int64(download.data.count), expectedBytes: Int64(download.data.count), elapsedSeconds: CFAbsoluteTimeGetCurrent() - startTime, statusText: self.statusText))

                    let rawBuf = try await Task.detached(priority: .userInitiated) {
                        try ImagePipeline.decodeToRawBuffer(download: download, request: request)
                    }.value

                    try Task.checkCancellation()

                    self.rawPreviewBuffer = rawBuf
                    self.previewBufferID = UUID()
                    self.platenAspectRatio = Double(rawBuf.width) / Double(max(1, rawBuf.height))
                    self.viewMode = .preview
                    self.isBusy = false
                    self.activeOperation = nil
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    self.statusText = String(format: "Preview ready (%dx%d · %.1fs)", rawBuf.width, rawBuf.height, elapsed)
                    self.isErrorStatus = false
                    self.broadcastSnapshot()
                    self.reRenderActiveView()
                } else {
                    self.statusText = "Processing & saving (\(capturedSettings.colorProfile.shortName))…"
                    self.emit(.progress(operation: .scan, bytesReceived: Int64(download.data.count), expectedBytes: Int64(download.data.count), elapsedSeconds: CFAbsoluteTimeGetCurrent() - startTime, statusText: self.statusText))

                    let exportSettings = ExportSettings(
                        rotation: capturedSettings.rotation,
                        colorProfile: capturedSettings.colorProfile,
                        toneAdjustments: capturedSettings.toneAdjustments,
                        format: capturedSettings.outputFormat,
                        quality: capturedSettings.quality,
                        scannerMakeAndModel: makeAndModel
                    )
                    let destURL = FilenameHelper.uniqueDestinationURL(
                        in: folderURL,
                        baseName: capturedSettings.baseFilename,
                        ext: capturedSettings.outputFormat.fileExtension
                    )
                    let shouldAutoTrim = capturedSettings.autoTrimEmptySpace

                    let (rawBuf, trimRect, proxyBuf, fullCG, fileSize) = try await Task.detached(priority: .userInitiated) {
                        let rawBuf = try ImagePipeline.decodeToRawBuffer(download: download, request: request)
                        let trimRect: NormalizedCropRect
                        if shouldAutoTrim, let detected = ImagePipeline.detectContentBounds(in: rawBuf) {
                            trimRect = detected
                        } else {
                            trimRect = .full
                        }
                        let effectiveBuf = trimRect.isFull ? rawBuf : ImagePipeline.cropRawBuffer(rawBuf, to: trimRect)
                        let cgImg = try ImagePipeline.renderCGImage(
                            from: effectiveBuf,
                            rotation: exportSettings.rotation,
                            colorProfile: exportSettings.colorProfile,
                            toneAdjustments: exportSettings.toneAdjustments
                        )
                        try ImagePipeline.export(cgImage: cgImg, dpi: effectiveBuf.dpi, settings: exportSettings, to: destURL)
                        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        let proxy = ImagePipeline.makeProxyBuffer(from: effectiveBuf, maxDimension: 2200)
                        return (rawBuf, trimRect, proxy, cgImg, bytes)
                    }.value

                    try Task.checkCancellation()

                    let sig = RenderSignature(
                        trimRect: trimRect,
                        rotation: capturedSettings.rotation,
                        colorProfile: capturedSettings.colorProfile,
                        toneAdjustments: capturedSettings.toneAdjustments
                    )
                    let newScanID = UUID()
                    self.trimTask?.cancel()
                    self.undoManager.removeAllActions()
                    self.rawScanBuffer = rawBuf
                    self.scanBufferID = newScanID
                    self.scanTrimRect = trimRect
                    self.rawScanProxyBuffer = proxyBuf
                    self.renderedFullScanImage = fullCG
                    self.fullScanRenderSignature = sig
                    self.lastSavedURL = destURL

                    if !trimRect.isFull {
                        self.undoManager.registerUndo(withTarget: self) { target in
                            MainActor.assumeIsolated {
                                target.applyScanTrimRect(
                                    .full,
                                    previousTrim: trimRect,
                                    bufferID: newScanID,
                                    actionName: "Auto-Trim Empty Space"
                                )
                            }
                        }
                        self.undoManager.setActionName("Auto-Trim Empty Space")
                    }

                    if capturedSettings.autoIncrement {
                        let nextName = FilenameHelper.incrementedFilename(capturedSettings.baseFilename)
                        self.settings.baseFilename = nextName
                        self.preferences.baseFilename = nextName
                    }

                    self.isBusy = false
                    self.activeOperation = nil
                    self.viewMode = .scan
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let mb = Double(fileSize) / (1024.0 * 1024.0)
                    let trimTag = trimRect.isFull ? "" : "trimmed · "
                    self.statusText = String(format: "Saved %@ (%@%dx%d · %.1f MB · %.1fs)", destURL.lastPathComponent, trimTag, fullCG.width, fullCG.height, mb, elapsed)
                    self.isErrorStatus = false
                    self.broadcastSnapshot()
                    self.emit(.scanCompleted(url: destURL, pixelWidth: fullCG.width, pixelHeight: fullCG.height, fileSizeBytes: fileSize, elapsedSeconds: elapsed))
                    self.reRenderActiveView()
                }
            } catch ESCLClientError.cancelled {
                self.isBusy = false
                self.activeOperation = nil
                self.statusText = "Scan cancelled"
                self.isErrorStatus = false
                self.broadcastSnapshot()
            } catch is CancellationError {
                self.isBusy = false
                self.activeOperation = nil
                self.statusText = "Scan cancelled"
                self.isErrorStatus = false
                self.broadcastSnapshot()
            } catch {
                self.isBusy = false
                self.activeOperation = nil
                self.statusText = error.localizedDescription
                self.isErrorStatus = true
                self.broadcastSnapshot()
                self.emit(.error(title: "Scan Failed", message: error.localizedDescription))
            }
        }
    }

    func exportCurrentScan(to customURL: URL? = nil) {
        guard !isBusy, let rawBuf = rawScanBuffer else { return }

        let capturedSettings = settings
        let folderURL = saveFolderURL
        let autoInc = capturedSettings.autoIncrement && customURL == nil
        let makeAndModel = capabilities?.makeAndModel ?? selectedScanner?.displayTitle

        let destURL = customURL ?? FilenameHelper.uniqueDestinationURL(
            in: folderURL,
            baseName: capturedSettings.baseFilename,
            ext: capturedSettings.outputFormat.fileExtension
        )

        let trimRect = scanTrimRect
        let sig = RenderSignature(
            trimRect: trimRect,
            rotation: capturedSettings.rotation,
            colorProfile: capturedSettings.colorProfile,
            toneAdjustments: capturedSettings.toneAdjustments
        )
        let cachedCG = (fullScanRenderSignature == sig) ? renderedFullScanImage : nil

        let exportSettings = ExportSettings(
            rotation: capturedSettings.rotation,
            colorProfile: capturedSettings.colorProfile,
            toneAdjustments: capturedSettings.toneAdjustments,
            format: capturedSettings.outputFormat,
            quality: capturedSettings.quality,
            scannerMakeAndModel: makeAndModel
        )

        isBusy = true
        activeOperation = .export
        isErrorStatus = false
        let startTime = CFAbsoluteTimeGetCurrent()
        statusText = "Exporting \(destURL.lastPathComponent)…"
        beginPowerAssertion(reason: "ChromaScan export")
        broadcastSnapshot()
        emit(.progress(operation: .export, bytesReceived: 0, expectedBytes: 0, elapsedSeconds: 0, statusText: statusText))

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.endPowerAssertion()
                self.reconcileSelectionIfNeededAfterBusy()
            }
            do {
                let (fullCG, fileSize) = try await Task.detached(priority: .userInitiated) {
                    let cgImg: CGImage
                    if let cachedCG {
                        cgImg = cachedCG
                    } else {
                        let effectiveBuf = trimRect.isFull ? rawBuf : ImagePipeline.cropRawBuffer(rawBuf, to: trimRect)
                        cgImg = try ImagePipeline.renderCGImage(
                            from: effectiveBuf,
                            rotation: exportSettings.rotation,
                            colorProfile: exportSettings.colorProfile,
                            toneAdjustments: exportSettings.toneAdjustments
                        )
                    }
                    try ImagePipeline.export(cgImage: cgImg, dpi: rawBuf.dpi, settings: exportSettings, to: destURL)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
                    let bytes = (attrs?[.size] as? Int64) ?? 0
                    return (cgImg, bytes)
                }.value

                self.renderedFullScanImage = fullCG
                self.fullScanRenderSignature = sig
                self.lastSavedURL = destURL
                if autoInc {
                    let nextName = FilenameHelper.incrementedFilename(capturedSettings.baseFilename)
                    self.settings.baseFilename = nextName
                    self.preferences.baseFilename = nextName
                }
                self.isBusy = false
                self.activeOperation = nil
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let mb = Double(fileSize) / (1024.0 * 1024.0)
                self.statusText = String(format: "Exported %@ (%.1f MB · %.2fs)", destURL.lastPathComponent, mb, elapsed)
                self.isErrorStatus = false
                self.broadcastSnapshot()
                self.emit(.exportCompleted(url: destURL, fileSizeBytes: fileSize, elapsedSeconds: elapsed))
            } catch {
                self.isBusy = false
                self.activeOperation = nil
                self.statusText = error.localizedDescription
                self.isErrorStatus = true
                self.broadcastSnapshot()
                self.emit(.error(title: "Export Failed", message: error.localizedDescription))
            }
        }
    }

    // MARK: - Live Display & Full-Res Background Rendering

    func reRenderActiveView() {
        let activeSource: RawImageBuffer?
        let trueBuf: RawImageBuffer?
        let imageKind: CompanionImageKind
        switch viewMode {
        case .preview:
            activeSource = rawPreviewBuffer
            trueBuf = rawPreviewBuffer
            imageKind = .previewProxy
        case .scan:
            activeSource = rawScanProxyBuffer ?? rawScanBuffer
            trueBuf = rawScanBuffer
            imageKind = .scanProxy
        }

        guard let sourceBuf = activeSource, let fullBuf = trueBuf else {
            renderedDisplayImage = nil
            renderedDisplayTrueSize = .zero
            outputPreviewSummary = ""
            broadcastSnapshot()
            return
        }

        let captured = settings
        let activeTrimRect = (viewMode == .scan) ? scanTrimRect : .full
        let simulateCompression = captured.previewCompressionEnabled && captured.outputFormat.supportsQuality
        let sig = RenderSignature(
            trimRect: activeTrimRect,
            rotation: captured.rotation,
            colorProfile: captured.colorProfile,
            toneAdjustments: captured.toneAdjustments
        )

        let fullBounds = ImagePipeline.croppedPixelBounds(of: fullBuf, normalizedRect: activeTrimRect)
        let trueRotatedSize: CGSize = (captured.rotation == .deg90 || captured.rotation == .deg270)
            ? CGSize(width: fullBounds.height, height: fullBounds.width)
            : CGSize(width: fullBounds.width, height: fullBounds.height)

        activeImageGeneration &+= 1
        let gen = activeImageGeneration

        // 1. Fast proxy / preview render
        previewRenderTask?.cancel()
        previewRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            guard let baseImg = try? ImagePipeline.renderCGImage(
                from: sourceBuf,
                rotation: captured.rotation,
                colorProfile: captured.colorProfile,
                toneAdjustments: captured.toneAdjustments
            ) else { return }
            if Task.isCancelled { return }

            var displayImg = baseImg
            var summary: String
            let profileLabel = (sourceBuf.colorMode == .grayscale8) ? "Grayscale" : captured.colorProfile.shortName

            if simulateCompression,
               let sim = ImagePipeline.simulateLossyFormat(cgImage: baseImg, format: captured.outputFormat, quality: captured.quality) {
                displayImg = sim.image
                let proxyPixels = Double(max(1, baseImg.width * baseImg.height))
                let fullPixels = Double(max(1, Int(trueRotatedSize.width * trueRotatedSize.height)))
                let estBytes = Double(sim.encodedBytes) * (fullPixels / proxyPixels)
                let estMB = estBytes / (1024.0 * 1024.0)
                let sizeText = estMB >= 1.0 ? String(format: "~%.1f MB", estMB) : String(format: "~%.0f KB", estBytes / 1024.0)
                let qPct = Int((captured.quality * 100).rounded())
                summary = "Live: \(profileLabel) · \(captured.outputFormat.displayName) \(qPct)% (\(sizeText) est.)"
            } else {
                let rawMB = Double(fullBounds.width * fullBounds.height * fullBuf.colorMode.bytesPerPixel) / (1024.0 * 1024.0)
                let fmtSuffix = captured.outputFormat.supportsQuality
                    ? "\(captured.outputFormat.displayName) (compression preview off)"
                    : "\(captured.outputFormat.displayName) · ~\(Int(rawMB.rounded())) MB"
                summary = "Live: \(profileLabel) · \(fmtSuffix)"
            }

            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.activeImageGeneration == gen else { return }
                self.renderedDisplayImage = displayImg
                self.renderedDisplayTrueSize = trueRotatedSize
                self.renderedDisplayDPI = fullBuf.dpi
                self.outputPreviewSummary = summary
                self.emit(.displayImageUpdated(
                    image: displayImg,
                    truePixelSize: trueRotatedSize,
                    summary: summary,
                    generation: gen,
                    kind: imageKind,
                    dpi: fullBuf.dpi
                ))
            }
        }

        // 2. Keep full-res rendered CGImage fresh in Scan mode
        if viewMode == .scan, let rawScan = rawScanBuffer, fullScanRenderSignature != sig {
            fullScanRenderTask?.cancel()
            fullScanRenderTask = Task.detached(priority: .utility) { [weak self] in
                if Task.isCancelled { return }
                let effectiveBuf = activeTrimRect.isFull ? rawScan : ImagePipeline.cropRawBuffer(rawScan, to: activeTrimRect)
                if Task.isCancelled { return }
                guard let fullCG = try? ImagePipeline.renderCGImage(
                    from: effectiveBuf,
                    rotation: captured.rotation,
                    colorProfile: captured.colorProfile,
                    toneAdjustments: captured.toneAdjustments
                ) else { return }
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renderedFullScanImage = fullCG
                    self.fullScanRenderSignature = sig
                    self.emit(.fullScanImageReady(fullCG))
                }
            }
        }
    }

    // MARK: - Companion Encoding APIs (Proxy, 1:1 High-Res Tile, Photos Copy)

    func encodeActiveProxy(preferHEIC: Bool = true, quality: Double = 0.88) async -> EncodedCompanionImage? {
        guard let img = renderedDisplayImage else { return nil }
        let kind: CompanionImageKind = (viewMode == .scan) ? .scanProxy : .previewProxy
        let gen = activeImageGeneration
        let trueW = Int(renderedDisplayTrueSize.width) > 0 ? Int(renderedDisplayTrueSize.width) : img.width
        let trueH = Int(renderedDisplayTrueSize.height) > 0 ? Int(renderedDisplayTrueSize.height) : img.height
        let dpi = renderedDisplayDPI
        let summary = outputPreviewSummary

        return await Task.detached(priority: .userInitiated) {
            guard let data = ImagePipeline.encodeCompanionImage(
                cgImage: img,
                preferHEIC: preferHEIC,
                quality: quality,
                dpi: dpi
            ) else { return nil }
            let info = CompanionImageReadyInfo(
                kind: kind,
                generation: gen,
                requestID: 0,
                width: img.width,
                height: img.height,
                trueWidth: trueW,
                trueHeight: trueH,
                dpi: dpi,
                normalizedRect: nil,
                summaryText: summary
            )
            return EncodedCompanionImage(info: info, data: data)
        }.value
    }

    func encodeHighResTile(
        requestID: UInt32,
        normalizedRect: NormalizedCropRect,
        maxPixelWidth: Int,
        preferHEIC: Bool = true
    ) async -> EncodedCompanionImage? {
        guard viewMode == .scan, let rawScan = rawScanBuffer else { return nil }

        let captured = settings
        let trimRect = scanTrimRect
        let gen = activeImageGeneration
        let dpi = rawScan.dpi
        let summary = outputPreviewSummary
        let sig = RenderSignature(
            trimRect: trimRect,
            rotation: captured.rotation,
            colorProfile: captured.colorProfile,
            toneAdjustments: captured.toneAdjustments
        )

        let existingFull: CGImage?
        if fullScanRenderSignature == sig, let cg = renderedFullScanImage {
            existingFull = cg
        } else {
            existingFull = nil
        }

        let simFormat: OutputFormat? = (captured.previewCompressionEnabled && captured.outputFormat.supportsQuality)
            ? captured.outputFormat
            : nil
        let simQuality = captured.quality

        return await Task.detached(priority: .userInitiated) {
            let fullCG: CGImage
            if let existingFull {
                fullCG = existingFull
            } else {
                let effectiveBuf = trimRect.isFull ? rawScan : ImagePipeline.cropRawBuffer(rawScan, to: trimRect)
                if let rendered = try? ImagePipeline.renderCGImage(
                    from: effectiveBuf,
                    rotation: captured.rotation,
                    colorProfile: captured.colorProfile,
                    toneAdjustments: captured.toneAdjustments
                ) {
                    fullCG = rendered
                } else {
                    return nil
                }
            }

            guard let tile = ImagePipeline.cropAndEncodeTile(
                from: fullCG,
                normalizedRect: normalizedRect,
                maxPixelWidth: maxPixelWidth,
                simulateFormat: simFormat,
                simulateQuality: simQuality,
                preferHEIC: preferHEIC
            ) else {
                return nil
            }

            let info = CompanionImageReadyInfo(
                kind: .highResTile,
                generation: gen,
                requestID: requestID,
                width: tile.width,
                height: tile.height,
                trueWidth: fullCG.width,
                trueHeight: fullCG.height,
                dpi: dpi,
                normalizedRect: tile.exactNormalizedRect,
                summaryText: summary
            )
            return EncodedCompanionImage(info: info, data: tile.data)
        }.value
    }

    func encodePhotosCopy(
        requestID: UInt32,
        format: OutputFormat,
        quality: Double
    ) async -> EncodedCompanionImage? {
        guard let rawScan = rawScanBuffer else { return nil }
        let captured = settings
        let trimRect = scanTrimRect
        let gen = activeImageGeneration
        let dpi = rawScan.dpi
        let sig = RenderSignature(
            trimRect: trimRect,
            rotation: captured.rotation,
            colorProfile: captured.colorProfile,
            toneAdjustments: captured.toneAdjustments
        )
        let existingFull = (fullScanRenderSignature == sig) ? renderedFullScanImage : nil
        let preferHEIC = (format != .jpeg)

        return await Task.detached(priority: .userInitiated) {
            let fullCG: CGImage
            if let existingFull {
                fullCG = existingFull
            } else {
                let effectiveBuf = trimRect.isFull ? rawScan : ImagePipeline.cropRawBuffer(rawScan, to: trimRect)
                if let rendered = try? ImagePipeline.renderCGImage(
                    from: effectiveBuf,
                    rotation: captured.rotation,
                    colorProfile: captured.colorProfile,
                    toneAdjustments: captured.toneAdjustments
                ) {
                    fullCG = rendered
                } else {
                    return nil
                }
            }

            guard let data = ImagePipeline.encodeCompanionImage(
                cgImage: fullCG,
                preferHEIC: preferHEIC,
                quality: quality,
                dpi: dpi
            ) else { return nil }

            let info = CompanionImageReadyInfo(
                kind: .photosCopy,
                generation: gen,
                requestID: requestID,
                width: fullCG.width,
                height: fullCG.height,
                trueWidth: fullCG.width,
                trueHeight: fullCG.height,
                dpi: dpi,
                normalizedRect: nil,
                summaryText: "Photos Copy (\(fullCG.width)×\(fullCG.height))"
            )
            return EncodedCompanionImage(info: info, data: data)
        }.value
    }

    // MARK: - Testing Support (Seed buffers without needing a physical scanner)

    func loadSyntheticBuffersForTesting(preview: RawImageBuffer?, scan: RawImageBuffer?) {
        self.trimTask?.cancel()
        self.undoManager.removeAllActions()
        self.rawPreviewBuffer = preview
        self.previewBufferID = UUID()
        if let preview {
            self.platenAspectRatio = Double(preview.width) / Double(max(1, preview.height))
        }
        self.rawScanBuffer = scan
        self.scanBufferID = UUID()
        self.scanTrimRect = .full
        if let scan {
            self.rawScanProxyBuffer = ImagePipeline.makeProxyBuffer(from: scan, maxDimension: 2200)
        } else {
            self.rawScanProxyBuffer = nil
        }
        self.renderedFullScanImage = nil
        self.fullScanRenderSignature = nil
        self.broadcastSnapshot()
        self.reRenderActiveView()
    }
}

/// Rolling-window throughput estimator that ignores initial scanner warm-up delay and predicts
/// remaining transfer time once sustained image bytes are streaming.
struct ScanTransferSpeedEstimator: Sendable {
    private struct Sample: Sendable {
        let time: Double
        let bytes: Int64
    }

    let windowSeconds: Double
    let minStreamingSeconds: Double
    let minSampleInterval: Double
    private var samples: [Sample] = []

    init(
        windowSeconds: Double = 10.0,
        minStreamingSeconds: Double = 1.5,
        minSampleInterval: Double = 0.2
    ) {
        self.windowSeconds = windowSeconds
        self.minStreamingSeconds = minStreamingSeconds
        self.minSampleInterval = minSampleInterval
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func record(bytesReceived: Int64, at timestamp: Double) {
        guard bytesReceived > 0 else { return }
        if let last = samples.last {
            if timestamp <= last.time {
                if bytesReceived > last.bytes {
                    samples[samples.count - 1] = Sample(time: last.time, bytes: bytesReceived)
                }
                return
            }
            if timestamp - last.time < minSampleInterval && samples.count >= 2 {
                samples[samples.count - 1] = Sample(time: timestamp, bytes: max(last.bytes, bytesReceived))
            } else {
                samples.append(Sample(time: timestamp, bytes: max(last.bytes, bytesReceived)))
            }
        } else {
            samples.append(Sample(time: timestamp, bytes: bytesReceived))
        }

        let cutoff = timestamp - windowSeconds
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
    }

    func estimatedRemainingSeconds(bytesReceived: Int64, expectedBytes: Int64) -> Double? {
        guard expectedBytes > 0, bytesReceived > 0, bytesReceived < expectedBytes else { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }
        let dt = last.time - first.time
        let dBytes = last.bytes - first.bytes
        guard dt >= minStreamingSeconds, dBytes > 0 else { return nil }
        let bytesPerSecond = Double(dBytes) / dt
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }
        let remaining = Double(expectedBytes - bytesReceived) / bytesPerSecond
        guard remaining.isFinite else { return nil }
        return max(1.0, remaining)
    }
}
