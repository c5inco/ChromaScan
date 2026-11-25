import XCTest
import dnssd
@testable import ChromaScan

final class USBScannerTests: XCTestCase {

    // MARK: - USB Configuration Descriptor Parsing

    func testParseHP3830MultiAlternateSettingDescriptor() {
        var bytes = Data()
        bytes.append(contentsOf: [9, 0x02, 0, 0, 4, 1, 0, 0xC0, 1])

        // IF 0 alt 0 (vendor) + alt 1 (IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 0, alt: 0, numEP: 3, cls: 0xFF, sub: 0xCC, proto: 0x00))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x01, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x82, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x83, attrs: 0x03, mps: 64))
        bytes.append(contentsOf: makeInterfaceDesc(num: 0, alt: 1, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x04))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x01, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x82, attrs: 0x02, mps: 512))

        // IF 1 alt 0 (legacy bidirectional printer) + alt 1 (IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 1, alt: 0, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x02))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x08, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x89, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeInterfaceDesc(num: 1, alt: 1, numEP: 2, cls: 0x07, sub: 0x01, proto: 0x04))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x08, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x89, attrs: 0x02, mps: 512))

        // IF 2 alt 0 (vendor only)
        bytes.append(contentsOf: makeInterfaceDesc(num: 2, alt: 0, numEP: 2, cls: 0xFF, sub: 0x04, proto: 0x01))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x04, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x85, attrs: 0x02, mps: 512))

        // IF 3 alt 0 (vendor) + alt 1 (IPP-USB)
        bytes.append(contentsOf: makeInterfaceDesc(num: 3, alt: 0, numEP: 2, cls: 0xFF, sub: 0x04, proto: 0x01))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x0A, attrs: 0x02, mps: 512))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x8B, attrs: 0x02, mps: 512))
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
        bytes.append(contentsOf: makeInterfaceDesc(num: 1, alt: 0, numEP: 1, cls: 0x03, sub: 0x00, proto: 0x00))
        bytes.append(contentsOf: makeEndpointDesc(addr: 0x84, attrs: 0x03, mps: 64))

        let parsed = USBConfigurationDescriptorParser.parseIPPUSBInterfaces(from: bytes)
        XCTAssertEqual(parsed, [
            IPPUSBInterfaceDescriptor(interfaceNumber: 0, alternateSetting: 0, bulkInAddress: 0x81, bulkOutAddress: 0x02, maxPacketSize: 512)
        ])
    }

    // MARK: - HTTP/1.1 Framing, Validation & Chunked Streaming

    func testHTTPFramingRewritesHostExpectConnectionCloseAndRejectsMalformed() {
        let req = Data("POST /eSCL/ScanJobs HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nExpect: 100-continue\r\nConnection: keep-alive\r\nContent-Length: 4\r\n\r\nBODY".utf8)
        let parsedReq = IPPUSBHTTPFraming.parseRequestHead(req)
        XCTAssertEqual(parsedReq?.expectsContinue, true)
        XCTAssertEqual(parsedReq?.contentLength, 4)

        let rewritten = IPPUSBHTTPFraming.rewriteRequestWithConnectionClose(req)
        let str = String(data: rewritten, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("Host: localhost\r\n"))
        XCTAssertFalse(str.contains("127.0.0.1:54321"))
        XCTAssertFalse(str.lowercased().contains("expect:"))
        XCTAssertTrue(str.contains("Connection: close\r\n"))
        XCTAssertFalse(str.lowercased().contains("keep-alive"))
        XCTAssertTrue(str.hasSuffix("\r\n\r\nBODY"))

        // Conflicting Content-Length + Transfer-Encoding must be rejected
        let conflictingReq = Data("POST /eSCL/ScanJobs HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 10\r\n\r\n".utf8)
        XCTAssertEqual(IPPUSBHTTPFraming.parseRequestHeadStrict(conflictingReq), .invalid)

        // Binary garbage before \r\n\r\n must NOT be misparsed as HTTP 200
        let garbageResp = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x0D, 0x0A, 0x0D, 0x0A])
        XCTAssertEqual(IPPUSBHTTPFraming.parseResponseHeadStrict(garbageResp, requestMethod: "GET"), .invalid)

        // Interim 100 Continue is recognized as isInterim == true
        let resp100 = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        let head100 = IPPUSBHTTPFraming.parseResponseHead(resp100, requestMethod: "POST")
        XCTAssertEqual(head100?.statusCode, 100)
        XCTAssertEqual(head100?.isInterim, true)

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

        // Chunked body across byte boundaries + trailing garbage not consumed
        let chunked = Data("5;ext=1\r\nHello\r\n6\r\n World\r\n0\r\nX-Trailer: ok\r\n\r\nEXTRA".utf8)
        var tracker = ChunkedTransferTracker()
        var totalConsumed = 0
        for idx in chunked.indices {
            totalConsumed += tracker.feed(Data([chunked[idx]]))
        }
        XCTAssertTrue(tracker.isComplete)
        XCTAssertFalse(tracker.isFailed)
        XCTAssertEqual(totalConsumed, chunked.count - 5) // "EXTRA" excluded!

        // Invalid chunk terminator (not CRLF) must fail strictly
        let badChunk = Data("5\r\nHelloXX0\r\n\r\n".utf8)
        var badTracker = ChunkedTransferTracker()
        badTracker.feed(badChunk)
        XCTAssertTrue(badTracker.isFailed)
    }

    // MARK: - DiscoveredScanner Bidirectional Codable Compatibility

    func testDiscoveredScannerBidirectionalCodableCompatibility() throws {
        // 1. New code decoding legacy JSON without transport/serialNumber/usbLocationID
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

        // 2. Legacy iOS client struct decoding new host DiscoveredScanner JSON with USB fields
        struct LegacyClientScanner: Decodable {
            let id: String
            let name: String
            let host: String
            let port: Int
            let useTLS: Bool
            let rootPath: String
            let modelName: String?
            let uuid: String?
        }
        let newUSBScanner = DiscoveredScanner(
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
        let encoded = try JSONEncoder().encode(newUSBScanner)
        let decodedByOldIOS = try JSONDecoder().decode(LegacyClientScanner.self, from: encoded)
        XCTAssertEqual(decodedByOldIOS.id, "usb:CN0178Q2QC074J")
        XCTAssertEqual(decodedByOldIOS.name, "HP OfficeJet 3830 series (USB)")

        XCTAssertEqual(
            DiscoveredScanner.usbDisplayName(vendor: "HP", product: "OfficeJet 3830 series"),
            "HP OfficeJet 3830 series (USB)"
        )
        XCTAssertEqual(
            DiscoveredScanner.usbDisplayName(vendor: "HP", product: "HP OfficeJet 3830 series"),
            "HP OfficeJet 3830 series (USB)"
        )
    }

    // MARK: - Bonjour Classification & Deduplication

    func testBonjourEndpointClassificationPreservesTLSAndDoesNotDowngradeNetworkTXT() {
        // 1. LocalOnly _uscan._tcp -> loopback 127.0.0.1 HTTP USB even if hosttarget is Mac.local.
        let localHTTP = BonjourScannerBrowser.makeDiscoveredScanner(
            serviceName: "HP OfficeJet 3830 series [1CE486]",
            host: "MacStudio.local.",
            port: 56824,
            interfaceIndex: kDNSServiceInterfaceIndexLocalOnly,
            useTLS: false,
            txt: ["usb_sn": "CN0178Q2QC074J", "usb_loc": "17825792", "ty": "HP OfficeJet 3830 series", "rs": "eSCL"]
        )
        XCTAssertEqual(localHTTP.transport, .usb)
        XCTAssertEqual(localHTTP.host, "127.0.0.1")
        XCTAssertEqual(localHTTP.useTLS, false)
        XCTAssertEqual(localHTTP.serialNumber, "CN0178Q2QC074J")

        // 2. LocalOnly _uscans._tcp -> preserves useTLS == true
        let localHTTPS = BonjourScannerBrowser.makeDiscoveredScanner(
            serviceName: "HP OfficeJet 3830 series [1CE486]",
            host: "localhost.",
            port: 56825,
            interfaceIndex: kDNSServiceInterfaceIndexLocalOnly,
            useTLS: true,
            txt: ["usb_sn": "CN0178Q2QC074J", "ty": "HP OfficeJet 3830 series"]
        )
        XCTAssertEqual(localHTTPS.transport, .usb)
        XCTAssertEqual(localHTTPS.useTLS, true)

        // 3. Network interface _uscans._tcp carrying usb_sn TXT must stay Wi-Fi HTTPS (never downgraded!)
        let networkWithUSBTXT = BonjourScannerBrowser.makeDiscoveredScanner(
            serviceName: "HP OfficeJet 3830 series [1CE486]",
            host: "HPE8D8D11CE486.local.",
            port: 443,
            interfaceIndex: 8,
            useTLS: true,
            txt: ["usb_sn": "CN0178Q2QC074J", "ty": "HP OfficeJet 3830 series"]
        )
        XCTAssertEqual(networkWithUSBTXT.transport, .wifi)
        XCTAssertEqual(networkWithUSBTXT.useTLS, true)
        XCTAssertEqual(networkWithUSBTXT.host, "HPE8D8D11CE486.local.")
    }

    func testDeduplicatorPrefersUSBOverWiFiAndPreservesAmbiguousSameModelPrinters() {
        let ippusbdHTTP = DiscoveredScanner(
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
        let ippusbdHTTPS = DiscoveredScanner(
            id: "usb:CN0178Q2QC074J",
            name: "HP OfficeJet 3830 series (USB)",
            host: "127.0.0.1",
            port: 56825,
            useTLS: true,
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
        let secondSameModelWiFi = DiscoveredScanner(
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

        // Case 1: Deterministically prefers plain HTTP Bonjour USB over HTTPS Bonjour USB regardless of order
        let merged = ScannerDeduplicator.merge(
            bonjourScanners: [ippusbdHTTPS, ippusbdHTTP, wifiHTTP],
            usbScanners: [directUSB],
            manualScanners: [manual]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].transport, .usb)
        XCTAssertEqual(merged[0].useTLS, false)
        XCTAssertEqual(merged[0].port, 56824)
        XCTAssertEqual(merged[1].transport, .manual)

        // Case 2: Unambiguous 1 direct USB + 1 Wi-Fi of same model -> direct USB wins
        let unambiguous = ScannerDeduplicator.merge(
            bonjourScanners: [wifiHTTP],
            usbScanners: [directUSB],
            manualScanners: []
        )
        XCTAssertEqual(unambiguous.count, 1)
        XCTAssertEqual(unambiguous[0].transport, .usb)

        // Case 3: Ambiguous 1 UUID-less direct USB + 2 Wi-Fi printers of same model -> keeps all 3 distinct!
        let ambiguous = ScannerDeduplicator.merge(
            bonjourScanners: [wifiHTTP, secondSameModelWiFi],
            usbScanners: [directUSB],
            manualScanners: []
        )
        XCTAssertEqual(ambiguous.count, 3)
    }

    // MARK: - ESCLClient Job Location Resolution (Relative, Query, Escaped %2F, Loopback)

    func testResolveJobURLPreservesRelativeQueryPercentEncodingAndUSBLoopbackAuthority() {
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
        let postURL = usbScanner.baseURL.appendingPathComponent("ScanJobs")

        // Absolute missing ephemeral port
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "http://localhost/eSCL/ScanJobs/job-1", relativeTo: usbScanner, postURL: postURL)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/job-1"
        )
        // Absolute Wi-Fi IP rewritten onto USB loopback, preserving %2F and query string
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "http://192.168.1.50:8080/eSCL/ScanJobs/a%2Fb?token=xyz", relativeTo: usbScanner, postURL: postURL)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/a%2Fb?token=xyz"
        )
        // Relative path without leading slash + query resolved against POST URL (/eSCL/ScanJobs -> /eSCL/ScanJobs/job-2?token=x)
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "ScanJobs/job-2?token=x", relativeTo: usbScanner, postURL: postURL)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/job-2?token=x"
        )
        // Root-relative path
        XCTAssertEqual(
            ESCLClient.resolveJobURL(location: "/eSCL/ScanJobs/job-3", relativeTo: usbScanner, postURL: postURL)?.absoluteString,
            "http://127.0.0.1:54321/eSCL/ScanJobs/job-3"
        )
    }

    // MARK: - End-to-End IPPUSBBridge Tests

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
        XCTAssertEqual(bridge.openChannelCount, 0)

        let scanner = makeUSBScanner(id: "usb:MOCK3830", port: Int(port))
        let client = ESCLClient()

        // Concurrent capabilities + chunked status across 2 slots
        async let capsTask = client.fetchCapabilities(from: scanner)
        async let statusTask = client.fetchStatus(from: scanner)
        let (caps, status) = try await (capsTask, statusTask)
        XCTAssertEqual(caps.makeAndModel, "Mock USB OfficeJet 3830")
        XCTAssertEqual(caps.serialNumber, "MOCK3830")
        XCTAssertEqual(status.state, "Idle")

        // Full RAW scan (Location: http://localhost/eSCL/ScanJobs/usb-job-1 -> chunked NextDocument -> ScanImageInfo)
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

        // Idle release verification
        let deadline = Date().addingTimeInterval(2.0)
        while bridge.openChannelCount > 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(bridge.openChannelCount, 0)
        XCTAssertGreaterThanOrEqual(tracker.closedCount, 1)
    }

    func testIPPUSBBridgeFailsOverOnSlotOpenFailureAndDoesNotReplayPartialPOST() async throws {
        // 1. Slot 0 fails to OPEN (simulating macOS CUPS holding exclusive access on IF 0) -> slot 1 succeeds!
        let tracker = MockUSBChannelTracker()
        let openFailBridge = IPPUSBBridge(
            deviceIdentifier: "mock-open-failover",
            channelCount: 2,
            idleReleaseSeconds: 1.0
        ) { slot in
            if slot == 0 {
                throw IPPUSBBridgeError.exclusiveAccessDenied(0)
            }
            return tracker.makeChannel(slot: slot)
        }
        let openPort = try openFailBridge.start()
        defer { openFailBridge.stop() }
        let client = ESCLClient()
        let status = try await client.fetchStatus(from: makeUSBScanner(id: "usb:OPEN", port: Int(openPort)))
        XCTAssertEqual(status.state, "Idle")

        // 2. Slot 0 fails WRITE after sending partial bytes on POST -> bridge must NOT replay POST on slot 1!
        let slot1WriteCounter = CounterBox()
        let partialPostBridge = IPPUSBBridge(
            deviceIdentifier: "mock-partial-post",
            channelCount: 2,
            idleReleaseSeconds: 1.0
        ) { slot in
            if slot == 0 {
                return FailingWriteUSBChannel(bytesWrittenBeforeFailure: 42)
            }
            return CountingUSBChannel(counter: slot1WriteCounter)
        }
        let postPort = try partialPostBridge.start()
        defer { partialPostBridge.stop() }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(postPort)/eSCL/ScanJobs")!)
        req.httpMethod = "POST"
        req.httpBody = Data("<scan/>".utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 502)
        XCTAssertEqual(slot1WriteCounter.count, 0, "Partially written POST must never be replayed on another USB slot")
    }

    func testIPPUSBBridgeSkips100ContinueRejectsGarbageAndHandlesIdleCloseRace() async throws {
        // 1. Printer sends HTTP/1.1 100 Continue followed by final 200 OK -> bridge skips 100 and returns 200!
        let statusXML = "<scan:ScannerStatus xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\"><State>Idle</State></scan:ScannerStatus>"
        let continueBridge = IPPUSBBridge(
            deviceIdentifier: "mock-100-continue",
            channelCount: 1,
            idleReleaseSeconds: 0.15
        ) { _ in
            ScriptedUSBChannel(responseChunks: [
                Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                Data("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(statusXML.utf8.count)\r\n\r\n\(statusXML)".utf8)
            ], closeDelay: 0.12)
        }
        let port = try continueBridge.start()
        defer { continueBridge.stop() }
        let scanner = makeUSBScanner(id: "usb:100", port: Int(port))
        let client = ESCLClient()

        let status1 = try await client.fetchStatus(from: scanner)
        XCTAssertEqual(status1.state, "Idle")

        // 2. Fire a second request right during the slow 120ms idle close window -> must wait for close & succeed!
        try await Task.sleep(for: .milliseconds(170))
        let status2 = try await client.fetchStatus(from: scanner)
        XCTAssertEqual(status2.state, "Idle")

        // 3. Garbage non-HTTP bytes from USB -> rejected with 502 instead of misparsed as HTTP 200
        let garbageBridge = IPPUSBBridge(
            deviceIdentifier: "mock-garbage",
            channelCount: 1,
            idleReleaseSeconds: 1.0
        ) { _ in
            ScriptedUSBChannel(responseChunks: [Data([0xFF, 0xD8, 0x00, 0x10, 0x0D, 0x0A, 0x0D, 0x0A])])
        }
        let gPort = try garbageBridge.start()
        defer { garbageBridge.stop() }
        let (_, gResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(gPort)/eSCL/ScannerStatus")!)
        XCTAssertEqual((gResp as? HTTPURLResponse)?.statusCode, 502)
    }

    // MARK: - Engine Refresh-While-Busy, Unplug Mid-Scan & Stale Capability Guard

    @MainActor
    func testEngineRefreshIgnoredWhileBusyAndUnplugReconcilesAfterCompletion() async throws {
        let suite = "com.chromascan.usbengine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chromascan-usb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        prefs.saveFolderURL = tmpDir

        let browser = RecordingScannerBrowser()
        let client = ControlledESCLClient()
        client.scanDelayNanoseconds = 300_000_000
        let engine = ScanSessionEngine(preferences: prefs, browser: browser, client: client)

        let usbV1 = makeUSBScanner(id: "usb:SN1", port: 50001)
        let usbV2 = makeUSBScanner(id: "usb:SN1", port: 50002)

        // 1. Stale failure on port 50001 must NOT clobber newer successful load on port 50002!
        client.failPorts = [50001]
        client.delayPorts[50001] = 180_000_000 // slow failure arrives AFTER fast success on 50002
        engine.startDiscovery()
        browser.emit([usbV1])
        try await Task.sleep(for: .milliseconds(30))
        browser.emit([usbV2])
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }
        try await Task.sleep(for: .milliseconds(250)) // let slow failure on 50001 finish
        XCTAssertNotNil(engine.capabilities, "Stale failure from old USB port must not overwrite newer successful port handoff")
        XCTAssertEqual(engine.selectedScanner?.port, 50002)

        // 2. Refresh while busy must be ignored (must NOT tear down browser or kill active scan)
        let refreshBefore = browser.refreshCount
        let startBefore = browser.startCount
        engine.startScan()
        try await waitUntil(timeout: 1.0) { engine.isBusy }
        engine.refreshScanners()
        XCTAssertEqual(browser.refreshCount, refreshBefore)
        XCTAssertEqual(browser.startCount, startBefore)

        // 3. Unplugging scanner mid-scan reconciles selection cleanly once scan completes
        browser.emit([])
        XCTAssertTrue(engine.isBusy)
        try await waitUntil(timeout: 2.0) { !engine.isBusy }
        XCTAssertNil(engine.selectedScannerID)
        XCTAssertNil(engine.capabilities)
        XCTAssertEqual(engine.statusText, "No scanners found")
    }

    // MARK: - Helpers

    private func makeUSBScanner(id: String, port: Int) -> DiscoveredScanner {
        DiscoveredScanner(
            id: id,
            name: "Mock HP OfficeJet 3830 (USB)",
            host: "127.0.0.1",
            port: port,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "Mock HP OfficeJet 3830",
            uuid: nil,
            transport: .usb,
            serialNumber: id
        )
    }

    private func makeInterfaceDesc(num: UInt8, alt: UInt8, numEP: UInt8, cls: UInt8, sub: UInt8, proto: UInt8) -> [UInt8] {
        [9, 0x04, num, alt, numEP, cls, sub, proto, 0]
    }

    private func makeEndpointDesc(addr: UInt8, attrs: UInt8, mps: UInt16) -> [UInt8] {
        [7, 0x05, addr, attrs, UInt8(mps & 0xFF), UInt8((mps >> 8) & 0xFF), 0]
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Test Doubles

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

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
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
    let bytesWrittenBeforeFailure: Int
    init(bytesWrittenBeforeFailure: Int = 0) {
        self.bytesWrittenBeforeFailure = bytesWrittenBeforeFailure
    }
    func writeAll(_ data: Data, timeout: TimeInterval) throws {
        throw IPPUSBBridgeError.writeFailed(bytesWritten: bytesWrittenBeforeFailure, detail: "Simulated stalled Bulk OUT pipe")
    }
    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data { Data() }
    func abortAndReset() {}
    func close() {}
}

