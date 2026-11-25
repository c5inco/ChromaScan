import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
@testable import ChromaScan

final class CompanionProtocolTests: XCTestCase {

    func testClientMessageFlatJSONRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(protocolVersion: 1, clientName: "Chris's iPhone", pin: "482910", authToken: nil),
            .hello(protocolVersion: 1, clientName: "Chris's iPhone", pin: nil, authToken: "deadbeef"),
            .selectScanner(scannerID: "hp-3830"),
            .refreshScanners,
            .addManualScanner(host: "192.168.1.50", port: 8080, useTLS: false),
            .updateSettings(patch: ScanSettingsPatch(
                resolution: 1200,
                rotation: .deg90,
                autoTrimEmptySpace: true,
                colorProfile: .displayP3Convert,
                outputFormat: .heic,
                quality: 0.90,
                toneAdjustments: ToneAdjustments(blackPoint: 0.05, whitePoint: 0.95, gamma: 1.1)
            )),
            .setCropRect(cropRect: NormalizedCropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)),
            .trimEmptySpace,
            .setViewMode(mode: .scan),
            .triggerPreview,
            .triggerScan,
            .triggerExport,
            .cancel,
            .requestTile(
                requestID: 42,
                normalizedRect: NormalizedCropRect(x: 0.35, y: 0.40, width: 0.15, height: 0.20),
                maxPixelWidth: 1600
            ),
            .requestPhotosCopy(requestID: 7, format: .heic, quality: 0.92),
            .registerPushToken(deviceToken: "aabbccddeeff00112233", environment: .sandbox, enabled: true, bundleID: "com.alice.chromascan.remote"),
            .registerPushToken(deviceToken: nil, environment: .production, enabled: false, bundleID: nil),
            .registerLiveActivityToken(activityPushToken: "ff00112233445566", environment: .sandbox, bundleID: "com.chromascan.remote"),
            .registerLiveActivityToken(activityPushToken: nil, environment: .production, bundleID: nil),
            .ping
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for msg in messages {
            let data = try encoder.encode(msg)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(obj["type"] as? String, "Wire JSON must have top-level 'type' discriminator")
            let decoded = try decoder.decode(ClientMessage.self, from: data)
            XCTAssertEqual(decoded, msg)
        }
    }

    func testHostMessageFlatJSONRoundTrip() throws {
        let scanner = DiscoveredScanner(
            id: "hp-1",
            name: "HP OfficeJet 3830",
            host: "hp.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "OfficeJet 3830",
            uuid: "uuid-1"
        )
        let snapshot = SessionSnapshot(
            scanners: [scanner],
            selectedScannerID: scanner.id,
            capabilities: nil,
            scannerStatus: ScannerStatus(state: "Idle", adfState: nil),
            settings: ScanSessionSettings(),
            cropRect: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7),
            viewMode: .preview,
            isBusy: false,
            activeOperation: nil,
            statusText: "Ready",
            isErrorStatus: false,
            hasPreviewImage: true,
            hasScanImage: false,
            platenAspectRatio: 2550.0 / 3508.0,
            lastSavedFilename: "scan-001.tiff",
            saveFolderDisplayName: "Pictures",
            outputPreviewSummary: "Live: Display P3 (Accurate)",
            activeImageGeneration: 3,
            scanPixelWidth: nil,
            scanPixelHeight: nil,
            scanDPI: nil,
            isScanTrimmed: false
        )

        let info = CompanionImageReadyInfo(
            kind: .highResTile,
            generation: 7,
            requestID: 42,
            width: 1200,
            height: 900,
            trueWidth: 10200,
            trueHeight: 13200,
            dpi: 1200,
            normalizedRect: NormalizedCropRect(x: 0.25, y: 0.30, width: 0.20, height: 0.15),
            summaryText: "Live: Display P3 (Accurate)"
        )

        let messages: [HostMessage] = [
            .welcome(protocolVersion: 1, hostID: "host-1", hostName: "Mac Studio", authToken: "abc123", snapshot: snapshot),
            .authRequired(hostID: "host-1", hostName: "Mac Studio", reason: "Incorrect pairing PIN."),
            .snapshot(snapshot: snapshot),
            .progress(operation: .scan, bytesReceived: 184_549_376, expectedBytes: 423_624_704, elapsedSeconds: 72.4, statusText: "Scanning 1200 DPI"),
            .imageReady(info),
            .scanCompleted(filename: "scan-004.tiff", pixelWidth: 10200, pixelHeight: 13200, fileSizeBytes: 214_958_080, elapsedSeconds: 168.2),
            .exportCompleted(filename: "scan-005.heic", fileSizeBytes: 4_200_000, elapsedSeconds: 0.45),
            .pushStatus(apnsConfigured: true),
            .error(title: "Scan Failed", message: "HTTP 409 Conflict"),
            .pong
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for msg in messages {
            let data = try encoder.encode(msg)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(obj["type"] as? String)
            let decoded = try decoder.decode(HostMessage.self, from: data)
            XCTAssertEqual(decoded, msg)
        }
    }

    func testBinaryFramePackUnpackAndBigEndianHeader() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])
        let frame = CompanionBinaryFrame(
            kind: .highResTile,
            generation: 0x01020304,
            requestID: 0x0A0B0C0D,
            payload: payload
        )
        let packed = frame.pack()
        XCTAssertEqual(packed.count, 9 + payload.count)
        XCTAssertEqual(packed[0], CompanionFrameKind.highResTile.rawValue)
        XCTAssertEqual(Array(packed[1...4]), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(Array(packed[5...8]), [0x0A, 0x0B, 0x0C, 0x0D])

        let unpacked = try CompanionBinaryFrame.unpack(packed)
        XCTAssertEqual(unpacked, frame)

        // Error cases
        XCTAssertThrowsError(try CompanionBinaryFrame.unpack(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? CompanionBinaryFrameError, .truncatedHeader(3))
        }
        XCTAssertThrowsError(try CompanionBinaryFrame.unpack(Data([99, 0, 0, 0, 1, 0, 0, 0, 0, 0xFF]))) { error in
            XCTAssertEqual(error as? CompanionBinaryFrameError, .unknownFrameKind(99))
        }
        XCTAssertThrowsError(try CompanionBinaryFrame.unpack(Data([1, 0, 0, 0, 1, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? CompanionBinaryFrameError, .emptyPayload)
        }
    }

    func testNormalizedCropRectRotationParityAcrossAll4Rotations() {
        let original = NormalizedCropRect(x: 0.12, y: 0.25, width: 0.42, height: 0.31)
        for rotation in ScanRotation.allCases {
            let displayRect = original.physicalToDisplay(rotation: rotation)
            let roundTrip = NormalizedCropRect.fromDisplayRect(displayRect, rotation: rotation)
            XCTAssertEqual(roundTrip.x, original.x, accuracy: 0.0001, "Failed x for \(rotation)")
            XCTAssertEqual(roundTrip.y, original.y, accuracy: 0.0001, "Failed y for \(rotation)")
            XCTAssertEqual(roundTrip.width, original.width, accuracy: 0.0001, "Failed width for \(rotation)")
            XCTAssertEqual(roundTrip.height, original.height, accuracy: 0.0001, "Failed height for \(rotation)")
        }
    }

    func testCompanionImageAndTileEncodingPreservesDisplayP3() throws {
        let w = 400, h = 300
        var bytes = Data(count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let off = (y * w + x) * 3
                bytes[off] = UInt8((x * 255) / w)
                bytes[off + 1] = UInt8((y * 255) / h)
                bytes[off + 2] = 200
            }
        }
        let raw = RawImageBuffer(data: bytes, width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 1200)
        let cg = try ImagePipeline.renderCGImage(
            from: raw,
            rotation: .deg0,
            colorProfile: .displayP3Convert,
            toneAdjustments: ToneAdjustments()
        )

        let encodedProxy = try XCTUnwrap(ImagePipeline.encodeCompanionImage(cgImage: cg, preferHEIC: true, quality: 0.88, dpi: 1200))
        XCTAssertGreaterThan(encodedProxy.count, 500)
        let proxySrc = try XCTUnwrap(CGImageSourceCreateWithData(encodedProxy as CFData, nil))
        let decodedProxy = try XCTUnwrap(CGImageSourceCreateImageAtIndex(proxySrc, 0, nil))
        XCTAssertEqual(decodedProxy.width, w)
        XCTAssertEqual(decodedProxy.height, h)
        XCTAssertEqual(decodedProxy.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        let tile = try XCTUnwrap(ImagePipeline.cropAndEncodeTile(
            from: cg,
            normalizedRect: NormalizedCropRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50),
            maxPixelWidth: 1600,
            simulateFormat: nil,
            simulateQuality: 0.90
        ))
        XCTAssertEqual(tile.width, 200)
        XCTAssertEqual(tile.height, 150)
        XCTAssertEqual(tile.exactNormalizedRect.x, 0.25, accuracy: 0.01)
        XCTAssertEqual(tile.exactNormalizedRect.width, 0.50, accuracy: 0.01)

        let tileSrc = try XCTUnwrap(CGImageSourceCreateWithData(tile.data as CFData, nil))
        let decodedTile = try XCTUnwrap(CGImageSourceCreateImageAtIndex(tileSrc, 0, nil))
        XCTAssertEqual(decodedTile.width, 200)
        XCTAssertEqual(decodedTile.height, 150)
        XCTAssertEqual(decodedTile.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
    }

    func testAPNsJWTGenerationAndSignatureVerification() throws {
        XCTAssertEqual(APNsConfiguration.extractKeyID(fromFilename: "AuthKey_9A8B7C6D5E.p8"), "9A8B7C6D5E")
        XCTAssertNil(APNsConfiguration.extractKeyID(fromFilename: "random.p8"))

        let key = P256.Signing.PrivateKey()
        let config = APNsConfiguration(
            keyID: "9A8B7C6D5E",
            teamID: "FXB7YX3ZD4",
            bundleID: "com.chromascan.remote",
            privateKeyPEM: key.pemRepresentation
        )
        let issuedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let jwt = try APNsJWTGenerator.generateToken(configuration: config, issuedAt: issuedAt)

        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)

        func base64URLDecode(_ s: Substring) throws -> Data {
            var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while str.count % 4 != 0 { str.append("=") }
            return try XCTUnwrap(Data(base64Encoded: str))
        }

        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: try base64URLDecode(parts[0])) as? [String: Any])
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "9A8B7C6D5E")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try base64URLDecode(parts[1])) as? [String: Any])
        XCTAssertEqual(payload["iss"] as? String, "FXB7YX3ZD4")
        XCTAssertEqual(payload["iat"] as? Int, 1_750_000_000)

        let rawSig = try base64URLDecode(parts[2])
        XCTAssertEqual(rawSig.count, 64)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: rawSig)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: signingInput))
    }

    func testAPNsClientFallbackOnBadDeviceTokenAndUnregisteredHandling() async throws {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfiguration(
            keyID: "9A8B7C6D5E",
            teamID: "FXB7YX3ZD4",
            bundleID: "com.chromascan.remote",
            privateKeyPEM: key.pemRepresentation
        )

        let transport = MockAPNsHTTPTransport { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.chromascan.remote")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
            XCTAssertTrue(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)

            if url.host == "api.sandbox.push.apple.com" {
                let resp = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "2.0", headerFields: nil)!
                return (Data(#"{"reason":"BadDeviceToken"}"#.utf8), resp)
            } else {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: nil)!
                return (Data(), resp)
            }
        }

        let client = APNsClient(transport: transport)
        let content = APNsNotificationContent.scanCompleted(
            filename: "art-001.tiff",
            pixelWidth: 4800,
            pixelHeight: 6400,
            fileSizeBytes: 52_428_800,
            elapsedSeconds: 95
        )
        let result = await client.send(
            notification: content,
            toDeviceToken: "deadbeef00112233",
            preferredEnvironment: .sandbox,
            configuration: config
        )
        XCTAssertEqual(result, .delivered(environment: .production))
        let requestedHosts = await transport.recordedHosts
        XCTAssertEqual(requestedHosts, ["api.sandbox.push.apple.com", "api.push.apple.com"])

        // 410 Unregistered handling
        let unregTransport = MockAPNsHTTPTransport { request in
            let url = try XCTUnwrap(request.url)
            let resp = HTTPURLResponse(url: url, statusCode: 410, httpVersion: "2.0", headerFields: nil)!
            return (Data(#"{"reason":"Unregistered"}"#.utf8), resp)
        }
        let unregClient = APNsClient(transport: unregTransport)
        let unregResult = await unregClient.send(
            notification: content,
            toDeviceToken: "stale0011",
            preferredEnvironment: .production,
            configuration: config
        )
        XCTAssertEqual(unregResult, .unregistered)
    }

    func testAPNsClientLiveActivityPushHeadersPayloadAndFallback() async throws {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfiguration(
            keyID: "9A8B7C6D5E",
            teamID: "FXB7YX3ZD4",
            bundleID: "com.chromascan.remote",
            privateKeyPEM: key.pemRepresentation
        )

        let transport = MockAPNsHTTPTransport { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.chromascan.remote.push-type.liveactivity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "liveactivity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")

            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let aps = try XCTUnwrap(json["aps"] as? [String: Any])
            XCTAssertEqual(aps["event"] as? String, "end")
            XCTAssertEqual(aps["timestamp"] as? Int, 1_750_000_100)
            XCTAssertEqual(aps["dismissal-date"] as? Int, 1_750_000_115)
            let contentState = try XCTUnwrap(aps["content-state"] as? [String: Any])
            XCTAssertEqual(contentState["phase"] as? String, "completed")
            XCTAssertEqual(contentState["filename"] as? String, "art-001.tiff")

            if url.host == "api.sandbox.push.apple.com" {
                let resp = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "2.0", headerFields: nil)!
                return (Data(#"{"reason":"BadDeviceToken"}"#.utf8), resp)
            } else {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: nil)!
                return (Data(), resp)
            }
        }

        let client = APNsClient(transport: transport)
        let payload = APNsLiveActivityPayload(
            event: .end,
            contentState: ScanLiveActivityContentState.completed(
                filename: "art-001.tiff",
                pixelWidth: 4800,
                pixelHeight: 6400,
                fileSizeBytes: 52_428_800
            ),
            timestamp: 1_750_000_100,
            dismissalDate: 1_750_000_115
        )
        let result = await client.sendLiveActivity(
            payload: payload,
            toActivityPushToken: "la001122334455",
            preferredEnvironment: .sandbox,
            configuration: config
        )
        XCTAssertEqual(result, .delivered(environment: .production))
        let requestedHosts = await transport.recordedHosts
        XCTAssertEqual(requestedHosts, ["api.sandbox.push.apple.com", "api.push.apple.com"])
    }

    @MainActor
    func testLocalAPNSDirectoryAutoDiscovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromascan-apns-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = P256.Signing.PrivateKey()
        try key.pemRepresentation.write(
            to: dir.appendingPathComponent("AuthKey_9A8B7C6D5E.p8"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # Local APNs config
        export APNS_TEAM_ID="TEAM123456"
        """.write(
            to: dir.appendingPathComponent("apns.env"),
            atomically: true,
            encoding: .utf8
        )

        let suite = "com.chromascan.localapns.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AppPreferences(defaults: defaults, apnsDirectoryURL: dir)
        XCTAssertTrue(prefs.isAPNsConfigured)
        XCTAssertTrue(prefs.isUsingLocalAPNsDirectoryKey)
        let config = try XCTUnwrap(prefs.apnsConfiguration)
        XCTAssertEqual(config.keyID, "9A8B7C6D5E")
        XCTAssertEqual(config.teamID, "TEAM123456")
        XCTAssertEqual(config.bundleID, "com.chromascan.remote")
    }
}

private actor MockAPNsHTTPTransport: APNsHTTPTransport {
    private let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    private(set) var recordedHosts: [String] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let host = request.url?.host {
            recordedHosts.append(host)
        }
        return try handler(request)
    }
}
