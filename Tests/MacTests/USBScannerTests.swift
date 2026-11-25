import XCTest
@testable import ChromaScan

final class USBScannerTests: XCTestCase {

    // MARK: - USB Configuration Descriptor Parsing

    func testParseHP3830MultiAlternateSettingDescriptor() {
        // Reproduces the exact descriptor structure of the HP OfficeJet 3830 series:
        // IF 0 alt 0 (FF/CC/00), IF 0 alt 1 (07/01/04 EP 0x01/0x82)
        // IF 1 alt 0 (07/01/02), IF 1 alt 1 (07/01/04 EP 0x08/0x89)
        // IF 2 alt 0 (FF/04/01)
        // IF 3 alt 0 (FF/04/01), IF 3 alt 1 (07/01/04 EP 0x0a/0x8b)
        var bytes = Data()
        // Config descriptor header (9 bytes)
        bytes.append(contentsOf: [9, 0x02, 0, 0, 4, 1, 0, 0xC0, 1])

        // IF 0 alt 0 (vendor)
        bytes.append(contentsOf: makeInterfaceDesc(num: 0, alt: 0, numEP: 3, cls: 0xFF, sub: 0xCC, proto: 0x00))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x01, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x82, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x83, attrs: 0x03, mps: 64))

        // IF 0 alt 1 (IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 0, alt: 1, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x04))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x01, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x82, attrs: 0x02, mps: 512))

        // IF 1 alt 0 (legacy bidirectional printer)
        bytes.append(contentsOf: makeInterfaceDesc(num: 1, alt: 0, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x02))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x08, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x89, attrs: 0x02, mps: 512))

        // IF 1 alt 1 (IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 1, alt: 1, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x04))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x08, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x89, attrs: 0x02, mps: 512))

        // IF 2 alt 0 (vendor only, no IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 2, alt: 0, numEP: 2, cls: 0xFF, sub: 0x04, proto: 0x01))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x04, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x85, attrs: 0x02, mps: 512))

        // IF 3 alt 0 (vendor)
        bytes.append(contentsOf: makeInterfaceDesc(num: 3, alt: 0, numEP: 2, cls: 0xFF, sub: 0x04, proto: 0x01))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x0A, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x8B, attrs: 0x02, mps: 512))

        // IF 3 alt 1 (IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 3, alt: 1, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x04))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x0A, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x8B, attrs: 0x02, mps: 512))

        let parsed = USBConfigurationDescriptorParser.parseIPPUSBInterfaces(from: bytes)
        XCTAssertEqual(parsed, [
            IPPUSBInterfaceDescriptor(interfaceNumber: 0, alternateSetting: 1, bulkInAddress: 0x82, bulkOutAddress: 0x01, maxPacketSize: 512),
            IPPUSBInterfaceDescriptor(interfaceNumber: 1, alternateSetting: 1, bulkInAddress: 0x89, bulkOutAddress: 0x08, maxPacketSize: 512),
            IPPUSBInterfaceDescriptor(interfaceNumber: 3, alternateSetting: 1, bulkInAddress: 0x8B, bulkOutAddress: 0x0A, maxPacketSize: 512)
        ])
    }

    func testParseAlt0IPPUSBAndIgnoreNonPrinterDevices() {
        var bytes = Data()
        bytes.append(contentsOf: [9, 0x02, 0, 0, 2, 1, 0, 0xC0, 1])
        bytes.append(contentsOf: makeInterfaceDesc(num: 0, alt: 0, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x04))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x02, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x81, attrs: 0x02, mps: 512))
        // Interrupt endpoint should be ignored
        bytes.append(contentsOf: makeInterfaceDesc(num: 1, alt: 0, numEP: 1, cls: 0x03, sub: 0x00, proto: 0x00))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x84, attrs: 0x03, mps: 64))

        let parsed = USBConfigurationDescriptorParser.parseIPPUSBInterfaces(from: bytes)
        XCTAssertEqual(parsed, [
            IPPUSBInterfaceDescriptor(interfaceNumber: 0, alternateSetting: 0, bulkInAddress: 0x81, bulkOutAddress: 0x02, maxPacketSize: 512)
        ])
    }

    // MARK: - HTTP/1.1 Framing & Chunked Streaming

    func testHTTPFramingRewritesConnectionCloseAndTracksChunkedStream() {
        let req = Data("GET /eSCL/ScannerStatus HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nConnection: keep-alive\r\n\r\n".utf8)
        let rewritten = IPPUSBHTTPFraming.rewriteRequestWithConnectionClose(req)
        let str = String(data: rewritten, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("Host: localhost\r\n"))
        XCTAssertFalse(str.contains("127.0.0.1:54321"))
        XCTAssertTrue(str.contains("Connection: close\r\n"))
        XCTAssertFalse(str.lowercased().contains("keep-alive"))

        let respNoConn = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8)
        let headEnd = IPPUSBHTTPFraming.findHeaderEnd(in: respNoConn)!
        let rewrittenResp = IPPUSBHTTPFraming.rewriteResponseHeadWithConnectionClose(respNoConn, headerEndOffset: headEnd)
        let respStr = String(data: rewrittenResp, encoding: .utf8) ?? ""
        XCTAssertTrue(respStr.contains("Connection: close\r\n"))
        XCTAssertTrue(respStr.hasSuffix("\r\n\r\nOK"))

        let resp204 = Data("HTTP/1.1 204 No Content\r\nServer: HP\r\n\r\n".utf8)
        let head204 = IPPUSBHTTPFraming.parseResponseHead(resp204, requestMethod: "DELETE")
        XCTAssertEqual(head204?.statusCode, 204)
        XCTAssertEqual(head204?.hasNoBody, true)

        // Feed chunked body split across arbitrary byte boundaries
        let chunked = Data("5;ext=1\r\nHello\r\n6\r\n World\r\n0\r\nX-Trailer: ok\r\n\r\n".utf8)
        var tracker = ChunkedTransferTracker()
        for idx in chunked.indices {
            XCTAssertFalse(tracker.isComplete)
            tracker.feed(Data([chunked[idx]]))
        }
        XCTAssertTrue(tracker.isComplete)
        XCTAssertFalse(tracker.isFailed)
    }

    // MARK: - DiscoveredScanner Codable & Display Name

    func testDiscoveredScannerLegacyJSONBackwardCompatibility() throws {
        let legacyJSON = """
        {
          "id": "hp-1",
          "name": "HP OfficeJet 3830",
          "host": "hp.local",
          "port": 8080,
          "useTLS": false,
          "rootPath": "eSCL",
          "modelName": "OfficeJet 3830",
          "uuid": "uuid-1"
        }
        """
        let decoded = try JSONDecoder().decode(DiscoveredScanner.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.transport, .wifi)
        XCTAssertNil(decoded.serialNumber)
        XCTAssertNil(decoded.usbLocationID)
        XCTAssertEqual(decoded.displayTitle, "HP OfficeJet 3830")

        XCTAssertEqual(
            DiscoveredScanner.usbDisplayName(vendor: "HP", product: "OfficeJet 3830 series"),
            "HP OfficeJet 3830 series (USB)"
        )
        XCTAssertEqual(
            DiscoveredScanner.usbDisplayName(vendor: "HP", product: "HP OfficeJet 3830 series"),
            "HP OfficeJet 3830 series (USB)"
        )
    }

    // MARK: - Deduplication (USB vs Wi-Fi vs macOS ippusbd vs Manual)

    func testDeduplicatorPrefersUSBOverWiFiAndMergesIppusbdWithDirectUSB() {
        let ippusbdUSB = DiscoveredScanner(
            id: "usb:CN0178Q2QC074J",
            name: "HP OfficeJet 3830 series (USB)",
            host: "127.0.0.1",
            port: 56824,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "HP OfficeJet 3830 series",
            uuid: "1c852a4d-b800-1f08-abcd-e8d8d11ce486",
            transport: .usb,
            serialNumber: "CN0178Q2QC074J",
            usbLocationID: 17825792
        )
        let directUSB = DiscoveredScanner(
            id: "usb:CN0178Q2QC074J",
            name: "HP OfficeJet 3830 series (USB)",
            host: "127.0.0.1",
            port: 59999,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "HP OfficeJet 3830 series",
            uuid: nil,
            transport: .usb,
            serialNumber: "CN0178Q2QC074J",
            usbLocationID: 17825792
        )
        let wifiHTTP = DiscoveredScanner(
            id: "1c852a4d-b800-1f08-abcd-e8d8d11ce486",
            name: "HP OfficeJet 3830 series [1CE486]",
            host: "HPE8D8D11CE486.local.",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "HP OfficeJet 3830 series",
            uuid: "1c852a4d-b800-1f08-abcd-e8d8d11ce486",
            transport: .wifi
        )
        let wifiHTTPS = DiscoveredScanner(
            id: "1c852a4d-b800-1f08-abcd-e8d8d11ce486",
            name: "HP OfficeJet 3830 series [1CE486]",
            host: "HPE8D8D11CE486.local.",
            port: 443,
            useTLS: true,
            rootPath: "eSCL",
            modelName: "HP OfficeJet 3830 series",
            uuid: "1c852a4d-b800-1f08-abcd-e8d8d11ce486",
            transport: .wifi
        )
        let secondWiFi = DiscoveredScanner(
            id: "canon-uuid-2",
            name: "Canon TR8620 [AABBCC]",
            host: "canon.local.",
            port: 80,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "Canon TR8620",
            uuid: "canon-uuid-2",
            transport: .wifi
        )
        let manual = DiscoveredScanner(
            id: "manual:192.168.1.50:8080:false",
            name: "192.168.1.50 (Manual)",
            host: "192.168.1.50",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: nil,
            uuid: nil,
            transport: .manual
        )

        // Case 1: Both macOS ippusbd USB + direct USB + Wi-Fi HTTP/HTTPS + another Wi-Fi + Manual
        let merged = ScannerDeduplicator.merge(
            bonjourScanners: [wifiHTTPS, wifiHTTP, ippusbdUSB, secondWiFi],
            usbScanners: [directUSB],
            manualScanners: [manual]
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].transport, .usb)
        XCTAssertEqual(merged[0].port, 56824) // macOS ippusbd loopback chosen cleanly
        XCTAssertEqual(merged[1].id, "canon-uuid-2")
        XCTAssertEqual(merged[2].transport, .manual)

        // Case 2: Direct USB ONLY (no macOS ippusbd) + matching Wi-Fi scanner -> direct USB wins via normalized model name!
        let directOnly = ScannerDeduplicator.merge(
            bonjourScanners: [wifiHTTP],
            usbScanners: [directUSB],
            manualScanners: []
        )
        XCTAssertEqual(directOnly.count, 1)
        XCTAssertEqual(directOnly[0].transport, .usb)
        XCTAssertEqual(directOnly[0].port, 59999)

        // Case 3: Two DIFFERENT printers of the same model with distinct UUIDs -> both kept!
        let secondHPWiFi = DiscoveredScanner(
            id: "different-uuid-999",
            name: "HP OfficeJet 3830 series [999999]",
            host: "HP999999.local.",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "HP OfficeJet 3830 series",
            uuid: "different-uuid-999",
            transport: .wifi
        )
        let twoSameModel = ScannerDeduplicator.merge(
            bonjourScanners: [ippusbdUSB, secondHPWiFi],
            usbScanners: [],
            manualScanners: []
        )
        XCTAssertEqual(twoSameModel.count, 2)
    }

    // MARK: - ESCLClient Job Location Resolution Over USB Loopback

    func testResolveJobURLKeepsUSBLoopbackPort() {
        let usbScanner = DiscoveredScanner(
            id: "usb:SN123",
            name: "HP OfficeJet 3830 (USB)",
            host: "127.0.0.1",
            port: 54321,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "HP OfficeJet 3830",
            uuid: nil,
            transport: .usb,
            serialNumber: "SN123"
        )
        // Printer omits ephemeral port in Location header
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "http://localhost/eSCL/ScanJobs/job-1", relativeTo: usbScanner)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/job-1"
        )
        // Printer returns its Wi-Fi IP in Location header while talking over USB
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "http://192.168.1.50:8080/eSCL/ScanJobs/job-2", relativeTo: usbScanner)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/job-2"
        )
        // Relative Location header
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "/eSCL/ScanJobs/job-3", relativeTo: usbScanner)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/job-3"
        )
    }

    // MARK: - End-to-End ESCLClient <-> IPPUSBBridge Loopback Relay

    func testESCLClientFullScanConcurrencyAndIdleReleaseOverIPPUSBBridge() async throws {
        let tracker = MockUSBChannelTracker()
        let bridge = IPPUSBBridge(
            deviceIdentifier: "mock-hp-3830",
            channelCount: 2,
            idleReleaseSeconds: 0.25
        ) { slot in
            tracker.makeChannel(slot: slot)
        }

        let port = try bridge.start()
        defer { bridge.stop() }
        XCTAssertGreaterThan(port, 0)
        // Lazy claim: no USB interfaces opened until first HTTP request arrives
        XCTAssertEqual(bridge.openChannelCount, 0)

        let scanner = DiscoveredScanner(
            id: "usb:MOCK3830",
            name: "Mock HP OfficeJet 3830 (USB)",
            host: "127.0.0.1",
            port: Int(port),
            useTLS: false,
            rootPath: "eSCL",
            modelName: "Mock HP OfficeJet 3830",
            uuid: nil,
            transport: .usb,
            serialNumber: "MOCK3830"
        )
        let client = ESCLClient()

        // 1. Capabilities (Content-Length) + Status (Transfer-Encoding: chunked) concurrently across 2 slots
        async let capsTask = client.fetchCapabilities(from: scanner)
        async let statusTask = client.fetchStatus(from: scanner)
        let (caps, status) = try await (capsTask, statusTask)
        XCTAssertEqual(caps.makeAndModel, "Mock USB OfficeJet 3830")
        XCTAssertEqual(caps.serialNumber, "MOCK3830")
        XCTAssertEqual(status.state, "Idle")

        // 2. Full RAW scan: POST /eSCL/ScanJobs (Location: http://localhost/eSCL/ScanJobs/usb-job-1)
        //    -> GET /NextDocument (chunked RAW RGB24) -> GET /ScanImageInfo
        let req = ScanJobRequest(
            version: "2.5",
            inputSource: .platen,
            resolution: 100,
            colorMode: .rgb24,
            intent: .photo,
            isPreview: false,
            transferFormat: .rawOctetStream,
            region: (0, 0, 192, 120),
            brightness: nil,
            contrast: nil
        )
        let progressBox = ProgressRecorder()
        let result = try await client.performScan(scanner: scanner, request: req) { recv, _ in
            progressBox.record(recv)
        }
        XCTAssertEqual(result.contentType, "application/octet-stream")
        XCTAssertEqual(result.data.count, 64 * 40 * 3)
        XCTAssertEqual(result.imageInfo?.actualWidth, 64)
        XCTAssertEqual(result.imageInfo?.actualHeight, 40)
        XCTAssertEqual(result.jobLocation.absoluteString, "http://127.0.0.1:\(port)/eSCL/ScanJobs/usb-job-1")
        XCTAssertGreaterThan(progressBox.maxBytes, 0)

        // 3. Idle release: wait past idleReleaseSeconds (0.25s) and verify USB interfaces were closed cleanly
        let deadline = Date().addingTimeInterval(2.0)
        while bridge.openChannelCount > 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(bridge.openChannelCount, 0, "Bridge must release USB interfaces when idle for CUPS coexistence")
        XCTAssertGreaterThanOrEqual(tracker.closedCount, 1)
    }

    func testIPPUSBBridgeFailsOverPastBrokenSlotAndDeprioritizesIt() async throws {
        let tracker = MockUSBChannelTracker()
        let bridge = IPPUSBBridge(
            deviceIdentifier: "mock-failover",
            channelCount: 2,
            idleReleaseSeconds: 1.0
        ) { slot in
            if slot == 0 {
                return FailingWriteUSBChannel()
            }
            return tracker.makeChannel(slot: slot)
        }
        let port = try bridge.start()
        defer { bridge.stop() }

        let scanner = DiscoveredScanner(
            id: "usb:FAILOVER",
            name: "Failover Printer (USB)",
            host: "127.0.0.1",
            port: Int(port),
            useTLS: false,
            rootPath: "eSCL",
            modelName: "Failover Printer",
            uuid: nil,
            transport: .usb,
            serialNumber: "FAILOVER"
        )
        let client = ESCLClient()
        let status = try await client.fetchStatus(from: scanner)
        XCTAssertEqual(status.state, "Idle")
    }

    // MARK: - Helpers

    private func makeInterfaceDesc(num: UInt8, alt: UInt8, numEP: UInt8, cls: UInt8, sub: UInt8, proto: UInt8) -> [UInt8] {
        [9, 0x04, num, alt, numEP, cls, sub, proto, 0]
    }

    private func makeEndpointDesc(addr: UInt8, attrs: UInt8, mps: UInt16) -> [UInt8] {
        [7, 0x05, addr, attrs, UInt8(mps & 0xFF), UInt8((mps >> 8) & 0xFF), 0]
    }
}

