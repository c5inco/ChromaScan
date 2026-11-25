import XCTest
import Network
import UIKit
import CoreGraphics
@preconcurrency import UserNotifications
@testable import ChromaScanRemote

@MainActor
final class ChromaScanRemoteTests: XCTestCase {

    func testNormalizedCropRectRotationParityOnIOS() {
        let crop = NormalizedCropRect(x: 0.15, y: 0.30, width: 0.45, height: 0.35)
        for rotation in ScanRotation.allCases {
            let display = crop.physicalToDisplay(rotation: rotation)
            let physical = NormalizedCropRect.fromDisplayRect(display, rotation: rotation)
            XCTAssertEqual(physical.x, crop.x, accuracy: 0.0001)
            XCTAssertEqual(physical.y, crop.y, accuracy: 0.0001)
            XCTAssertEqual(physical.width, crop.width, accuracy: 0.0001)
            XCTAssertEqual(physical.height, crop.height, accuracy: 0.0001)
        }
    }

    func testRemoteSessionStoreConnectsPairsDecodesDisplayP3ProxyAndTile() async throws {
        // Start a real loopback NWListener WebSocket server acting as Mac Studio Host right inside iOS test process
        let mockHost = try LoopbackMockMacHost(pin: "654321")
        let port = try await mockHost.start()
        defer { mockHost.stop() }

        let tokenStore = KeychainTokenStore()
        tokenStore.deleteToken(for: "mock-mac-studio")
        tokenStore.deleteToken(for: "manual:127.0.0.1:\(port)")

        let store = RemoteSessionStore(clientName: "Simulator iPhone", tokenStore: tokenStore)
        defer { store.disconnect() }

        // 1. Connect without PIN -> should enter .needsPIN
        store.connectManual(host: "127.0.0.1", port: port)
        try await waitUntil(timeout: 3.0) {
            if case .needsPIN = store.phase { return true }
            return false
        }

        // 2. Submit correct PIN -> connected + snapshot + Display P3 proxy UIImage decoded
        store.submitPIN("654321")
        try await waitUntil(timeout: 3.0) {
            if case .connected = store.phase, store.snapshot != nil, store.proxyImage != nil {
                return true
            }
            return false
        }
        XCTAssertEqual(store.snapshot?.selectedScannerID, "hp-3830")
        let proxyCG = try XCTUnwrap(store.proxyImage?.cgImage)
        XCTAssertEqual(proxyCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // 3. Switch to scan mode, test remote trim & request 1:1 high-res tile
        store.setViewMode(.scan)
        try await waitUntil(timeout: 2.0) { store.snapshot?.viewMode == .scan }

        store.trimEmptySpace()
        try await waitUntil(timeout: 2.0) { store.snapshot?.isScanTrimmed == true }
        XCTAssertTrue(store.dimensionsReadout.contains("Trimmed"))

        store.requestHighResTile(
            normalizedRect: NormalizedCropRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            maxPixelWidth: 1200
        )
        try await waitUntil(timeout: 3.0) { store.tileImage != nil && store.tileNormalizedRect != nil }
        let tileCG = try XCTUnwrap(store.tileImage?.cgImage)
        XCTAssertEqual(tileCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(store.tileNormalizedRect?.x ?? -1, 0.2, accuracy: 0.01)

        // 4. Token was persisted -> disconnecting and reconnecting without PIN succeeds automatically!
        store.disconnect()
        store.connectManual(host: "127.0.0.1", port: port)
        try await waitUntil(timeout: 3.0) {
            if case .connected = store.phase { return true }
            return false
        }
    }

    func testActiveOperationDisplayInfoAcrossScanLifecycle() async throws {
        XCTAssertEqual(RemoteSessionStore.formatElapsedSeconds(14.2), "14s")
        XCTAssertEqual(RemoteSessionStore.formatElapsedSeconds(75.0), "1m 15s")
        XCTAssertEqual(RemoteSessionStore.formatMegabytes(5 * 1024 * 1024), "5.0 MB")

        let mockHost = try LoopbackMockMacHost(pin: "123456")
        let port = try await mockHost.start()
        defer { mockHost.stop() }

        let tokenStore = KeychainTokenStore()
        tokenStore.deleteToken(for: "mock-mac-studio")
        tokenStore.deleteToken(for: "manual:127.0.0.1:\(port)")

        let store = RemoteSessionStore(clientName: "Simulator iPhone", tokenStore: tokenStore)
        defer { store.disconnect() }

        store.connectManual(host: "127.0.0.1", port: port, pin: "123456")
        try await waitUntil(timeout: 3.0) {
            if case .connected = store.phase, store.snapshot != nil { return true }
            return false
        }

        // Trigger scan -> warm-up phase (bytesReceived == 0) is indeterminate
        store.triggerScan()
        try await waitUntil(timeout: 2.0) {
            store.snapshot?.isBusy == true && store.progress != nil
        }
        let warmup = store.activeOperationInfo
        XCTAssertEqual(warmup.title, "Scanning · 1200 DPI")
        XCTAssertNil(warmup.progressFraction)
        XCTAssertTrue(warmup.statusDetail.contains("expected"))
        XCTAssertFalse(warmup.metadataSummary.isEmpty)

        // Advance to active transfer -> determinate fraction & percentage badge
        mockHost.broadcastProgress(
            operation: .scan,
            bytesReceived: 40 * 1024 * 1024,
            expectedBytes: 100 * 1024 * 1024,
            elapsedSeconds: 12,
            statusText: "Scanning 1200 DPI · 40.0 / 100.0 MB (12s)"
        )
        try await waitUntil(timeout: 2.0) { store.progress?.bytesReceived == 40 * 1024 * 1024 }
        let transferring = store.activeOperationInfo
        XCTAssertEqual(transferring.title, "Scanning · 1200 DPI")
        XCTAssertEqual(transferring.progressFraction ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(transferring.trailingBadge, "40%")
        XCTAssertEqual(transferring.statusDetail, "40.0 MB / 100.0 MB · 12s")

        // Advance to processing & saving phase -> switches back to indeterminate with elapsed badge
        mockHost.broadcastProgress(
            operation: .scan,
            bytesReceived: 100 * 1024 * 1024,
            expectedBytes: 100 * 1024 * 1024,
            elapsedSeconds: 68,
            statusText: "Processing & saving (Display P3)…"
        )
        try await waitUntil(timeout: 2.0) { store.progress?.statusText == "Processing & saving (Display P3)…" }
        let processing = store.activeOperationInfo
        XCTAssertEqual(processing.title, "Processing & Saving")
        XCTAssertNil(processing.progressFraction)
        XCTAssertEqual(processing.statusDetail, "Processing & saving (Display P3)…")
        XCTAssertEqual(processing.trailingBadge, "1m 8s")

        // Cancel -> returns to idle and clears progress
        store.cancelActiveOperation()
        try await waitUntil(timeout: 2.0) { store.snapshot?.isBusy == false && store.progress == nil }
    }

    func testScanCompletionNotificationPayloadFormatting() {
        let shortPayload = ScanCompletionNotificationPayload(
            filename: "scan-001.tiff",
            pixelWidth: 2400,
            pixelHeight: 3200,
            fileSizeBytes: 12 * 1024 * 1024,
            elapsedSeconds: 0.4
        )
        XCTAssertEqual(shortPayload.title, "Scan Complete")
        XCTAssertEqual(shortPayload.body, "scan-001.tiff · 2400×3200 · 12.0 MB")

        let timedPayload = ScanCompletionNotificationPayload(
            filename: "watercolor-004.png",
            pixelWidth: 10200,
            pixelHeight: 13200,
            fileSizeBytes: 157_286_400,
            elapsedSeconds: 75.0
        )
        XCTAssertEqual(timedPayload.body, "watercolor-004.png · 10200×13200 · 150.0 MB · 1m 15s")
    }

    func testScanCompletionPostsLocalNotificationAndManagesBackgroundTask() async throws {
        let mockHost = try LoopbackMockMacHost(pin: "123456")
        let port = try await mockHost.start()
        defer { mockHost.stop() }

        let tokenStore = KeychainTokenStore()
        tokenStore.deleteToken(for: "mock-mac-studio")
        tokenStore.deleteToken(for: "manual:127.0.0.1:\(port)")

        let suiteName = "com.chromascan.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mockNotifier = MockScanCompletionNotifier(initialStatus: .notDetermined, statusAfterRequest: .authorized)
        let mockBG = MockBackgroundTaskManager()

        let store = RemoteSessionStore(
            clientName: "Simulator iPhone",
            tokenStore: tokenStore,
            userDefaults: defaults,
            notifier: mockNotifier,
            backgroundTaskManager: mockBG
        )
        defer { store.disconnect() }

        XCTAssertTrue(store.notifyOnScanComplete)

        store.connectManual(host: "127.0.0.1", port: port, pin: "123456")
        try await waitUntil(timeout: 3.0) {
            if case .connected = store.phase, store.snapshot != nil { return true }
            return false
        }

        // Backgrounding while idle should NOT begin a background task
        store.handleScenePhaseBackground()
        XCTAssertEqual(mockBG.beginCount, 0)
        XCTAssertFalse(mockBG.hasActiveTask)

        // Trigger scan -> requests notification authorization and transitions to active scan
        store.triggerScan()
        try await waitUntil(timeout: 2.0) {
            store.isScanActive && store.notificationAuthorizationStatus == .authorized
        }
        let requestCount = await mockNotifier.requestCount
        XCTAssertGreaterThanOrEqual(requestCount, 1)

        // Backgrounding while scan is active begins a background task
        store.handleScenePhaseBackground()
        XCTAssertEqual(mockBG.beginCount, 1)
        XCTAssertTrue(mockBG.hasActiveTask)

        // Complete scan (host sends snapshot(isBusy: false) followed by scanCompleted, matching ScanSessionEngine)
        mockHost.broadcastScanCompleted(
            filename: "art-002.tiff",
            pixelWidth: 4800,
            pixelHeight: 6400,
            fileSizeBytes: 52_428_800,
            elapsedSeconds: 18.0
        )

        try await waitUntil(timeout: 2.0) { !mockBG.hasActiveTask }
        let posted = await mockNotifier.postedPayloads
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(
            posted.first,
            ScanCompletionNotificationPayload(
                filename: "art-002.tiff",
                pixelWidth: 4800,
                pixelHeight: 6400,
                fileSizeBytes: 52_428_800,
                elapsedSeconds: 18.0
            )
        )
        XCTAssertEqual(mockBG.endCount, 1)

        // Disable notifications -> setting persists, no background task or notification on next scan
        store.setNotifyOnScanComplete(false)
        XCTAssertFalse(store.notifyOnScanComplete)
        XCTAssertFalse(defaults.bool(forKey: "remote.notifyOnScanComplete"))

        store.triggerScan()
        try await waitUntil(timeout: 2.0) { store.isScanActive }
        store.handleScenePhaseBackground()
        XCTAssertEqual(mockBG.beginCount, 1)

        mockHost.broadcastScanCompleted(
            filename: "art-003.tiff",
            pixelWidth: 4800,
            pixelHeight: 6400,
            fileSizeBytes: 52_428_800,
            elapsedSeconds: 20.0
        )
        try await waitUntil(timeout: 2.0) { !store.isScanActive }
        try await Task.sleep(for: .milliseconds(100))
        let postedAfterDisable = await mockNotifier.postedPayloads
        XCTAssertEqual(postedAfterDisable.count, 1)
    }

    func testDirectAPNsTokenSyncAndBackgroundLocalDeduplication() async throws {
        let mockHost = try LoopbackMockMacHost(pin: "123456", apnsConfigured: true)
        let port = try await mockHost.start()
        defer { mockHost.stop() }

        let tokenStore = KeychainTokenStore()
        tokenStore.deleteToken(for: "mock-mac-studio")
        tokenStore.deleteToken(for: "manual:127.0.0.1:\(port)")

        let suiteName = "com.chromascan.apns.ios.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mockNotifier = MockScanCompletionNotifier(initialStatus: .authorized, statusAfterRequest: .authorized)
        let mockBG = MockBackgroundTaskManager()

        let store = RemoteSessionStore(
            clientName: "Simulator iPhone",
            tokenStore: tokenStore,
            userDefaults: defaults,
            notifier: mockNotifier,
            backgroundTaskManager: mockBG
        )
        defer { store.disconnect() }

        store.connectManual(host: "127.0.0.1", port: port, pin: "123456")
        try await waitUntil(timeout: 3.0) {
            if case .connected = store.phase, store.hostAPNsConfigured { return true }
            return false
        }

        // Register APNs token -> synced to Mac host
        store.updateAPNsDeviceToken("0123456789abcdef")
        try await waitUntil(timeout: 2.0) {
            mockHost.lastRegisteredPushToken == "0123456789abcdef" && mockHost.lastPushEnabled == true
        }
        XCTAssertTrue(store.isDirectAPNsActive)
        let remoteRegCount = await mockNotifier.remoteRegisterCount
        XCTAssertGreaterThanOrEqual(remoteRegCount, 1)

        // When backgrounded with Direct APNs active, do NOT start local background task or double-notify locally
        store.triggerScan()
        try await waitUntil(timeout: 2.0) { store.isScanActive }
        store.handleScenePhaseBackground()
        XCTAssertEqual(mockBG.beginCount, 0)

        mockHost.broadcastScanCompleted(
            filename: "locked-scan-001.tiff",
            pixelWidth: 4800,
            pixelHeight: 6400,
            fileSizeBytes: 52_428_800,
            elapsedSeconds: 45
        )
        try await waitUntil(timeout: 2.0) { !store.isScanActive }
        try await Task.sleep(for: .milliseconds(100))
        let postedWhileBackground = await mockNotifier.postedPayloads
        XCTAssertEqual(postedWhileBackground.count, 0)

        // Returning to foreground -> local notification fires immediately on scan completion
        store.handleScenePhaseActive()
        store.triggerScan()
        try await waitUntil(timeout: 2.0) { store.isScanActive }
        mockHost.broadcastScanCompleted(
            filename: "fg-scan-002.tiff",
            pixelWidth: 4800,
            pixelHeight: 6400,
            fileSizeBytes: 52_428_800,
            elapsedSeconds: 12
        )
        try await waitUntil(timeout: 2.0) { !store.isScanActive }
        try await waitUntil(timeout: 2.0) {
            store.toastMessage?.contains("fg-scan-002.tiff") == true
        }
        try await Task.sleep(for: .milliseconds(100))
        let postedInForeground = await mockNotifier.postedPayloads
        XCTAssertEqual(postedInForeground.count, 1)
        XCTAssertEqual(postedInForeground.first?.filename, "fg-scan-002.tiff")

        // Turning off notifications notifies Mac host to disable push for this device
        store.setNotifyOnScanComplete(false)
        try await waitUntil(timeout: 2.0) {
            mockHost.lastPushEnabled == false && mockHost.lastRegisteredPushToken == nil
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

// MARK: - Loopback Mock Mac Host for iOS Client Verification

@MainActor
private final class LoopbackMockMacHost {
    private let pin: String
    private let apnsConfigured: Bool
    private let validToken = "ios-test-token-256bit"
    private let queue = DispatchQueue(label: "com.chromascan.iostest.mockhost")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var currentViewMode: CanvasViewMode = .preview
    private var isBusy: Bool = false
    private var activeOperation: CompanionOperation?
    private var currentStatusText: String = "Ready"
    private var isScanTrimmed: Bool = false
    private(set) var lastRegisteredPushToken: String?
    private(set) var lastPushEnabled: Bool?

    init(pin: String, apnsConfigured: Bool = false) throws {
        self.pin = pin
        self.apnsConfigured = apnsConfigured
    }

    func start() async throws -> UInt16 {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.maximumMessageSize = CompanionConstants.maximumMessageSize
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            final class PortResumeBox: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                let cont: CheckedContinuation<UInt16, Error>
                init(_ cont: CheckedContinuation<UInt16, Error>) { self.cont = cont }
                func resume(returning port: UInt16) {
                    lock.lock()
                    guard !resumed else { lock.unlock(); return }
                    resumed = true
                    lock.unlock()
                    cont.resume(returning: port)
                }
                func resume(throwing error: Error) {
                    lock.lock()
                    guard !resumed else { lock.unlock(); return }
                    resumed = true
                    lock.unlock()
                    cont.resume(throwing: error)
                }
            }
            let box = PortResumeBox(cont)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    box.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let err):
                    box.resume(throwing: err)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.accept(conn)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        for c in connections { c.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self] in
                if case .ready = state, let conn {
                    self?.receiveNext(on: conn)
                }
            }
        }
        conn.start(queue: queue)
    }

    private func receiveNext(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, let conn, error == nil else { return }
                if let data, let msg = try? self.decoder.decode(ClientMessage.self, from: data) {
                    self.handle(msg, on: conn)
                }
                self.receiveNext(on: conn)
            }
        }
    }