private final class CountingUSBChannel: IPPUSBChannelTransport, @unchecked Sendable {
    let counter: CounterBox
    init(counter: CounterBox) { self.counter = counter }
    func writeAll(_ data: Data, timeout: TimeInterval) throws {
        counter.increment()
    }
    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data {
        Data("HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n".utf8)
    }
    func abortAndReset() {}
    func close() {}
}

private final class ScriptedUSBChannel: IPPUSBChannelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let templateChunks: [Data]
    private var pendingChunks: [Data] = []
    private let closeDelay: TimeInterval

    init(responseChunks: [Data], closeDelay: TimeInterval = 0) {
        self.templateChunks = responseChunks
        self.closeDelay = closeDelay
    }

    func writeAll(_ data: Data, timeout: TimeInterval) throws {
        lock.lock()
        pendingChunks = templateChunks
        lock.unlock()
    }

    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if pendingChunks.isEmpty { return Data() }
        return pendingChunks.removeFirst()
    }

    func abortAndReset() {
        lock.lock()
        pendingChunks.removeAll()
        lock.unlock()
    }

    func close() {
        if closeDelay > 0 {
            Thread.sleep(forTimeInterval: closeDelay)
        }
    }
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
            fullResponse = Data("HTTP/1.1 201 Created\r\nLocation: http://localhost/eSCL/ScanJobs/usb-job-1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        } else if method == "GET" && path.hasSuffix("/NextDocument") {
            let raw = Data(repeating: 0xAB, count: 64 * 40 * 3)
            var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
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

@MainActor
private final class RecordingScannerBrowser: ScannerBrowserProtocol {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?
    var startCount = 0
    var refreshCount = 0
    var stopCount = 0

    func start() { startCount += 1 }
    func refresh() { refreshCount += 1 }
    func stop() { stopCount += 1 }
    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String) {}
    func emit(_ list: [DiscoveredScanner]) { onScannersChanged?(list) }
}

