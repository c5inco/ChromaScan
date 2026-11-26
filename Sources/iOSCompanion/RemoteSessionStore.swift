import Foundation
import UIKit
import ImageIO
import Photos
import Observation
@preconcurrency import UserNotifications

struct RemoteProgressState: Equatable, Sendable {
    let operation: CompanionOperation
    let bytesReceived: Int64
    let expectedBytes: Int64
    let elapsedSeconds: Double
    let statusText: String

    var fraction: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1.0, Double(bytesReceived) / Double(expectedBytes))
    }
}

struct RemoteOperationDisplayInfo: Equatable, Sendable {
    let title: String
    let statusDetail: String
    let trailingBadge: String?
    let progressFraction: Double?
    let metadataSummary: String
}

struct RemoteErrorAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

/// Central `@Observable` iOS store mirroring the Mac Studio's `SessionSnapshot`,
/// managing proxy + 1:1 high-res tile images, debounced mutations, and Photos export.
@Observable
@MainActor
final class RemoteSessionStore {

    enum AuthPhase: Equatable {
        case browsing
        case connecting(hostName: String)
        case needsPIN(hostID: String, hostName: String, reason: String?)
        case connected(hostID: String, hostName: String)
    }

    let browser = HostBrowser()
    let client: CompanionClient

    private(set) var phase: AuthPhase = .browsing
    private(set) var connectionStatus: CompanionClient.ConnectionStatus = .disconnected
    private(set) var snapshot: SessionSnapshot?
    private(set) var progress: RemoteProgressState?

    private(set) var proxyImage: UIImage?
    private(set) var proxyInfo: CompanionImageReadyInfo?
    private(set) var tileImage: UIImage?
    private(set) var tileNormalizedRect: NormalizedCropRect?
    private(set) var isLoadingTile: Bool = false

    var toastMessage: String?
    var errorAlert: RemoteErrorAlert?
    private(set) var isSavingToPhotos: Bool = false
    private(set) var notifyOnScanComplete: Bool
    private(set) var liveActivityEnabled: Bool
    private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var apnsDeviceToken: String?
    private(set) var apnsRegistrationError: String?
    private(set) var hostAPNsConfigured: Bool = false
    private(set) var isAppInBackground: Bool = false

    var isDirectAPNsActive: Bool {
        notifyOnScanComplete
            && hostAPNsConfigured
            && (apnsDeviceToken?.isEmpty == false)
            && apnsRegistrationError == nil
    }

    var isLiveActivityActive: Bool {
        liveActivityManager.hasActiveActivity
    }

    var areLiveActivitiesAvailable: Bool {
        liveActivityManager.areActivitiesSupportedAndEnabled
    }

    var currentPushEnvironment: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    private let userDefaults: UserDefaults
    private let notifier: any ScanCompletionNotifying
    private let backgroundTaskManager: any BackgroundTaskManaging
    private let liveActivityManager: any ScanLiveActivityManaging

    // Manual connection persistence
    var lastManualHost: String {
        get { userDefaults.string(forKey: "remote.lastManualHost") ?? "" }
        set { userDefaults.set(newValue, forKey: "remote.lastManualHost") }
    }

    var lastManualPort: String {
        get { userDefaults.string(forKey: "remote.lastManualPort") ?? "" }
        set { userDefaults.set(newValue, forKey: "remote.lastManualPort") }
    }

    // Internal frame correlation
    private var pendingImageInfoByKey: [FrameKey: CompanionImageReadyInfo] = [:]
    private var latestProxyGeneration: UInt32 = 0
    private var nextRequestID: UInt32 = 1
    private var activeTileRequestID: UInt32 = 0
    private var activePhotosRequestID: UInt32 = 0

    private var cropThrottleTask: Task<Void, Never>?
    private var pendingCropToSend: NormalizedCropRect?
    private var toastClearTask: Task<Void, Never>?
    private var imageDecodeTask: Task<Void, Never>?
    private var tileDecodeTask: Task<Void, Never>?
    private var deferredEndBackgroundTask: Task<Void, Never>?
    private var deferredEndLiveActivityTask: Task<Void, Never>?
    private var latestLiveActivityPushToken: String?

    private static let notifyOnScanCompleteKey = "remote.notifyOnScanComplete"
    private static let liveActivityEnabledKey = "remote.liveActivityEnabled"

    private struct FrameKey: Hashable {
        let kind: CompanionFrameKind
        let generation: UInt32
        let requestID: UInt32
    }