    private func handle(_ msg: ClientMessage, on conn: NWConnection) {
        switch msg {
        case .hello(_, _, let providedPIN, let providedToken):
            if providedPIN == pin || providedToken == validToken {
                sendText(.welcome(
                    protocolVersion: 1,
                    hostID: "mock-mac-studio",
                    hostName: "Mock Mac Studio",
                    authToken: validToken,
                    snapshot: makeSnapshot()
                ), on: conn)
                sendText(.pushStatus(apnsConfigured: apnsConfigured), on: conn)
                sendSyntheticImage(kind: .previewProxy, requestID: 0, normRect: nil, on: conn)
            } else {
                sendText(.authRequired(hostID: "mock-mac-studio", hostName: "Mock Mac Studio", reason: nil), on: conn)
            }

        case .setViewMode(let mode):
            currentViewMode = mode
            sendText(.snapshot(snapshot: makeSnapshot()), on: conn)
            sendSyntheticImage(kind: mode == .scan ? .scanProxy : .previewProxy, requestID: 0, normRect: nil, on: conn)

        case .trimEmptySpace:
            if currentViewMode == .scan {
                isScanTrimmed = true
            }
            sendText(.snapshot(snapshot: makeSnapshot()), on: conn)

        case .requestTile(let requestID, let rect, _):
            sendSyntheticImage(kind: .highResTile, requestID: requestID, normRect: rect, on: conn)

        case .triggerScan:
            isBusy = true
            activeOperation = .scan
            currentStatusText = "Scanning 1200 DPI…"
            sendText(.snapshot(snapshot: makeSnapshot()), on: conn)
            sendText(.progress(
                operation: .scan,
                bytesReceived: 0,
                expectedBytes: 100 * 1024 * 1024,
                elapsedSeconds: 0,
                statusText: currentStatusText
            ), on: conn)

        case .cancel:
            isBusy = false
            activeOperation = nil
            currentStatusText = "Scan cancelled"
            sendText(.snapshot(snapshot: makeSnapshot()), on: conn)

        case .registerPushToken(let deviceToken, _, let enabled, _):
            lastRegisteredPushToken = deviceToken
            lastPushEnabled = enabled

        default:
            break
        }
    }

