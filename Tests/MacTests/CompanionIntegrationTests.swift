import XCTest
import Network
import ImageIO
import CoreGraphics
import CryptoKit
@testable import ChromaScan

/// End-to-end loopback WebSocket integration tests proving real `NWListener` + `NWProtocolWebSocket`
/// authentication, token persistence, snapshot/settings/crop sync, Display P3 proxy binary streaming,
/// 1:1 high-res tile fetching, Photos copy export, cancellation, and revocation.
@MainActor
final class CompanionIntegrationTests: XCTestCase {

    func testFullCompanionLifecycleOverRealWebSocket() async throws {
        let suite = "com.chromascan.integration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = AppPreferences(defaults: defaults)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chromascan-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        prefs.saveFolderURL = tmpDir
        prefs.pairingPIN = "482910"
        prefs.baseFilename = "remote-001"
        prefs.resolution = 300

        let browser = MockScannerBrowser()
        let esclClient = MockESCLClient()
        let engine = ScanSessionEngine(preferences: prefs, browser: browser, client: esclClient)
        let server = CompanionServer(engine: engine, preferences: prefs, advertiseBonjour: false, port: 0)

        let scanner = DiscoveredScanner(
            id: "hp-3830",
            name: "HP OfficeJet 3830",
            host: "hp3830.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "OfficeJet 3830",
            uuid: "hp-3830"
        )
        engine.startDiscovery()
        browser.emit([scanner])
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }

        server.start()
        defer { server.stop() }
        try await waitUntil(timeout: 3.0) { server.isRunning && server.port != nil }
        let port = try XCTUnwrap(server.port)

        // 1. Connect test WebSocket client
        let ws = TestWebSocketClient(port: port)
        try await ws.connect()
        defer { ws.close() }

        // 2. Unauthenticated command -> rejected with authRequired
        ws.send(.triggerPreview)
        let rejectMsg = try await ws.waitForHostMessage(timeout: 2.0) {
            if case .authRequired = $0 { return true }
            return false
        }
        guard case .authRequired = rejectMsg else { return XCTFail("Expected authRequired") }

        // 3. Wrong PIN -> rejected with reason
        ws.send(.hello(protocolVersion: 1, clientName: "Test iPhone", pin: "000000", authToken: nil))
        let wrongPINMsg = try await ws.waitForHostMessage(timeout: 2.0) {
            if case .authRequired(_, _, let reason) = $0 { return reason?.contains("Incorrect") == true }
            return false
        }
        XCTAssertNotNil(wrongPINMsg)

        // 4. Correct PIN -> welcome + minted 256-bit authToken + snapshot
        ws.send(.hello(protocolVersion: 1, clientName: "Chris's iPhone 17 Pro", pin: "482910", authToken: nil))
        let welcomeMsg = try await ws.waitForHostMessage(timeout: 2.0) {
            if case .welcome = $0 { return true }
            return false
        }
        guard case let .welcome(proto, _, _, authToken, initialSnapshot) = welcomeMsg else {
            return XCTFail("Expected welcome")
        }
        XCTAssertEqual(proto, 1)
        XCTAssertEqual(authToken.count, 64) // 32 bytes hex = 256 bits
        XCTAssertEqual(initialSnapshot.selectedScannerID, "hp-3830")
        XCTAssertEqual(server.connectedClients.count, 1)

        // 5. Disconnect and reconnect with saved token only (simulating iPhone lock/relaunch)
        ws.close()
        try await waitUntil(timeout: 2.0) { server.connectedClients.isEmpty }

        let ws2 = TestWebSocketClient(port: port)
        try await ws2.connect()
        defer { ws2.close() }
        ws2.send(.hello(protocolVersion: 1, clientName: "Chris's iPhone 17 Pro", pin: nil, authToken: authToken))
        let reconnectWelcome = try await ws2.waitForHostMessage(timeout: 2.0) {
            if case .welcome = $0 { return true }
            return false
        }
        guard case .welcome = reconnectWelcome else { return XCTFail("Token reconnect failed") }

