import XCTest
import Network
import UIKit
import CoreGraphics
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

        // 3. Switch to scan mode & request 1:1 high-res tile -> tileImage decoded with Display P3 ICC profile
        store.setViewMode(.scan)
        try await waitUntil(timeout: 2.0) { store.snapshot?.viewMode == .scan }

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

    init(pin: String) throws {
        self.pin = pin
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
                sendSyntheticImage(kind: .previewProxy, requestID: 0, normRect: nil, on: conn)
            } else {
                sendText(.authRequired(hostID: "mock-mac-studio", hostName: "Mock Mac Studio", reason: nil), on: conn)
            }

        case .setViewMode(let mode):
            currentViewMode = mode
            sendText(.snapshot(snapshot: makeSnapshot()), on: conn)
            sendSyntheticImage(kind: mode == .scan ? .scanProxy : .previewProxy, requestID: 0, normRect: nil, on: conn)

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
            scanPixelWidth: 2400,
            scanPixelHeight: 3200,
            scanDPI: 600
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