    func broadcastProgress(
        operation: CompanionOperation,
        bytesReceived: Int64,
        expectedBytes: Int64,
        elapsedSeconds: Double,
        statusText: String
    ) {
        currentStatusText = statusText
        for conn in connections {
            sendText(.progress(
                operation: operation,
                bytesReceived: bytesReceived,
                expectedBytes: expectedBytes,
                elapsedSeconds: elapsedSeconds,
                statusText: statusText
            ), on: conn)
        }
    }

    func broadcastScanCompleted(
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int64,
        elapsedSeconds: Double
    ) {
        isBusy = false
        activeOperation = nil
        currentViewMode = .scan
        currentStatusText = "Saved \(filename)"
        let snap = makeSnapshot()
        for conn in connections {
            sendText(.snapshot(snapshot: snap), on: conn)
            sendText(.scanCompleted(
                filename: filename,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                fileSizeBytes: fileSizeBytes,
                elapsedSeconds: elapsedSeconds
            ), on: conn)
        }
    }

    private func makeSnapshot() -> SessionSnapshot {
        let scanner = DiscoveredScanner(
            id: "hp-3830",
            name: "HP OfficeJet 3830",
            host: "hp.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "OfficeJet 3830",
            uuid: "hp-3830"
        )
        return SessionSnapshot(
            scanners: [scanner],
            selectedScannerID: scanner.id,
            capabilities: nil,
            scannerStatus: ScannerStatus(state: "Idle", adfState: nil),
            settings: ScanSessionSettings(),
            cropRect: .full,
            viewMode: currentViewMode,
            isBusy: isBusy,
            activeOperation: activeOperation,
            statusText: currentStatusText,
            isErrorStatus: false,
            hasPreviewImage: true,
            hasScanImage: true,
            platenAspectRatio: 2550.0 / 3508.0,
            lastSavedFilename: "scan-001.tiff",
            saveFolderDisplayName: "Pictures",
            outputPreviewSummary: "Live: Display P3 (Accurate)",
            activeImageGeneration: 1,
            scanPixelWidth: isScanTrimmed ? 1600 : 2400,
            scanPixelHeight: isScanTrimmed ? 2100 : 3200,
            scanDPI: 600,
            isScanTrimmed: isScanTrimmed
        )
    }