// MARK: - Mock IPP-USB Channel Transport for Deterministic End-to-End Bridge Tests

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var maxVal: Int64 = 0
    func record(_ v: Int64) {
        lock.lock()
        maxVal = max(maxVal, v)
        lock.unlock()
    }
    var maxBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return maxVal
    }
}

private final class MockUSBChannelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = 0

    var closedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func markClosed() {
        lock.lock()
        closed += 1
        lock.unlock()
    }

    func makeChannel(slot: Int) -> any IPPUSBChannelTransport {
        MockESCLUSBChannel(slot: slot, onClose: { [weak self] in self?.markClosed() })
    }
}

private final class FailingWriteUSBChannel: IPPUSBChannelTransport, @unchecked Sendable {
    func writeAll(_ data: Data, timeout: TimeInterval) throws {
        throw IPPUSBBridgeError.transferFailed("Simulated stalled Bulk OUT pipe")
    }
    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data { Data() }
    func abortAndReset() {}
    func close() {}
}

private final class MockESCLUSBChannel: IPPUSBChannelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let slot: Int
    private let onClose: @Sendable () -> Void
    private var responseChunks: [Data] = []
    private var isClosed = false

    init(slot: Int, onClose: @escaping @Sendable () -> Void) {
        self.slot = slot
        self.onClose = onClose
    }

    func writeAll(_ data: Data, timeout: TimeInterval) throws {
        let reqText = String(data: data, encoding: .utf8) ?? ""
        let firstLine = reqText.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count >= 2 ? String(parts[1]) : "/"

        let fullResponse: Data
        if method == "GET" && path.hasSuffix("/ScannerCapabilities") {
            let body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.5</pwg:Version>
              <pwg:MakeAndModel>Mock USB OfficeJet 3830</pwg:MakeAndModel>
              <pwg:SerialNumber>MOCK3830</pwg:SerialNumber>
              <scan:Platen>
                <scan:PlatenInputCaps>
                  <scan:MinWidth>8</scan:MinWidth><scan:MaxWidth>2550</scan:MaxWidth>
                  <scan:MinHeight>8</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>
                  <scan:SettingProfiles><scan:SettingProfile>
                    <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
                    <scan:DocumentFormats><pwg:DocumentFormat>application/octet-stream</pwg:DocumentFormat></scan:DocumentFormats>
                    <scan:SupportedResolutions><scan:DiscreteResolutions>
                      <scan:DiscreteResolution><scan:XResolution>100</scan:XResolution><scan:YResolution>100</scan:YResolution></scan:DiscreteResolution>
                    </scan:DiscreteResolutions></scan:SupportedResolutions>
                  </scan:SettingProfile></scan:SettingProfiles>
                </scan:PlatenInputCaps>
              </scan:Platen>
            </scan:ScannerCapabilities>
            """
            let bodyData = Data(body.utf8)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8)
            resp.append(bodyData)
            fullResponse = resp
        } else if method == "GET" && path.hasSuffix("/ScannerStatus") {
            // Return chunked encoding to exercise ChunkedTransferTracker end-to-end!
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.5</pwg:Version>
              <pwg:State>Idle</pwg:State>
            </scan:ScannerStatus>
            """
            let xmlData = Data(xml.utf8)
            let mid = xmlData.count / 2
            let p1 = xmlData.prefix(mid)
            let p2 = xmlData.dropFirst(mid)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
            resp.append(Data("\(String(p1.count, radix: 16))\r\n".utf8))
            resp.append(p1)
            resp.append(Data("\r\n\(String(p2.count, radix: 16))\r\n".utf8))
            resp.append(p2)
            resp.append(Data("\r\n0\r\n\r\n".utf8))
            fullResponse = resp
        } else if method == "POST" && path.hasSuffix("/ScanJobs") {
            // Deliberately emit http://localhost/eSCL/ScanJobs/usb-job-1 (missing ephemeral port!)
            // just like real HP IPP-USB printers do, to prove ESCLClient rewrites it onto the USB port.
            fullResponse = Data("HTTP/1.1 201 Created\r\nLocation: http://localhost/eSCL/ScanJobs/usb-job-1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        } else if method == "GET" && path.hasSuffix("/NextDocument") {
            let raw = Data(repeating: 0xAB, count: 64 * 40 * 3)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
            // Stream in 1024-byte chunks
            var off = 0
            while off < raw.count {
                let end = min(raw.count, off + 1024)
                let slice = raw[off..<end]
                resp.append(Data("\(String(slice.count, radix: 16))\r\n".utf8))
                resp.append(slice)
                resp.append(Data("\r\n".utf8))
                off = end
            }
            resp.append(Data("0\r\n\r\n".utf8))
            fullResponse = resp
        } else if method == "GET" && path.hasSuffix("/ScanImageInfo") {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScanImageInfo xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:JobUuid>usb-job-1</pwg:JobUuid>
              <scan:ActualWidth>64</scan:ActualWidth>
              <scan:ActualHeight>40</scan:ActualHeight>
              <scan:ActualBytesPerLine>192</scan:ActualBytesPerLine>
            </scan:ScanImageInfo>
            """
            let bodyData = Data(xml.utf8)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8)
            resp.append(bodyData)
            fullResponse = resp
        } else {
            fullResponse = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }

        // Slice into small USB-like 512-byte bulk packets
        var packets: [Data] = []
        var pos = 0
        while pos < fullResponse.count {
            let end = min(fullResponse.count, pos + 512)
            packets.append(Data(fullResponse[pos..<end]))
            pos = end
        }
        lock.lock()
        responseChunks = packets
        lock.unlock()
    }

    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if responseChunks.isEmpty { return Data() }
        return responseChunks.removeFirst()
    }

    func abortAndReset() {
        lock.lock()
        responseChunks.removeAll()
        lock.unlock()
    }

    func close() {
        lock.lock()
        let shouldNotify = !isClosed
        isClosed = true
        responseChunks.removeAll()
        lock.unlock()
        if shouldNotify {
            onClose()
        }
    }
}