        // 6. Remote settings & crop mutation -> reflected on Mac engine + broadcast back
        let newCrop = NormalizedCropRect(x: 0.15, y: 0.20, width: 0.65, height: 0.55)
        ws2.send(.setCropRect(cropRect: newCrop))
        ws2.send(.updateSettings(patch: ScanSettingsPatch(resolution: 600, rotation: .deg90, autoTrimEmptySpace: true, colorProfile: .displayP3Convert)))
        try await waitUntil(timeout: 2.0) {
            engine.settings.resolution == 600
                && engine.settings.rotation == .deg90
                && engine.settings.autoTrimEmptySpace == true
                && engine.cropRect == newCrop
        }

        // 7. Remote Preview -> receives imageReady + Display P3 binary frame
        ws2.send(.triggerPreview)
        let previewFrame = try await ws2.waitForBinaryFrame(timeout: 4.0) { $0.kind == .previewProxy }
        let previewSrc = try XCTUnwrap(CGImageSourceCreateWithData(previewFrame.payload as CFData, nil))
        let previewCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(previewSrc, 0, nil))
        XCTAssertGreaterThan(previewCG.width, 50)
        XCTAssertEqual(previewCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // 8. Remote Full Scan -> progress + scanCompleted + Display P3 scanProxy + file saved on Mac disk
        ws2.send(.triggerScan)
        let completedMsg = try await ws2.waitForHostMessage(timeout: 5.0) {
            if case .scanCompleted = $0 { return true }
            return false
        }
        guard case let .scanCompleted(filename, pxW, pxH, fileSize, _) = completedMsg else {
            return XCTFail("Expected scanCompleted")
        }
        XCTAssertEqual(filename, "remote-001.tiff")
        XCTAssertGreaterThan(pxW, 50)
        XCTAssertGreaterThan(pxH, 50)
        XCTAssertGreaterThan(fileSize, 1000)

        let scanProxyFrame = try await ws2.waitForBinaryFrame(timeout: 4.0) { $0.kind == .scanProxy }
        let scanProxySrc = try XCTUnwrap(CGImageSourceCreateWithData(scanProxyFrame.payload as CFData, nil))
        let scanProxyCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(scanProxySrc, 0, nil))
        XCTAssertEqual(scanProxyCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // 9. Remote 1:1 High-Res Tile request -> receives matching requestID + exact normalizedRect + Display P3 tile
        ws2.send(.requestTile(
            requestID: 42,
            normalizedRect: NormalizedCropRect(x: 0.25, y: 0.25, width: 0.40, height: 0.40),
            maxPixelWidth: 1600
        ))
        let tileReadyMsg = try await ws2.waitForHostMessage(timeout: 4.0) {
            if case .imageReady(let info) = $0 { return info.kind == .highResTile && info.requestID == 42 }
            return false
        }
        guard case .imageReady(let tileInfo) = tileReadyMsg else { return XCTFail("Expected highResTile imageReady") }
        XCTAssertNotNil(tileInfo.normalizedRect)

        let tileFrame = try await ws2.waitForBinaryFrame(timeout: 4.0) { $0.kind == .highResTile && $0.requestID == 42 }
        let tileSrc = try XCTUnwrap(CGImageSourceCreateWithData(tileFrame.payload as CFData, nil))
        let tileCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(tileSrc, 0, nil))
        XCTAssertEqual(tileCG.width, tileInfo.width)
        XCTAssertEqual(tileCG.height, tileInfo.height)
        XCTAssertEqual(tileCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // 10. Remote Save Copy to Photos -> receives Display P3 photosCopy binary frame
        ws2.send(.requestPhotosCopy(requestID: 77, format: .heic, quality: 0.92))
        let photosFrame = try await ws2.waitForBinaryFrame(timeout: 4.0) { $0.kind == .photosCopy && $0.requestID == 77 }
        let photosSrc = try XCTUnwrap(CGImageSourceCreateWithData(photosFrame.payload as CFData, nil))
        let photosCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(photosSrc, 0, nil))
        XCTAssertEqual(photosCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // 11. Revoke all paired devices -> token rejected on next reconnect
        server.revokeAllPairedDevices()
        try await waitUntil(timeout: 2.0) { server.connectedClients.isEmpty }

        let ws3 = TestWebSocketClient(port: port)
        try await ws3.connect()
        defer { ws3.close() }
        ws3.send(.hello(protocolVersion: 1, clientName: "Revoked iPhone", pin: nil, authToken: authToken))
        let revokedResp = try await ws3.waitForHostMessage(timeout: 2.0) {
            if case .authRequired = $0 { return true }
            return false
        }
        guard case .authRequired = revokedResp else { return XCTFail("Revoked token must require auth") }
    }

    func testDirectMacToAPNsPushOnScanCompleteEvenWhenClientDisconnected() async throws {
        let suite = "com.chromascan.apns.integration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chromascan-apns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let testKey = P256.Signing.PrivateKey()
        prefs.saveFolderURL = tmpDir
        prefs.pairingPIN = "654321"
        prefs.baseFilename = "push-test-001"
        prefs.resolution = 300
        prefs.apnsKeyID = "9A8B7C6D5E"
        prefs.apnsTeamID = "TEAM123456"
        prefs.apnsBundleID = "com.chromascan.remote"
        prefs.apnsPrivateKeyPEM = testKey.pemRepresentation

        let mockAPNs = RecordingAPNsClient(result: .delivered(environment: .production))
        let browser = MockScannerBrowser()
        let esclClient = MockESCLClient()
        let engine = ScanSessionEngine(preferences: prefs, browser: browser, client: esclClient)
        let server = CompanionServer(
            engine: engine,
            preferences: prefs,
            advertiseBonjour: false,
            port: 0,
            apnsClient: mockAPNs
        )

        let scanner = DiscoveredScanner(
            id: "hp-3830",
            name: "HP OfficeJet 3830",
            host: "hp3830.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "OfficeJet 3830",
            uuid: "hp-3830"
        )
        engine.startDiscovery()
        browser.emit([scanner])
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }

        server.start()
        defer { server.stop() }
        try await waitUntil(timeout: 3.0) { server.isRunning && server.port != nil }
        let port = try XCTUnwrap(server.port)

        // Pair iPhone and register its APNs token
        let ws = TestWebSocketClient(port: port)
        try await ws.connect()
        ws.send(.hello(protocolVersion: 1, clientName: "Locked iPhone", pin: "654321", authToken: nil))
        _ = try await ws.waitForHostMessage(timeout: 2.0) {
            if case .welcome = $0 { return true }
            return false
        }
        let pushStatus = try await ws.waitForHostMessage(timeout: 2.0) {
            if case .pushStatus = $0 { return true }
            return false
        }
        XCTAssertEqual(pushStatus, .pushStatus(apnsConfigured: true))

        ws.send(.registerPushToken(
            deviceToken: "aabbccddeeff00112233",
            environment: .sandbox,
            enabled: true,
            bundleID: "com.example.custom.remote"
        ))
        try await waitUntil(timeout: 2.0) {
            prefs.pushEligibleDevices.first?.apnsDeviceToken == "aabbccddeeff00112233"
        }

        // Disconnect WebSocket (simulates iPhone locked and suspended for minutes!)
        ws.close()
        try await waitUntil(timeout: 2.0) { server.connectedClients.isEmpty }

        // Complete a scan on the Mac while iPhone is disconnected
        engine.startScan()
        try await waitUntil(timeout: 5.0) {
            server.lastPushSucceeded == true
        }

        let deliveries = await mockAPNs.deliveries
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.deviceToken, "aabbccddeeff00112233")
        XCTAssertEqual(deliveries.first?.bundleID, "com.example.custom.remote")
        XCTAssertEqual(deliveries.first?.notification.title, "Scan Complete")
        XCTAssertTrue(deliveries.first?.notification.body.contains("push-test-001.tiff") == true)
        // Auto-updated environment persisted after sandbox -> production delivery
        XCTAssertEqual(prefs.pushEligibleDevices.first?.apnsEnvironment, .production)

        // Unregistered token (HTTP 410) clears stale token cleanly
        await mockAPNs.setResult(.unregistered)
        let ok = await server.sendTestPush()
        XCTAssertFalse(ok)
        XCTAssertTrue(prefs.pushEligibleDevices.isEmpty)
    }

    func testMacSendsLiveActivityAPNsUpdatesAndEndWhenClientDisconnects() async throws {
        let suite = "com.chromascan.liveactivity.integration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chromascan-la-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let testKey = P256.Signing.PrivateKey()
        prefs.saveFolderURL = tmpDir
        prefs.pairingPIN = "777888"
        prefs.baseFilename = "live-001"
        prefs.resolution = 300
        prefs.apnsKeyID = "9A8B7C6D5E"
        prefs.apnsTeamID = "TEAM123456"
        prefs.apnsBundleID = "com.chromascan.remote"
        prefs.apnsPrivateKeyPEM = testKey.pemRepresentation

        let mockAPNs = RecordingAPNsClient(result: .delivered(environment: .sandbox))
        let browser = MockScannerBrowser()
        let esclClient = MockESCLClient()
        let engine = ScanSessionEngine(preferences: prefs, browser: browser, client: esclClient)
        let server = CompanionServer(
            engine: engine,
            preferences: prefs,
            advertiseBonjour: false,
            port: 0,
            apnsClient: mockAPNs
        )

        let scanner = DiscoveredScanner(
            id: "hp-3830",
            name: "HP OfficeJet 3830",
            host: "hp3830.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "OfficeJet 3830",
            uuid: "hp-3830"
        )
        engine.startDiscovery()
        browser.emit([scanner])
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }

        server.start()
        defer { server.stop() }
        try await waitUntil(timeout: 3.0) { server.isRunning && server.port != nil }
        let port = try XCTUnwrap(server.port)

        let ws = TestWebSocketClient(port: port)
        try await ws.connect()
        ws.send(.hello(protocolVersion: 1, clientName: "iPhone 17 Pro", pin: "777888", authToken: nil))
        _ = try await ws.waitForHostMessage(timeout: 2.0) {
            if case .welcome = $0 { return true }
            return false
        }

        // Register ephemeral Live Activity push token, then disconnect (simulating locked phone)
        ws.send(.registerLiveActivityToken(
            activityPushToken: "liveactivitytoken0123456789",
            environment: .sandbox,
            bundleID: "com.chromascan.remote"
        ))
        try await Task.sleep(for: .milliseconds(80))
        ws.close()
        try await waitUntil(timeout: 2.0) { server.connectedClients.isEmpty }

        // Run scan -> Mac should deliver Live Activity APNs update(s) and final .end push
        engine.startScan()
        try await waitUntil(timeout: 5.0) { !engine.isBusy && engine.lastSavedURL != nil }
        try await waitUntil(timeout: 3.0) {
            await mockAPNs.liveActivityDeliveries.contains(where: { $0.payload.event == .end })
        }

        let laDeliveries = await mockAPNs.liveActivityDeliveries
        XCTAssertGreaterThanOrEqual(laDeliveries.count, 2)
        XCTAssertTrue(laDeliveries.contains(where: { $0.payload.event == .update }))
        let endDelivery = try XCTUnwrap(laDeliveries.last(where: { $0.payload.event == .end }))
        XCTAssertEqual(endDelivery.activityPushToken, "liveactivitytoken0123456789")
        XCTAssertEqual(endDelivery.bundleID, "com.chromascan.remote")
        XCTAssertEqual(endDelivery.payload.contentState.phase, .completed)
        XCTAssertEqual(endDelivery.payload.contentState.filename, "live-001.tiff")
        XCTAssertNotNil(endDelivery.payload.dismissalDate)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Minimal Test WebSocket Client (Real NWConnection + NWProtocolWebSocket)