    private func sendSyntheticImage(kind: CompanionImageKind, requestID: UInt32, normRect: NormalizedCropRect?, on conn: NWConnection) {
        let w = 120, h = 160
        var rawBytes = Data(count: w * h * 3)
        for i in 0..<(w * h) {
            rawBytes[i * 3] = 220
            rawBytes[i * 3 + 1] = 80
            rawBytes[i * 3 + 2] = 60
        }
        let raw = RawImageBuffer(data: rawBytes, width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 600)
        guard let cg = try? ImagePipeline.renderCGImage(from: raw, rotation: .deg0, colorProfile: .displayP3Convert, toneAdjustments: ToneAdjustments()),
              let encoded = ImagePipeline.encodeCompanionImage(cgImage: cg, preferHEIC: true, quality: 0.90, dpi: 600) else {
            return
        }
        let info = CompanionImageReadyInfo(
            kind: kind,
            generation: 1,
            requestID: requestID,
            width: w,
            height: h,
            trueWidth: 2400,
            trueHeight: 3200,
            dpi: 600,
            normalizedRect: normRect,
            summaryText: "Live: Display P3 (Accurate)"
        )
        sendText(.imageReady(info), on: conn)
        let frame = CompanionBinaryFrame(kind: kind.frameKind, generation: 1, requestID: requestID, payload: encoded)
        sendBinary(frame.pack(), on: conn)
    }