    init(
        clientName: String = UIDevice.current.name,
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        userDefaults: UserDefaults = .standard,
        notifier: (any ScanCompletionNotifying)? = nil,
        backgroundTaskManager: (any BackgroundTaskManaging)? = nil,
        liveActivityManager: (any ScanLiveActivityManaging)? = nil
    ) {
        self.userDefaults = userDefaults
        if userDefaults.object(forKey: Self.notifyOnScanCompleteKey) == nil {
            self.notifyOnScanComplete = true
        } else {
            self.notifyOnScanComplete = userDefaults.bool(forKey: Self.notifyOnScanCompleteKey)
        }
        if userDefaults.object(forKey: Self.liveActivityEnabledKey) == nil {
            self.liveActivityEnabled = true
        } else {
            self.liveActivityEnabled = userDefaults.bool(forKey: Self.liveActivityEnabledKey)
        }
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if let notifier {
            self.notifier = notifier
        } else if isRunningTests {
            self.notifier = NoOpScanCompletionNotifier()
        } else {
            self.notifier = UserNotificationScanNotifier.shared
        }
        self.backgroundTaskManager = backgroundTaskManager ?? UIApplicationBackgroundTaskManager()
        if let liveActivityManager {
            self.liveActivityManager = liveActivityManager
        } else if isRunningTests {
            self.liveActivityManager = NoOpScanLiveActivityManager()
        } else {
            self.liveActivityManager = ActivityKitScanLiveActivityManager()
        }
        self.client = CompanionClient(clientName: clientName, tokenStore: tokenStore)
        self.liveActivityManager.onPushTokenUpdated = { [weak self] token in
            self?.handleLiveActivityPushTokenUpdated(token)
        }
        wireClientCallbacks()
        if notifier == nil && !isRunningTests {
            self.apnsDeviceToken = PushTokenRelay.shared.latestDeviceToken
            self.apnsRegistrationError = PushTokenRelay.shared.lastRegistrationError
            PushTokenRelay.shared.onTokenUpdated = { [weak self] token in
                self?.updateAPNsDeviceToken(token)
            }
            PushTokenRelay.shared.onRegistrationFailed = { [weak self] errorMessage in
                self?.updateAPNsRegistrationError(errorMessage)
            }
        }
        self.liveActivityManager.cleanupOrphanedActivities()
        browser.start()
        applyLaunchArgumentsIfPresent()
        refreshNotificationAuthorizationStatus()
    }

    private func wireClientCallbacks() {
        client.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.connectionStatus = status
            if status == .disconnected, case .connected = self.phase {
                self.phase = .browsing
            }
        }

        client.onHostMessage = { [weak self] message in
            self?.handleHostMessage(message)
        }

