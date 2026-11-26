import XCTest
import CoreGraphics
import ImageIO
import Network
@testable import ChromaScan

final class ChromaScanTests: XCTestCase {

    func testParseHP3830CapabilitiesXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.5</pwg:Version>
          <pwg:MakeAndModel>OfficeJet 3830 All-in-One Printer series</pwg:MakeAndModel>
          <pwg:SerialNumber>CN0178Q2QC074J</pwg:SerialNumber>
          <scan:Platen>
            <scan:PlatenInputCaps>
              <scan:MinWidth>8</scan:MinWidth>
              <scan:MaxWidth>2550</scan:MaxWidth>
              <scan:MinHeight>8</scan:MinHeight>
              <scan:MaxHeight>3508</scan:MaxHeight>
              <scan:SettingProfiles>
                <scan:SettingProfile>
                  <scan:ColorModes>
                    <scan:ColorMode>Grayscale8</scan:ColorMode>
                    <scan:ColorMode>RGB24</scan:ColorMode>
                  </scan:ColorModes>
                  <scan:DocumentFormats>
                    <pwg:DocumentFormat>application/octet-stream</pwg:DocumentFormat>
                    <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
                  </scan:DocumentFormats>
                  <scan:SupportedResolutions>
                    <scan:DiscreteResolutions>
                      <scan:DiscreteResolution><scan:XResolution>75</scan:XResolution><scan:YResolution>75</scan:YResolution></scan:DiscreteResolution>
                      <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
                      <scan:DiscreteResolution><scan:XResolution>1200</scan:XResolution><scan:YResolution>1200</scan:YResolution></scan:DiscreteResolution>
                    </scan:DiscreteResolutions>
                  </scan:SupportedResolutions>
                </scan:SettingProfile>
              </scan:SettingProfiles>
              <scan:MaxOpticalXResolution>1200</scan:MaxOpticalXResolution>
            </scan:PlatenInputCaps>
          </scan:Platen>
          <scan:BrightnessSupport><scan:Min>0</scan:Min><scan:Max>2000</scan:Max><scan:Normal>1000</scan:Normal><scan:Step>1</scan:Step></scan:BrightnessSupport>
          <scan:ContrastSupport><scan:Min>0</scan:Min><scan:Max>2000</scan:Max><scan:Normal>1000</scan:Normal><scan:Step>1</scan:Step></scan:ContrastSupport>
        </scan:ScannerCapabilities>
        """
        let caps = try CapabilitiesXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(caps.version, "2.5")
        XCTAssertEqual(caps.makeAndModel, "OfficeJet 3830 All-in-One Printer series")
        XCTAssertEqual(caps.platen?.maxWidth, 2550)
        XCTAssertEqual(caps.platen?.maxHeight, 3508)
        XCTAssertEqual(caps.platen?.discreteResolutions, [75, 300, 1200])
        XCTAssertEqual(caps.platen?.supportsRawOctetStream, true)
        XCTAssertEqual(caps.brightnessRange?.normal, 1000)
        XCTAssertEqual(caps.contrastRange?.max, 2000)
    }

    func testBuildScanSettingsXMLIncludesPhotoAnd1200DPI() {
        let req = ScanJobRequest(
            version: "2.5",
            inputSource: .platen,
            resolution: 1200,
            colorMode: .rgb24,
            intent: .photo,
            isPreview: false,
            transferFormat: .rawOctetStream,
            region: (0, 0, 2550, 3300),
            brightness: 1050,
            contrast: 1100
        )
        let xml = ESCLXMLBuilder.buildScanSettingsXML(for: req)
        XCTAssertTrue(xml.contains("<scan:Intent>Photo</scan:Intent>"))
        XCTAssertTrue(xml.contains("<pwg:ContentType>Photo</pwg:ContentType>"))
        XCTAssertTrue(xml.contains("<scan:XResolution>1200</scan:XResolution>"))
        XCTAssertTrue(xml.contains("<scan:ColorSpace>sRGB</scan:ColorSpace>"))
        XCTAssertTrue(xml.contains("<scan:Brightness>1050</scan:Brightness>"))
        XCTAssertTrue(xml.contains("<scan:Contrast>1100</scan:Contrast>"))

        // JPEG transfer should omit ColorSpace=sRGB (HP firmware uses YCC and rejects sRGB with 409)
        let jpegReq = ScanJobRequest(
            version: "2.5",
            inputSource: .platen,
            resolution: 300,
            colorMode: .rgb24,
            intent: .photo,
            isPreview: false,
            transferFormat: .jpeg,
            region: (0, 0, 2550, 3300),
            brightness: nil,
            contrast: nil
        )
        let jpegXML = ESCLXMLBuilder.buildScanSettingsXML(for: jpegReq)
        XCTAssertTrue(jpegXML.contains("<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>"))
        XCTAssertFalse(jpegXML.contains("<scan:ColorSpace>sRGB</scan:ColorSpace>"))

        // Minimal fallback omits optional ColorSpace, ContentType, and DocumentFormatExt
        let minimalXML = ESCLXMLBuilder.buildScanSettingsXML(for: req, minimal: true)
        XCTAssertFalse(minimalXML.contains("<scan:ColorSpace>"))
        XCTAssertFalse(minimalXML.contains("<pwg:ContentType>"))
        XCTAssertFalse(minimalXML.contains("<scan:DocumentFormatExt>"))
        XCTAssertTrue(minimalXML.contains("<pwg:DocumentFormat>application/octet-stream</pwg:DocumentFormat>"))
    }

    func testImagePipelineDisplayP3ConvertAndExportTIFF() throws {
        // Create a tiny 8x4 RGB24 raw image (red pixel top-left, green next, blue next)
        let w = 8, h = 4
        var bytes = Data(count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let off = (y * w + x) * 3
                bytes[off] = UInt8(min(255, x * 32))
                bytes[off + 1] = UInt8(min(255, y * 64))
                bytes[off + 2] = 180
            }
        }
        let raw = RawImageBuffer(data: bytes, width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 1200)

        // Render with 90-degree rotation + Display P3 conversion
        let cgImg = try ImagePipeline.renderCGImage(
            from: raw,
            rotation: .deg90,
            colorProfile: .displayP3Convert,
            toneAdjustments: ToneAdjustments()
        )
        XCTAssertEqual(cgImg.width, h)
        XCTAssertEqual(cgImg.height, w)
        XCTAssertEqual(cgImg.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(cgImg.bitsPerPixel, 24) // 3-channel RGB, no wasted alpha!

        // Export to temporary LZW TIFF & verify embedded DPI + Display P3 ICC profile
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chromascan-test-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = ExportSettings(
            rotation: .deg90,
            colorProfile: .displayP3Convert,
            toneAdjustments: ToneAdjustments(),
            format: .tiffLZW,
            quality: 0.92,
            scannerMakeAndModel: "OfficeJet 3830"
        )
        try ImagePipeline.export(cgImage: cgImg, dpi: 1200, settings: settings, to: tmp)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(tmp as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Int, 1200)
        XCTAssertEqual(props[kCGImagePropertyDPIHeight] as? Int, 1200)
        let loaded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(loaded.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
    }

    func testFilenameIncrement() {
        XCTAssertEqual(FilenameHelper.incrementedFilename("scan-001"), "scan-002")
        XCTAssertEqual(FilenameHelper.incrementedFilename("pokemon-page-09"), "pokemon-page-10")
        XCTAssertEqual(FilenameHelper.incrementedFilename("watercolor"), "watercolor-002")
    }

    func testSimulateLossyFormatAndProxyDownsample() throws {
        let w = 64, h = 32
        var bytes = Data(count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let off = (y * w + x) * 3
                bytes[off] = UInt8((x * 4) % 256)
                bytes[off + 1] = UInt8((y * 8) % 256)
                bytes[off + 2] = UInt8(((x + y) * 3) % 256)
            }
        }
        let raw = RawImageBuffer(data: bytes, width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 1200)
        let proxy = ImagePipeline.makeProxyBuffer(from: raw, maxDimension: 32)
        XCTAssertEqual(proxy.width, 32)
        XCTAssertEqual(proxy.height, 16)

        let cg = try ImagePipeline.renderCGImage(
            from: raw,
            rotation: .deg0,
            colorProfile: .displayP3Convert,
            toneAdjustments: ToneAdjustments()
        )
        let highQ = try XCTUnwrap(ImagePipeline.simulateLossyFormat(cgImage: cg, format: .jpeg, quality: 0.95))
        let lowQ = try XCTUnwrap(ImagePipeline.simulateLossyFormat(cgImage: cg, format: .jpeg, quality: 0.30))
        XCTAssertEqual(highQ.image.width, w)
        XCTAssertGreaterThan(highQ.encodedBytes, lowQ.encodedBytes)
        XCTAssertNil(ImagePipeline.simulateLossyFormat(cgImage: cg, format: .tiffLZW, quality: 0.9))
    }

    @MainActor
    func testCanvasCursorStaysArrowOutsideBoundsWhenZoomedIn() throws {
        let canvas = PreviewCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let raw = RawImageBuffer(
            data: Data(repeating: 200, count: 1000 * 1000 * 3),
            width: 1000,
            height: 1000,
            bytesPerRow: 1000 * 3,
            colorMode: .rgb24,
            dpi: 300
        )
        let cg = try ImagePipeline.renderCGImage(
            from: raw,
            rotation: .deg0,
            colorProfile: .sRGB,
            toneAdjustments: ToneAdjustments()
        )
        canvas.previewImage = cg
        canvas.truePixelSize = CGSize(width: 1000, height: 1000)
        canvas.zoomToActualSize() // pageRect is 1000x1000 centered in 400x300, extending well outside bounds

        // Inside canvas bounds -> crosshair in preview mode
        XCTAssertEqual(canvas.desiredCursor(at: CGPoint(x: 200, y: 150)), .crosshair)

        // Outside canvas bounds (even though inside zoomed-in pageRect) -> arrow
        XCTAssertEqual(canvas.desiredCursor(at: CGPoint(x: 200, y: -20)), .arrow)
        XCTAssertEqual(canvas.desiredCursor(at: CGPoint(x: 200, y: 320)), .arrow)
        XCTAssertEqual(canvas.desiredCursor(at: CGPoint(x: 420, y: 150)), .arrow)

        // In Last Scan inspection mode -> openHand inside bounds, arrow outside bounds
        canvas.showCropOverlay = false
        XCTAssertEqual(canvas.desiredCursor(at: CGPoint(x: 200, y: 150)), .openHand)
        XCTAssertEqual(canvas.desiredCursor(at: CGPoint(x: 420, y: 150)), .arrow)

        // Tracking area must monitor enter/exit & cursor updates so leaving the canvas resets cursor
        canvas.updateTrackingAreas()
        let area = try XCTUnwrap(canvas.trackingAreas.last)
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.options.contains(.cursorUpdate))
    }

    func testDetectContentBoundsAndCropRawBuffer() throws {
        // 1. Centered artwork on warm cream flatbed lid border (246, 242, 234)
        let w = 200, h = 240
        var centered = Data(count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let off = (y * w + x) * 3
                let inArt = x >= 30 && x < 170 && y >= 40 && y < 200
                if inArt {
                    centered[off] = 40
                    centered[off + 1] = 110
                    centered[off + 2] = 190
                } else {
                    centered[off] = 246
                    centered[off + 1] = 242
                    centered[off + 2] = 234
                }
            }
        }
        let centeredBuf = RawImageBuffer(data: centered, width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 300)
        let centeredRect = try XCTUnwrap(ImagePipeline.detectContentBounds(in: centeredBuf))
        XCTAssertEqual(centeredRect.x, 30.0 / 200.0, accuracy: 0.02)
        XCTAssertEqual(centeredRect.y, 40.0 / 240.0, accuracy: 0.02)
        XCTAssertEqual(centeredRect.width, 140.0 / 200.0, accuracy: 0.025)
        XCTAssertEqual(centeredRect.height, 160.0 / 240.0, accuracy: 0.025)

        let cropped = ImagePipeline.cropRawBuffer(centeredBuf, to: centeredRect)
        XCTAssertLessThan(cropped.width, w)
        XCTAssertLessThan(cropped.height, h)
        XCTAssertGreaterThanOrEqual(cropped.width, 138)
        XCTAssertGreaterThanOrEqual(cropped.height, 158)
        XCTAssertEqual(cropped.dpi, 300)
        XCTAssertEqual(cropped.data.count, cropped.width * cropped.height * 3)

        // 2. Photo aligned flush to top-left flatbed corner (0..110, 0..140) on white lid
        var topLeft = Data(repeating: 250, count: w * h * 3)
        for y in 0..<140 {
            for x in 0..<110 {
                let off = (y * w + x) * 3
                topLeft[off] = 210
                topLeft[off + 1] = 70
                topLeft[off + 2] = 55
            }
        }
        let topLeftBuf = RawImageBuffer(data: topLeft, width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 600)
        let topLeftRect = try XCTUnwrap(ImagePipeline.detectContentBounds(in: topLeftBuf))
        XCTAssertEqual(topLeftRect.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(topLeftRect.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(topLeftRect.width, 110.0 / 200.0, accuracy: 0.02)
        XCTAssertEqual(topLeftRect.height, 140.0 / 240.0, accuracy: 0.02)

        // 3. Grayscale8 document with white margins + isolated 1px dust speck (should ignore dust)
        var gray = Data(repeating: 248, count: w * h)
        for y in 60..<180 {
            for x in 50..<150 {
                gray[y * w + x] = 35
            }
        }
        gray[10 * w + 10] = 20 // isolated 1px dust speck in empty margin
        let grayBuf = RawImageBuffer(data: gray, width: w, height: h, bytesPerRow: w, colorMode: .grayscale8, dpi: 300)
        let grayRect = try XCTUnwrap(ImagePipeline.detectContentBounds(in: grayBuf))
        XCTAssertEqual(grayRect.x, 50.0 / 200.0, accuracy: 0.02)
        XCTAssertEqual(grayRect.y, 60.0 / 240.0, accuracy: 0.02)
        XCTAssertEqual(grayRect.width, 100.0 / 200.0, accuracy: 0.025)
        XCTAssertEqual(grayRect.height, 120.0 / 240.0, accuracy: 0.025)

        // 4. Full-bleed dark/colorful image (no empty border) -> nil
        let fullBleed = RawImageBuffer(data: Data(repeating: 80, count: w * h * 3), width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 300)
        XCTAssertNil(ImagePipeline.detectContentBounds(in: fullBleed))

        // 5. Completely blank white flatbed -> nil (must not collapse to tiny rect)
        let blank = RawImageBuffer(data: Data(repeating: 252, count: w * h * 3), width: w, height: h, bytesPerRow: w * 3, colorMode: .rgb24, dpi: 300)
        XCTAssertNil(ImagePipeline.detectContentBounds(in: blank))

        // 6. Real flatbed scan with thick dark bottom/right mechanical bezel (~1.2%) + 3x2 dust speck in white lid
        let fw = 523, fh = 720
        var flatbed = Data(repeating: 253, count: fw * fh * 3)
        // Book page flush to top-left: 0..<491, 0..<622
        for y in 0..<622 {
            for x in 0..<491 {
                let off = (y * fw + x) * 3
                flatbed[off] = 130
                flatbed[off + 1] = 118
                flatbed[off + 2] = 106
            }
        }
        // 3x2 dark dust speck on glass inside white bottom margin at y=666..667, x=44..46
        for y in 666...667 {
            for x in 44...46 {
                let off = (y * fw + x) * 3
                flatbed[off] = 130; flatbed[off + 1] = 130; flatbed[off + 2] = 130
            }
        }
        // 8px dark mechanical bottom bezel (y=712..<720) & 2px right bezel (x=521..<523)
        for y in 712..<fh {
            for x in 0..<fw {
                let off = (y * fw + x) * 3
                flatbed[off] = 40; flatbed[off + 1] = 40; flatbed[off + 2] = 40
            }
        }
        for y in 0..<fh {
            for x in 521..<fw {
                let off = (y * fw + x) * 3
                flatbed[off] = 35; flatbed[off + 1] = 35; flatbed[off + 2] = 35
            }
        }
        let flatbedBuf = RawImageBuffer(data: flatbed, width: fw, height: fh, bytesPerRow: fw * 3, colorMode: .rgb24, dpi: 1200)
        let flatbedRect = try XCTUnwrap(ImagePipeline.detectContentBounds(in: flatbedBuf))
        XCTAssertEqual(flatbedRect.x, 0.0, accuracy: 0.002)
        XCTAssertEqual(flatbedRect.y, 0.0, accuracy: 0.002)
        XCTAssertEqual(flatbedRect.width, 491.0 / 523.0, accuracy: 0.01)
        XCTAssertEqual(flatbedRect.height, 622.0 / 720.0, accuracy: 0.01)
    }

    // MARK: - ScannerStatus job list (leftover-job cleanup)

    func testScannerJobsParserExtractsActiveAndFinishedJobs() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.5</pwg:Version>
          <pwg:State>Processing</pwg:State>
          <scan:Jobs>
            <scan:JobInfo>
              <pwg:JobUri>/eSCL/ScanJobs/aaa-111</pwg:JobUri>
              <pwg:JobUuid>aaa-111</pwg:JobUuid>
              <pwg:JobState>Processing</pwg:JobState>
              <pwg:JobStateReasons><pwg:JobStateReason>JobScanning</pwg:JobStateReason></pwg:JobStateReasons>
            </scan:JobInfo>
            <scan:JobInfo>
              <pwg:JobUri>/eSCL/ScanJobs/bbb-222</pwg:JobUri>
              <pwg:JobState>Completed</pwg:JobState>
            </scan:JobInfo>
          </scan:Jobs>
        </scan:ScannerStatus>
        """
        let jobs = ScannerJobsXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].jobID, "aaa-111")
        XCTAssertTrue(jobs[0].isActive)
        XCTAssertEqual(jobs[0].stateReasons, ["JobScanning"])
        XCTAssertEqual(jobs[1].jobID, "bbb-222") // falls back to URI path when no UUID
        XCTAssertFalse(jobs[1].isActive)
    }

    func testOwnedJobTrackingRecognizesRememberedJobs() {
        let suiteName = "com.chromascan.test.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }
        let client = ESCLClient(ownedJobsSuiteName: suiteName)

        let id = "job-\(UUID().uuidString)"
        client.rememberOwnedJob(URL(string: "http://localhost:1/eSCL/ScanJobs/\(id)")!)
        XCTAssertTrue(client.isOwnedJob(ESCLJobInfo(uri: "/eSCL/ScanJobs/\(id)", uuid: nil, state: "Processing", stateReasons: [])))
        XCTAssertFalse(client.isOwnedJob(ESCLJobInfo(uri: "/eSCL/ScanJobs/someone-else", uuid: nil, state: "Processing", stateReasons: [])))
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "ESCLClient.recentOwnedScanJobIDs")?.first { $0 == id })
    }

    func testImageGenerationSeedIncreasesAcrossLaunches() {
        let first = Date(timeIntervalSince1970: 1_764_000_000)
        let a = ScanSessionEngine.launchImageGenerationSeed(now: first)
        let b = ScanSessionEngine.launchImageGenerationSeed(now: first.addingTimeInterval(1))
        XCTAssertGreaterThan(a, 0)
        XCTAssertEqual(b - a, 10) // tenths of a second
        XCTAssertEqual(ScanSessionEngine.launchImageGenerationSeed(now: Date(timeIntervalSince1970: 0)), 0)
    }

    // MARK: - Cancellation while POST /ScanJobs is unanswered

    /// Loopback HTTP server that answers ScannerStatus but never answers POST /ScanJobs —
    /// like a printer / macOS ippusbd that accepted the connection and then hung.
    private final class HangingScanServer: @unchecked Sendable {
        let listener: NWListener
        private var connections: [NWConnection] = []
        private let queue = DispatchQueue(label: "HangingScanServer")

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.connections.append(conn)
                conn.start(queue: self.queue)
                self.receive(on: conn)
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<100 {
                if let port = listener.port?.rawValue, port > 0 { return port }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw XCTSkip("loopback listener did not start")
        }

        private func receive(on conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
                guard let self else { return }
                if let data, let text = String(data: data, encoding: .utf8), text.hasPrefix("GET /eSCL/ScannerStatus") {
                    let body = "<?xml version=\"1.0\"?><scan:ScannerStatus xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:State>Idle</pwg:State></scan:ScannerStatus>"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
                }
                // Anything else (POST /ScanJobs) is read and never answered.
                if !done { self.receive(on: conn) }
            }
        }

        func stop() {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }

    func testCancellingWhileScanRequestIsUnansweredReportsCancelledNotFailure() async throws {
        let server = try HangingScanServer()
        defer { server.stop() }
        let port = try await server.start()

        let scanner = DiscoveredScanner(
            id: "hang", name: "Hanging Scanner", host: "127.0.0.1", port: Int(port),
            useTLS: false, rootPath: "eSCL", modelName: nil, uuid: nil
        )
        let request = ScanJobRequest(
            version: "2.5", inputSource: .platen, resolution: 100, colorMode: .rgb24, intent: .photo,
            isPreview: false, transferFormat: .rawOctetStream, region: (0, 0, 2550, 3508),
            brightness: nil, contrast: nil
        )
        let client = ESCLClient(ownedJobsSuiteName: "com.chromascan.tests.escl-owned-jobs")
        let task = Task { try await client.performScan(scanner: scanner, request: request) { _, _ in } }
        try await Task.sleep(nanoseconds: 1_000_000_000) // POST is now in flight and unanswered
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch ESCLClientError.cancelled {
            // expected: engine shows "Scan cancelled", not "Scan Failed"
        } catch {
            XCTFail("expected ESCLClientError.cancelled, got \(error)")
        }
    }

    // MARK: - Slow USB detection

    func testSlowUSBDetection() {
        func check(_ transport: ScannerTransport = .usb, preview: Bool = false, dpi: Int = 1200,
                   format: TransferFormat = .rawOctetStream, mb: Double, seconds: Double) -> Bool {
            ScanSessionEngine.isSlowUSBTransfer(
                transport: transport, isPreview: preview, resolution: dpi, transferFormat: format,
                bytesReceived: Int64(mb * 1e6), streamingSeconds: seconds)
        }
        // Stuck printer-side USB mode: ~0.19 MB/s
        XCTAssertTrue(check(mb: 3.8, seconds: 20))
        XCTAssertTrue(check(dpi: 300, mb: 3.4, seconds: 18))
        XCTAssertTrue(check(mb: 1.6, seconds: 8))   // detected after 8 s of streaming
        // Normal USB speed (~1.6–1.7 MB/s)
        XCTAssertFalse(check(mb: 34, seconds: 20))
        // Too early to judge
        XCTAssertFalse(check(mb: 1.0, seconds: 5))
        XCTAssertFalse(check(mb: 1.4, seconds: 7.9))
        // Excluded: Wi-Fi (normally ~0.3 MB/s), previews, low DPI, JPEG transfers
        XCTAssertFalse(check(.wifi, mb: 6, seconds: 20))
        XCTAssertFalse(check(preview: true, dpi: 100, mb: 3, seconds: 16))
        XCTAssertFalse(check(dpi: 200, mb: 2, seconds: 20))
        XCTAssertFalse(check(format: .jpeg, mb: 2, seconds: 20))
    }

    func testNetworkCounterpartPicksSamePrinterOverPlainHTTP() {
        func s(_ id: String, _ host: String, _ port: Int, tls: Bool, uuid: String?, _ transport: ScannerTransport, model: String = "HP OfficeJet 3830 series") -> DiscoveredScanner {
            DiscoveredScanner(id: id, name: model, host: host, port: port, useTLS: tls, rootPath: "eSCL",
                              modelName: model, uuid: uuid, transport: transport)
        }
        let usb = s("usb", "127.0.0.1", 56824, tls: false, uuid: "hp-uuid", .usb)
        let bonjour = [
            s("usb-bonjour", "localhost", 56824, tls: false, uuid: "hp-uuid", .usb),
            s("wifi-https", "hp.local", 443, tls: true, uuid: "hp-uuid", .wifi),
            s("wifi-http", "hp.local", 8080, tls: false, uuid: "hp-uuid", .wifi),
            s("other", "canon.local", 80, tls: false, uuid: "canon-uuid", .wifi, model: "Canon TS"),
        ]
        XCTAssertEqual(ScannerDeduplicator.networkCounterpart(for: usb, among: bonjour)?.id, "wifi-http")
        // No counterpart for a different printer, or when asked for a non-USB scanner.
        let otherUSB = s("usb2", "127.0.0.1", 1, tls: false, uuid: "epson-uuid", .usb, model: "Epson ET")
        XCTAssertNil(ScannerDeduplicator.networkCounterpart(for: otherUSB, among: bonjour))
        XCTAssertNil(ScannerDeduplicator.networkCounterpart(for: bonjour[2], among: bonjour))
    }
}