    private func sendText(_ msg: HostMessage, on conn: NWConnection) {
        guard let data = try? encoder.encode(msg) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendBinary(_ data: Data, on conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
}

// MARK: - Notification & Background Task Test Doubles

private actor MockScanCompletionNotifier: ScanCompletionNotifying {
    private var status: UNAuthorizationStatus
    private let statusAfterRequest: UNAuthorizationStatus
    private(set) var requestCount = 0
    private(set) var remoteRegisterCount = 0
    private(set) var postedPayloads: [ScanCompletionNotificationPayload] = []

    init(initialStatus: UNAuthorizationStatus, statusAfterRequest: UNAuthorizationStatus) {
        self.status = initialStatus
        self.statusAfterRequest = statusAfterRequest
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        guard status == .notDetermined else { return status }
        requestCount += 1
        status = statusAfterRequest
        return status
    }

    func registerForRemoteNotifications() async {
        remoteRegisterCount += 1
    }

    func postScanCompleted(_ payload: ScanCompletionNotificationPayload) async {
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        postedPayloads.append(payload)
    }
}

@MainActor
private final class MockBackgroundTaskManager: BackgroundTaskManaging {
    private(set) var hasActiveTask = false
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginTask(name: String, onExpiration: @escaping @MainActor () -> Void) {
        guard !hasActiveTask else { return }
        hasActiveTask = true
        beginCount += 1
    }

    func endTask() {
        guard hasActiveTask else { return }
        hasActiveTask = false
        endCount += 1
    }
}