private final class ControlledESCLClient: ESCLClientProtocol, @unchecked Sendable {
    var failPorts: Set<Int> = []
    var delayPorts: [Int: UInt64] = [:]
    var scanDelayNanoseconds: UInt64 = 0

    func fetchCapabilities(from scanner: DiscoveredScanner) async throws -> ScannerCapabilities {
        if let ns = delayPorts[scanner.port] {
            try? await Task.sleep(nanoseconds: ns)
        }
        if failPorts.contains(scanner.port) {
            throw ESCLClientError.httpError(503, "Port busy")
        }
        return ScannerCapabilities(
            version: "2.5",
            makeAndModel: "Mock USB HP 3830",
            serialNumber: "SN1",
            platen: ScannerCapabilities.InputSourceCaps(
                minWidth: 8, maxWidth: 2550, minHeight: 8, maxHeight: 3508,
                discreteResolutions: [100, 300],
                colorModes: ["RGB24"],
                documentFormats: ["application/octet-stream"],
                intents: ["Photo"],
                contentTypes: ["Photo"],
                maxOpticalResolution: 1200
            ),
            adf: nil,
            brightnessRange: nil,
            contrastRange: nil
        )
    }

    func fetchStatus(from scanner: DiscoveredScanner) async throws -> ScannerStatus {
        ScannerStatus(state: "Idle", adfState: nil)
    }

    func performScan(
        scanner: DiscoveredScanner,
        request: ScanJobRequest,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ScanDownloadResult {
        if scanDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        let w = 64, h = 64
        let data = Data(repeating: 128, count: w * h * 3)
        onProgress(Int64(data.count), Int64(data.count))
        return ScanDownloadResult(
            data: data,
            contentType: "application/octet-stream",
            imageInfo: ScanImageInfo(jobUUID: "j1", actualWidth: w, actualHeight: h, actualBytesPerLine: w * 3),
            jobLocation: URL(string: "http://127.0.0.1:\(scanner.port)/eSCL/ScanJobs/j1")!
        )
    }
}