        client.onBinaryFrame = { [weak self] frame in
            self?.handleBinaryFrame(frame)
        }
    }

    private func applyLaunchArgumentsIfPresent() {
        let args = ProcessInfo.processInfo.arguments
        guard let hostIdx = args.firstIndex(of: "--connect-host"), hostIdx + 1 < args.count,
              let portIdx = args.firstIndex(of: "--connect-port"), portIdx + 1 < args.count,
              let port = UInt16(args[portIdx + 1]) else {
            return
        }
        let host = args[hostIdx + 1]
        var pin: String?
        if let pinIdx = args.firstIndex(of: "--connect-pin"), pinIdx + 1 < args.count {
            pin = args[pinIdx + 1]
        }
        connectManual(host: host, port: port, pin: pin)
    }

    // MARK: - Connection & Pairing

    func connect(to host: DiscoveredHost) {
        resetSessionImages()
        phase = .connecting(hostName: host.name)
        client.connect(to: .bonjour(name: host.name, endpoint: host.endpoint, hostID: host.hostID))
    }

    func connectManual(host: String, port: UInt16, pin: String? = nil) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, port > 0 else { return }
        lastManualHost = clean
        lastManualPort = "\(port)"
        resetSessionImages()
        phase = .connecting(hostName: "\(clean):\(port)")
        client.connect(to: .manual(host: clean, port: port), pin: pin)
    }

    func submitPIN(_ pin: String) {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 6 else { return }
        client.submitPIN(digits)
    }

    func disconnect() {
        endScanBackgroundTaskImmediately()
        endLiveActivity(finalState: nil, dismissImmediately: true)
        client.disconnect(clearTarget: true)
        phase = .browsing
        snapshot = nil
        progress = nil
        hostAPNsConfigured = false
        resetSessionImages()
        browser.start()
    }

    func handleScenePhaseActive() {
        isAppInBackground = false
        endScanBackgroundTaskImmediately()
        refreshNotificationAuthorizationStatus()
        if case .browsing = phase {
            browser.start()
        } else {
            client.reconnectIfNeeded()
        }
    }

    func handleScenePhaseBackground() {
        isAppInBackground = true
        guard notifyOnScanComplete, isScanActive, !isDirectAPNsActive else { return }
        deferredEndBackgroundTask?.cancel()
        deferredEndBackgroundTask = nil
        backgroundTaskManager.beginTask(name: "ChromaScanActiveScan") { [weak self] in
            self?.deferredEndBackgroundTask?.cancel()
            self?.deferredEndBackgroundTask = nil
        }
    }

    var isScanActive: Bool {
        guard let snap = snapshot, snap.isBusy else { return false }
        return (progress?.operation ?? snap.activeOperation) == .scan
    }

    func setNotifyOnScanComplete(_ enabled: Bool) {
        notifyOnScanComplete = enabled
        userDefaults.set(enabled, forKey: Self.notifyOnScanCompleteKey)
        if enabled {
            requestNotificationPermissionIfNeeded()
        } else {
            endScanBackgroundTaskImmediately()
        }
        syncPushRegistrationWithHost()
    }

    func setLiveActivityEnabled(_ enabled: Bool) {
        liveActivityEnabled = enabled
        userDefaults.set(enabled, forKey: Self.liveActivityEnabledKey)
        if !enabled {
            endLiveActivity(finalState: nil, dismissImmediately: true)
        } else if isScanActive, !isAppInBackground, let snap = snapshot {
            startLiveActivityIfNeeded(for: snap, progress: progress)
        }
    }

    func updateAPNsDeviceToken(_ token: String) {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        apnsDeviceToken = clean
        apnsRegistrationError = nil
        syncPushRegistrationWithHost()
    }

    func updateAPNsRegistrationError(_ message: String) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        apnsDeviceToken = nil
        apnsRegistrationError = clean
        syncPushRegistrationWithHost()
    }

    private var configuredTeamID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ChromaScanTeamID") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    func refreshNotificationAuthorizationStatus() {
        Task { [weak self] in
            guard let self else { return }
            let status = await self.notifier.authorizationStatus()
            self.notificationAuthorizationStatus = status
            if self.notifyOnScanComplete,
               (status == .authorized || status == .provisional || status == .ephemeral) {
                await self.notifier.registerForRemoteNotifications()
            }
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            let status = await self.notifier.requestAuthorizationIfNeeded()
            self.notificationAuthorizationStatus = status
            if self.notifyOnScanComplete,
               (status == .authorized || status == .provisional || status == .ephemeral) {
                await self.notifier.registerForRemoteNotifications()
            }
        }
    }

    private func syncPushRegistrationWithHost() {
        guard case .connected = phase else { return }
        client.send(.registerPushToken(
            deviceToken: notifyOnScanComplete ? apnsDeviceToken : nil,
            environment: currentPushEnvironment,
            enabled: notifyOnScanComplete,
            bundleID: Bundle.main.bundleIdentifier,
            teamID: configuredTeamID,
            registrationError: notifyOnScanComplete ? apnsRegistrationError : nil
        ))
    }

    private func handleLiveActivityPushTokenUpdated(_ token: String?) {
        let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        latestLiveActivityPushToken = (clean?.isEmpty == false) ? clean : nil
        syncLiveActivityPushTokenWithHost()
    }

    private func syncLiveActivityPushTokenWithHost() {
        guard case .connected = phase else { return }
        client.send(.registerLiveActivityToken(
            activityPushToken: latestLiveActivityPushToken,
            environment: currentPushEnvironment,
            bundleID: Bundle.main.bundleIdentifier
        ))
    }

    private func startLiveActivityIfNeeded(for snap: SessionSnapshot, progress: RemoteProgressState?) {
        guard liveActivityEnabled, !isAppInBackground, !liveActivityManager.hasActiveActivity else { return }
        deferredEndLiveActivityTask?.cancel()
        deferredEndLiveActivityTask = nil

        let scannerName = snap.selectedScanner?.displayTitle ?? "Scanner"
        let profileName = snap.settings.colorMode == .grayscale8
            ? "Grayscale"
            : snap.settings.colorProfile.shortName
        let startedAt = Date().addingTimeInterval(-(progress?.elapsedSeconds ?? 0))
        let initialState: ScanLiveActivityContentState
        if let progress, progress.operation == .scan {
            initialState = ScanLiveActivityContentState.fromProgress(
                bytesReceived: progress.bytesReceived,
                expectedBytes: progress.expectedBytes,
                statusText: progress.statusText
            )
        } else {
            initialState = ScanLiveActivityContentState(
                phase: .starting,
                statusText: "Starting scanner…"
            )
        }

        liveActivityManager.start(
            scannerName: scannerName,
            resolutionDPI: snap.settings.resolution,
            colorProfileName: profileName,
            outputFormatName: snap.settings.outputFormat.displayName,
            startedAt: startedAt,
            initialState: initialState
        )
    }

    private func endLiveActivity(finalState: ScanLiveActivityContentState?, dismissImmediately: Bool) {
        deferredEndLiveActivityTask?.cancel()
        deferredEndLiveActivityTask = nil
        guard liveActivityManager.hasActiveActivity else { return }
        liveActivityManager.end(finalState: finalState, dismissImmediately: dismissImmediately)
    }

    private func scheduleDeferredEndLiveActivity() {
        guard liveActivityManager.hasActiveActivity else { return }
        deferredEndLiveActivityTask?.cancel()
        deferredEndLiveActivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard let self, !Task.isCancelled else { return }
            self.deferredEndLiveActivityTask = nil
            if !self.isScanActive {
                self.liveActivityManager.end(finalState: nil, dismissImmediately: true)
            }
        }
    }

    private func endScanBackgroundTaskImmediately() {
        deferredEndBackgroundTask?.cancel()
        deferredEndBackgroundTask = nil
        backgroundTaskManager.endTask()
    }

    private func scheduleDeferredEndScanBackgroundTask() {
        guard backgroundTaskManager.hasActiveTask else { return }
        deferredEndBackgroundTask?.cancel()
        deferredEndBackgroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.deferredEndBackgroundTask = nil
            self.backgroundTaskManager.endTask()
        }
    }

    // MARK: - Remote Actions

    func selectScanner(id: String) {
        client.send(.selectScanner(scannerID: id))
    }

    func refreshScanners() {
        client.send(.refreshScanners)
    }

    func addManualScanner(host: String, port: Int, useTLS: Bool) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        client.send(.addManualScanner(host: clean, port: port, useTLS: useTLS))
    }

    func updateSettings(_ patch: ScanSettingsPatch) {
        if var snap = snapshot {
            var s = snap.settings
            if let v = patch.inputSource { s.inputSource = v }
            if let v = patch.resolution { s.resolution = v }
            if let v = patch.colorMode { s.colorMode = v }
            if let v = patch.intent { s.intent = v }
            if let v = patch.transferFormat { s.transferFormat = v }
            if let v = patch.rotation { s.rotation = v }
            if let v = patch.autoTrimEmptySpace { s.autoTrimEmptySpace = v }
            if let v = patch.hardwareBrightness { s.hardwareBrightness = v }
            if let v = patch.hardwareContrast { s.hardwareContrast = v }
            if let v = patch.colorProfile { s.colorProfile = v }
            if let v = patch.outputFormat { s.outputFormat = v }
            if let v = patch.quality { s.quality = v }
            if let v = patch.previewCompressionEnabled { s.previewCompressionEnabled = v }
            if let v = patch.toneAdjustments { s.toneAdjustments = v }
            if patch.resetSoftwareTone == true { s.toneAdjustments = ToneAdjustments() }
            if let v = patch.baseFilename { s.baseFilename = v }
            if let v = patch.autoIncrement { s.autoIncrement = v }
            snap = SessionSnapshot(
                scanners: snap.scanners,
                selectedScannerID: snap.selectedScannerID,
                capabilities: snap.capabilities,
                scannerStatus: snap.scannerStatus,
                settings: s,
                cropRect: snap.cropRect,
                viewMode: snap.viewMode,
                isBusy: snap.isBusy,
                activeOperation: snap.activeOperation,
                statusText: snap.statusText,
                isErrorStatus: snap.isErrorStatus,
                hasPreviewImage: snap.hasPreviewImage,
                hasScanImage: snap.hasScanImage,
                platenAspectRatio: snap.platenAspectRatio,
                lastSavedFilename: snap.lastSavedFilename,
                saveFolderDisplayName: snap.saveFolderDisplayName,
                outputPreviewSummary: snap.outputPreviewSummary,
                activeImageGeneration: snap.activeImageGeneration,
                scanPixelWidth: snap.scanPixelWidth,
                scanPixelHeight: snap.scanPixelHeight,
                scanDPI: snap.scanDPI,
                isScanTrimmed: snap.isScanTrimmed
            )
            snapshot = snap
        }
        client.send(.updateSettings(patch: patch))
    }

    func setCropRect(_ rect: NormalizedCropRect, immediate: Bool = false) {
        let clamped = rect.clamped()
        if let snap = snapshot {
            snapshot = SessionSnapshot(
                scanners: snap.scanners,
                selectedScannerID: snap.selectedScannerID,
                capabilities: snap.capabilities,
                scannerStatus: snap.scannerStatus,
                settings: snap.settings,
                cropRect: clamped,
                viewMode: snap.viewMode,
                isBusy: snap.isBusy,
                activeOperation: snap.activeOperation,
                statusText: snap.statusText,
                isErrorStatus: snap.isErrorStatus,
                hasPreviewImage: snap.hasPreviewImage,
                hasScanImage: snap.hasScanImage,
                platenAspectRatio: snap.platenAspectRatio,
                lastSavedFilename: snap.lastSavedFilename,
                saveFolderDisplayName: snap.saveFolderDisplayName,
                outputPreviewSummary: snap.outputPreviewSummary,
                activeImageGeneration: snap.activeImageGeneration,
                scanPixelWidth: snap.scanPixelWidth,
                scanPixelHeight: snap.scanPixelHeight,
                scanDPI: snap.scanDPI,
                isScanTrimmed: snap.isScanTrimmed
            )
        }

        if immediate {
            cropThrottleTask?.cancel()
            cropThrottleTask = nil
            pendingCropToSend = nil
            client.send(.setCropRect(cropRect: clamped))
            return
        }

        pendingCropToSend = clamped
        if cropThrottleTask == nil {
            cropThrottleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(45))
                guard let self else { return }
                self.cropThrottleTask = nil
                if let pending = self.pendingCropToSend {
                    self.pendingCropToSend = nil
                    self.client.send(.setCropRect(cropRect: pending))
                }
            }
        }
    }

    func resetCrop() {
        setCropRect(.full, immediate: true)
    }

    func trimEmptySpace() {
        if snapshot?.viewMode == .scan {
            clearHighResTile()
        }
        client.send(.trimEmptySpace)
    }

    func setViewMode(_ mode: CanvasViewMode) {
        clearHighResTile()
        client.send(.setViewMode(mode: mode))
    }

    func triggerPreview() {
        client.send(.triggerPreview)
    }

    func triggerScan() {
        if notifyOnScanComplete {
            requestNotificationPermissionIfNeeded()
        }
        client.send(.triggerScan)
    }

    func triggerExport() {
        client.send(.triggerExport)
    }

    func cancelActiveOperation() {
        client.send(.cancel)
    }

    func requestHighResTile(normalizedRect: NormalizedCropRect, maxPixelWidth: Int) {
        guard snapshot?.viewMode == .scan, snapshot?.hasScanImage == true else { return }
        let reqID = allocateRequestID()
        activeTileRequestID = reqID
        isLoadingTile = true
        client.send(.requestTile(
            requestID: reqID,
            normalizedRect: normalizedRect,
            maxPixelWidth: max(256, min(3200, maxPixelWidth))
        ))
    }

    func clearHighResTile() {
        activeTileRequestID = 0
        tileImage = nil
        tileNormalizedRect = nil
        isLoadingTile = false
    }

    func saveCopyToPhotos() {
        guard snapshot?.hasScanImage == true, !isSavingToPhotos else { return }
        let reqID = allocateRequestID()
        activePhotosRequestID = reqID
        isSavingToPhotos = true
        let format: OutputFormat = (snapshot?.settings.outputFormat == .jpeg) ? .jpeg : .heic
        let quality = snapshot?.settings.quality ?? 0.92
        client.send(.requestPhotosCopy(requestID: reqID, format: format, quality: quality))
    }

    // MARK: - Computed Dimensions & Active Operation Summary

    var dimensionsReadout: String {
        guard let snap = snapshot else { return "" }
        if snap.viewMode == .scan,
           let w = snap.scanPixelWidth,
           let h = snap.scanPixelHeight,
           let dpi = snap.scanDPI {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            let pw = nf.string(from: NSNumber(value: w)) ?? "\(w)"
            let ph = nf.string(from: NSNumber(value: h)) ?? "\(h)"
            let profile = snap.settings.colorMode == .grayscale8 ? "Grayscale" : snap.settings.colorProfile.shortName
            let trimSuffix = snap.isScanTrimmed ? " · Trimmed" : ""
            return "\(pw)×\(ph) px · \(dpi) DPI · \(profile)\(trimSuffix)"
        }

        return plannedCaptureReadout
    }

    var plannedCaptureReadout: String {
        guard let snap = snapshot else { return "" }
        let source = snap.settings.inputSource
        let inputCaps = snap.capabilities?.caps(for: source) ?? snap.capabilities?.platen
        let maxW = inputCaps?.maxWidth ?? 2550
        let maxH = inputCaps?.maxHeight ?? 3508
        let crop = (source == .feeder) ? .full : snap.cropRect
        let region = crop.toESCLRegion(maxWidth: maxW, maxHeight: maxH)
        let dpi = snap.settings.resolution
        let bpp = snap.settings.colorMode.bytesPerPixel

        var wIn = Double(region.width) / 300.0
        var hIn = Double(region.height) / 300.0
        var pxW = Int((wIn * Double(dpi)).rounded())
        var pxH = Int((hIn * Double(dpi)).rounded())
        if snap.settings.rotation == .deg90 || snap.settings.rotation == .deg270 {
            swap(&wIn, &hIn)
            swap(&pxW, &pxH)
        }
        let rawMB = Double(Int64(pxW) * Int64(pxH) * Int64(bpp)) / (1024.0 * 1024.0)
        let sizeStr = rawMB >= 10.0 ? String(format: "%.0f MB", rawMB) : String(format: "%.1f MB", rawMB)
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let pw = nf.string(from: NSNumber(value: pxW)) ?? "\(pxW)"
        let ph = nf.string(from: NSNumber(value: pxH)) ?? "\(pxH)"
        return String(format: "%.2f\"×%.2f\" · %@×%@ (%@ raw)", wIn, hIn, pw, ph, sizeStr)
    }

    var activeOperationInfo: RemoteOperationDisplayInfo {
        guard let snap = snapshot else {
            return RemoteOperationDisplayInfo(
                title: "Working…",
                statusDetail: "",
                trailingBadge: nil,
                progressFraction: nil,
                metadataSummary: ""
            )
        }

        let op = progress?.operation ?? snap.activeOperation
        let rawStatus = (progress?.statusText ?? snap.statusText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isProcessingPhase = rawStatus.hasPrefix("Processing") || rawStatus.hasPrefix("Rendering")

        let title: String
        switch op {
        case .preview:
            title = rawStatus.hasPrefix("Rendering") ? "Rendering Preview" : "Previewing Flatbed"
        case .scan:
            title = rawStatus.hasPrefix("Processing")
                ? "Processing & Saving"
                : "Scanning · \(snap.settings.resolution) DPI"
        case .export:
            title = "Exporting Scan"
        case nil:
            title = "Working…"
        }

        let fraction: Double?
        if let progress,
           op != .export,
           !isProcessingPhase,
           progress.expectedBytes > 0,
           progress.bytesReceived > 0 {
            fraction = progress.fraction
        } else {
            fraction = nil
        }

        let statusDetail: String
        let trailingBadge: String?

        if let progress {
            if isProcessingPhase || op == .export {
                statusDetail = rawStatus.isEmpty ? title : rawStatus
                trailingBadge = progress.elapsedSeconds >= 1.0
                    ? Self.formatElapsedSeconds(progress.elapsedSeconds)
                    : nil
            } else if progress.bytesReceived > 0 && progress.expectedBytes > 0 {
                let recvStr = Self.formatMegabytes(progress.bytesReceived)
                let expStr = Self.formatMegabytes(progress.expectedBytes)
                let elapsedStr = Self.formatElapsedSeconds(progress.elapsedSeconds)
                statusDetail = "\(recvStr) / \(expStr) · \(elapsedStr)"
                let pct = Int(((fraction ?? 0) * 100.0).rounded())
                trailingBadge = "\(pct)%"
            } else if progress.bytesReceived > 0 {
                let recvStr = Self.formatMegabytes(progress.bytesReceived)
                let elapsedStr = Self.formatElapsedSeconds(progress.elapsedSeconds)
                statusDetail = "\(recvStr) received · \(elapsedStr)"
                trailingBadge = nil
            } else if progress.expectedBytes > 0 {
                let expStr = Self.formatMegabytes(progress.expectedBytes)
                statusDetail = "Starting scanner… · \(expStr) expected"
                trailingBadge = nil
            } else {
                statusDetail = rawStatus.isEmpty ? "Starting…" : rawStatus
                trailingBadge = nil
            }
        } else {
            statusDetail = rawStatus.isEmpty ? "Starting…" : rawStatus
            trailingBadge = nil
        }

        let metadataSummary: String
        switch op {
        case .scan:
            let profile = snap.settings.colorMode == .grayscale8
                ? "Grayscale"
                : snap.settings.colorProfile.shortName
            let details = [plannedCaptureReadout, profile, snap.settings.outputFormat.displayName]
                .filter { !$0.isEmpty }
            metadataSummary = details.joined(separator: " · ")
        case .preview:
            let scanner = snap.selectedScanner?.displayTitle ?? "Flatbed"
            metadataSummary = "\(scanner) · Full Page · \(snap.settings.colorMode.displayName)"
        case .export:
            let base = dimensionsReadout
            let fmt = snap.settings.outputFormat.displayName
            metadataSummary = base.isEmpty ? fmt : "\(base) · \(fmt)"
        case nil:
            metadataSummary = dimensionsReadout
        }

        return RemoteOperationDisplayInfo(
            title: title,
            statusDetail: statusDetail,
            trailingBadge: trailingBadge,
            progressFraction: fraction,
            metadataSummary: metadataSummary
        )
    }

    nonisolated static func formatMegabytes(_ bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    nonisolated static func formatElapsedSeconds(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 60 {
            let mins = total / 60
            let secs = total % 60
            return "\(mins)m \(secs)s"
        }
        return "\(total)s"
    }

    // MARK: - Incoming Host Messages & Binary Frames

    private func handleHostMessage(_ message: HostMessage) {
        switch message {
        case .welcome(_, let hostID, let hostName, let authToken, let snap):
            client.saveAuthToken(authToken, hostID: hostID)
            phase = .connected(hostID: hostID, hostName: hostName)
            // Every (re)connect starts a fresh image stream: the host pushes its current proxy right
            // after welcome, and a relaunched host restarts its generation counter, so stale
            // `latestProxyGeneration` from a previous host process would drop every new frame.
            resetSessionImages()
            applyIncomingSnapshot(snap)
            syncPushRegistrationWithHost()
            if liveActivityManager.hasActiveActivity && isScanActive {
                syncLiveActivityPushTokenWithHost()
            } else if !isScanActive {
                endLiveActivity(finalState: nil, dismissImmediately: true)
            }
            refreshNotificationAuthorizationStatus()

        case .authRequired(let hostID, let hostName, let reason):
            if let reason, !reason.isEmpty {
                client.clearSavedToken(hostID: hostID)
            }
            phase = .needsPIN(hostID: hostID, hostName: hostName, reason: reason)

        case .snapshot(let snap):
            applyIncomingSnapshot(snap)

        case .progress(let op, let recv, let exp, let elapsed, let text):
            let newProgress = RemoteProgressState(
                operation: op,
                bytesReceived: recv,
                expectedBytes: exp,
                elapsedSeconds: elapsed,
                statusText: text
            )
            progress = newProgress
            if op == .scan {
                if !liveActivityManager.hasActiveActivity, let snap = snapshot {
                    startLiveActivityIfNeeded(for: snap, progress: newProgress)
                }
                if liveActivityManager.hasActiveActivity {
                    let state = ScanLiveActivityContentState.fromProgress(
                        bytesReceived: recv,
                        expectedBytes: exp,
                        statusText: text
                    )
                    liveActivityManager.update(state)
                }
            }

        case .imageReady(let info):
            let key = FrameKey(kind: info.kind.frameKind, generation: info.generation, requestID: info.requestID)
            pendingImageInfoByKey[key] = info
            if info.kind == .previewProxy || info.kind == .scanProxy {
                if info.generation >= latestProxyGeneration {
                    latestProxyGeneration = info.generation
                }
            }

        case .scanCompleted(let filename, let pxW, let pxH, let bytes, let elapsedSeconds):
            progress = nil
            let mb = Double(bytes) / (1024.0 * 1024.0)
            showToast(String(format: "Saved %@ (%dx%d · %.1f MB)", filename, pxW, pxH, mb))
            let completedState = ScanLiveActivityContentState.completed(
                filename: filename,
                pixelWidth: pxW,
                pixelHeight: pxH,
                fileSizeBytes: bytes
            )
            endLiveActivity(finalState: completedState, dismissImmediately: !isAppInBackground)
            handleScanCompletedNotification(
                filename: filename,
                pixelWidth: pxW,
                pixelHeight: pxH,
                fileSizeBytes: bytes,
                elapsedSeconds: elapsedSeconds
            )

        case .exportCompleted(let filename, let bytes, _):
            progress = nil
            let mb = Double(bytes) / (1024.0 * 1024.0)
            showToast(String(format: "Exported %@ (%.1f MB)", filename, mb))

        case .pushStatus(let apnsConfigured):
            hostAPNsConfigured = apnsConfigured
            if apnsConfigured && notifyOnScanComplete {
                requestNotificationPermissionIfNeeded()
            }

        case .error(let title, let message):
            isSavingToPhotos = false
            endScanBackgroundTaskImmediately()
            let failedState = ScanLiveActivityContentState.failed(title: title, message: message)
            endLiveActivity(finalState: failedState, dismissImmediately: !isAppInBackground)
            errorAlert = RemoteErrorAlert(title: title, message: message)

        case .pong:
            break
        }
    }

    private func handleScanCompletedNotification(
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int64,
        elapsedSeconds: Double
    ) {
        deferredEndBackgroundTask?.cancel()
        deferredEndBackgroundTask = nil

        guard notifyOnScanComplete else {
            backgroundTaskManager.endTask()
            return
        }

        // When backgrounded with Direct Mac -> APNs active, let the Mac's APNs push
        // deliver the single lock-screen alert to avoid duplicate notifications.
        if isAppInBackground && isDirectAPNsActive {
            backgroundTaskManager.endTask()
            return
        }

        let payload = ScanCompletionNotificationPayload(
            filename: filename,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fileSizeBytes: fileSizeBytes,
            elapsedSeconds: elapsedSeconds
        )

        Task { [weak self] in
            guard let self else { return }
            await self.notifier.postScanCompleted(payload)
            self.notificationAuthorizationStatus = await self.notifier.authorizationStatus()
            self.backgroundTaskManager.endTask()
        }
    }

    private func applyIncomingSnapshot(_ snap: SessionSnapshot) {
        let wasScanActive = isScanActive
        let modeChanged = (snapshot?.viewMode != snap.viewMode)
        let genChanged = (snapshot?.activeImageGeneration != snap.activeImageGeneration)
        snapshot = snap

        if !snap.isBusy {
            progress = nil
        }

        let nowScanActive = isScanActive
        if !wasScanActive && nowScanActive {
            if notifyOnScanComplete {
                requestNotificationPermissionIfNeeded()
            }
            startLiveActivityIfNeeded(for: snap, progress: progress)
        } else if wasScanActive && !nowScanActive {
            scheduleDeferredEndScanBackgroundTask()
            if snap.statusText.localizedCaseInsensitiveContains("cancel") {
                endLiveActivity(finalState: nil, dismissImmediately: true)
            } else {
                scheduleDeferredEndLiveActivity()
            }
        }

        if modeChanged || genChanged {
            clearHighResTile()
        }

        let hasActiveImage = (snap.viewMode == .scan) ? snap.hasScanImage : snap.hasPreviewImage
        if !hasActiveImage {
            proxyImage = nil
            proxyInfo = nil
            clearHighResTile()
        }
    }

    private func handleBinaryFrame(_ frame: CompanionBinaryFrame) {
        let key = FrameKey(kind: frame.kind, generation: frame.generation, requestID: frame.requestID)
        let info = pendingImageInfoByKey.removeValue(forKey: key)

        switch frame.kind {
        case .previewProxy, .scanProxy:
            guard frame.generation >= latestProxyGeneration else { return }
            latestProxyGeneration = frame.generation
            let payload = frame.payload
            let gen = frame.generation
            imageDecodeTask?.cancel()
            imageDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let image = Self.decodeDisplayP3UIImage(from: payload) else { return }
                await MainActor.run { [weak self] in
                    guard let self, gen >= self.latestProxyGeneration else { return }
                    self.proxyImage = image
                    if let info {
                        self.proxyInfo = info
                    }
                    self.clearHighResTile()
                }
            }

        case .highResTile:
            guard frame.requestID == activeTileRequestID else { return }
            let payload = frame.payload
            let reqID = frame.requestID
            tileDecodeTask?.cancel()
            tileDecodeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let image = Self.decodeDisplayP3UIImage(from: payload) else { return }
                await MainActor.run { [weak self] in
                    guard let self, reqID == self.activeTileRequestID else { return }
                    self.tileImage = image
                    self.tileNormalizedRect = info?.normalizedRect
                    self.isLoadingTile = false
                }
            }

        case .photosCopy:
            guard frame.requestID == activePhotosRequestID else { return }
            persistImageDataToPhotosLibrary(frame.payload)
        }
    }

    private nonisolated static func decodeDisplayP3UIImage(from data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private func persistImageDataToPhotosLibrary(_ data: Data) {
        Task { [weak self] in
            guard let self else { return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                self.isSavingToPhotos = false
                self.errorAlert = RemoteErrorAlert(
                    title: "Photos Access Needed",
                    message: "Allow ChromaScan Companion to add photos in iOS Settings to save a copy to your library."
                )
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }
                self.isSavingToPhotos = false
                self.showToast("Saved Display P3 copy to Photos")
            } catch {
                self.isSavingToPhotos = false
                self.errorAlert = RemoteErrorAlert(title: "Save to Photos Failed", message: error.localizedDescription)
            }
        }
    }

    private func allocateRequestID() -> UInt32 {
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        return nextRequestID
    }

    private func resetSessionImages() {
        proxyImage = nil
        proxyInfo = nil
        latestProxyGeneration = 0
        pendingImageInfoByKey.removeAll()
        clearHighResTile()
    }

    private func showToast(_ text: String) {
        toastMessage = text
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, !Task.isCancelled else { return }
            self.toastMessage = nil
        }
    }
}