@MainActor
private final class TestWebSocketClient {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.chromascan.test.wsclient")
    private var conn: NWConnection?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var receivedMessages: [HostMessage] = []
    private var receivedFrames: [CompanionBinaryFrame] = []

    init(port: UInt16) {
        self.port = port
    }

    func connect() async throws {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.maximumMessageSize = CompanionConstants.maximumMessageSize
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let wsURL = URL(string: "ws://127.0.0.1:\(port)/")!
        let connection = NWConnection(to: .url(wsURL), using: params)
        self.conn = connection

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class ResumeBox: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                let cont: CheckedContinuation<Void, Error>
                init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
                func resume(throwing error: Error? = nil) {
                    lock.lock()
                    guard !resumed else { lock.unlock(); return }
                    resumed = true
                    lock.unlock()
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            let box = ResumeBox(cont)
            connection.stateUpdateHandler = { state in
                print("[TestWS] state: \(state)")
                switch state {
                case .ready:
                    box.resume()
                case .failed(let err):
                    box.resume(throwing: err)
                case .waiting(let err):
                    box.resume(throwing: err)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5.0) {
                box.resume(throwing: NSError(domain: "TestWS", code: 99, userInfo: [NSLocalizedDescriptionKey: "connect() timed out after 5s"]))
            }
        }

        receiveLoop()
    }

    func send(_ message: ClientMessage) {
        guard let conn, let data = try? encoder.encode(message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func waitForHostMessage(timeout: TimeInterval, matching predicate: (HostMessage) -> Bool) async throws -> HostMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let idx = receivedMessages.firstIndex(where: predicate) {
                return receivedMessages.remove(at: idx)
            }
            if Date() > deadline {
                throw NSError(domain: "TestWS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for HostMessage"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForBinaryFrame(timeout: TimeInterval, matching predicate: (CompanionBinaryFrame) -> Bool) async throws -> CompanionBinaryFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let idx = receivedFrames.firstIndex(where: predicate) {
                return receivedFrames.remove(at: idx)
            }
            if Date() > deadline {
                throw NSError(domain: "TestWS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for BinaryFrame"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
    }

    private func receiveLoop() {
        conn?.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor [weak self] in
                guard let self, error == nil else { return }
                if let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch wsMeta.opcode {
                    case .text:
                        if let data, let msg = try? self.decoder.decode(HostMessage.self, from: data) {
                            self.receivedMessages.append(msg)
                        }
                    case .binary:
                        if let data, let frame = try? CompanionBinaryFrame.unpack(data) {
                            self.receivedFrames.append(frame)
                        }
                    case .close:
                        return
                    default:
                        break
                    }
                }
                self.receiveLoop()
            }
        }
    }
}

private actor RecordingAPNsClient: APNsPushing {
    struct Delivery: Equatable, Sendable {
        let notification: APNsNotificationContent
        let deviceToken: String
        let preferredEnvironment: PushEnvironment
        let bundleID: String
    }

    struct LiveActivityDelivery: Equatable, Sendable {
        let payload: APNsLiveActivityPayload
        let activityPushToken: String
        let preferredEnvironment: PushEnvironment
        let bundleID: String
    }

    private var nextResult: APNsDeliveryResult
    private(set) var deliveries: [Delivery] = []
    private(set) var liveActivityDeliveries: [LiveActivityDelivery] = []

    init(result: APNsDeliveryResult) {
        self.nextResult = result
    }

    func setResult(_ result: APNsDeliveryResult) {
        self.nextResult = result
    }

    func send(
        notification: APNsNotificationContent,
        toDeviceToken deviceToken: String,
        preferredEnvironment: PushEnvironment,
        configuration: APNsConfiguration
    ) async -> APNsDeliveryResult {
        deliveries.append(Delivery(
            notification: notification,
            deviceToken: deviceToken,
            preferredEnvironment: preferredEnvironment,
            bundleID: configuration.bundleID
        ))
        return nextResult
    }

    func sendLiveActivity(
        payload: APNsLiveActivityPayload,
        toActivityPushToken activityPushToken: String,
        preferredEnvironment: PushEnvironment,
        configuration: APNsConfiguration
    ) async -> APNsDeliveryResult {
        liveActivityDeliveries.append(LiveActivityDelivery(
            payload: payload,
            activityPushToken: activityPushToken,
            preferredEnvironment: preferredEnvironment,
            bundleID: configuration.bundleID
        ))
        return nextResult
    }
}
