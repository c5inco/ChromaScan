import XCTest
import CoreGraphics
import ImageIO
@testable import ChromaScan

// MARK: - Test Doubles

@MainActor
final class MockScannerBrowser: ScannerBrowserProtocol {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?
    var startCount = 0
    var stopCount = 0
    private var scanners: [DiscoveredScanner] = []

    func start() {
        startCount += 1
        onScannersChanged?(scanners)
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ list: [DiscoveredScanner]) {
        scanners = list
        onScannersChanged?(list)
    }

    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String) {
        let s = DiscoveredScanner(
            id: "manual:\(host):\(port):\(useTLS)",
            name: "\(host) (Manual)",
            host: host,
            port: port,
            useTLS: useTLS,
            rootPath: rootPath,
            modelName: nil,
            uuid: nil
        )
        scanners.append(s)
        onScannersChanged?(scanners)
    }
}

final class MockESCLClient: ESCLClientProtocol, @unchecked Sendable {
    var capabilities: ScannerCapabilities
    var status = ScannerStatus(state: "Idle", adfState: nil)
    var scanDelayNanoseconds: UInt64 = 0
    var progressChunks = 3
    var syntheticWhiteMarginFraction: Double = 0.0
    var lastScanRequest: ScanJobRequest?
    var wasCancelled = false

    init() {
        self.capabilities = ScannerCapabilities(
            version: "2.5",
            makeAndModel: "Mock HP OfficeJet 3830",
            serialNumber: "MOCK1234",
            platen: ScannerCapabilities.InputSourceCaps(
                minWidth: 8,
                maxWidth: 2550,
                minHeight: 8,
                maxHeight: 3508,
                discreteResolutions: [75, 100, 300, 600, 1200],
                colorModes: ["RGB24", "Grayscale8"],
                documentFormats: ["application/octet-stream", "image/jpeg"],
                intents: ["Photo", "Document"],
                contentTypes: ["Photo", "Text"],
                maxOpticalResolution: 1200
            ),
            adf: nil,
            brightnessRange: ScannerCapabilities.ToneRange(min: 0, max: 2000, normal: 1000, step: 1),
            contrastRange: ScannerCapabilities.ToneRange(min: 0, max: 2000, normal: 1000, step: 1)
        )
    }

    func fetchCapabilities(from scanner: DiscoveredScanner) async throws -> ScannerCapabilities {
        capabilities
    }

    func fetchStatus(from scanner: DiscoveredScanner) async throws -> ScannerStatus {
        status
    }

    func performScan(
        scanner: DiscoveredScanner,
        request: ScanJobRequest,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ScanDownloadResult {
        lastScanRequest = request

        // Keep test images fast and bounded while preserving exact aspect / multi-resolution behavior
        let w = min(640, max(64, request.expectedPixelWidth))
        let h = min(800, max(64, request.expectedPixelHeight))
        let bpp = request.colorMode.bytesPerPixel
        let total = w * h * bpp

        if scanDelayNanoseconds > 0 {
            let steps = max(1, progressChunks)
            let stepDelay = scanDelayNanoseconds / UInt64(steps)
            for i in 1...steps {
                do {
                    try await Task.sleep(nanoseconds: stepDelay)
                } catch {
                    wasCancelled = true
                    throw ESCLClientError.cancelled
                }
                if Task.isCancelled {
                    wasCancelled = true
                    throw ESCLClientError.cancelled
                }
                onProgress(Int64((total * i) / steps), Int64(total))
            }
        } else {
            onProgress(Int64(total / 2), Int64(total))
            onProgress(Int64(total), Int64(total))
        }

        var data = Data(count: total)
        let margin = syntheticWhiteMarginFraction
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let minX = Int(Double(w) * margin)
            let maxX = w - minX
            let minY = Int(Double(h) * margin)
            let maxY = h - minY
            for y in 0..<h {
                for x in 0..<w {
                    let off = (y * w + x) * bpp
                    let isBorder = margin > 0 && (x < minX || x >= maxX || y < minY || y >= maxY)
                    if isBorder {
                        if bpp == 3 {
                            ptr[off] = 248
                            ptr[off + 1] = 248
                            ptr[off + 2] = 246
                        } else {
                            ptr[off] = 248
                        }
                    } else if bpp == 3 {
                        ptr[off] = UInt8((x * 255) / max(1, w - 1))
                        ptr[off + 1] = UInt8((y * 255) / max(1, h - 1))
                        ptr[off + 2] = 160
                    } else {
                        ptr[off] = UInt8(((x + y) * 255) / max(1, w + h - 2))
                    }
                }
            }
        }

        let info = ScanImageInfo(jobUUID: "job-1", actualWidth: w, actualHeight: h, actualBytesPerLine: w * bpp)
        return ScanDownloadResult(
            data: data,
            contentType: "application/octet-stream",
            imageInfo: info,
            jobLocation: URL(string: "http://mock.local/eSCL/ScanJobs/job-1")!
        )
    }
}

// MARK: - ScanSessionEngine Tests

@MainActor
final class ScanSessionEngineTests: XCTestCase {

    private func makeIsolatedEngine(client: MockESCLClient = MockESCLClient()) -> (ScanSessionEngine, MockScannerBrowser, MockESCLClient, URL) {
        let suite = "com.chromascan.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = AppPreferences(defaults: defaults)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("chromascan-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        prefs.saveFolderURL = tmpDir
        prefs.baseFilename = "artwork-001"
        prefs.resolution = 300
        prefs.outputFormat = .tiffLZW
        prefs.colorProfile = .displayP3Convert

        let browser = MockScannerBrowser()
        let engine = ScanSessionEngine(preferences: prefs, browser: browser, client: client)
        return (engine, browser, client, tmpDir)
    }

    func testPreviewScanExportAndTilePipeline() async throws {
        let (engine, browser, client, tmpDir) = makeIsolatedEngine()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scanner = DiscoveredScanner(
            id: "mock-hp",
            name: "Mock HP 3830",
            host: "mock.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "Mock HP 3830",
            uuid: "mock-hp"
        )
        engine.startDiscovery()
        browser.emit([scanner])

        // Wait for capabilities fetch
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }
        XCTAssertEqual(engine.selectedScannerID, "mock-hp")
        XCTAssertEqual(engine.scannerStatus?.state, "Idle")

        // 1. Trigger preview
        engine.startPreview()
        try await waitUntil(timeout: 3.0) { !engine.isBusy && engine.renderedDisplayImage != nil }
        XCTAssertEqual(engine.viewMode, .preview)
        XCTAssertNotNil(engine.rawPreviewBuffer)

        // Encode companion proxy for preview
        let previewProxy = await engine.encodeActiveProxy()
        XCTAssertNotNil(previewProxy)
        XCTAssertEqual(previewProxy?.info.kind, .previewProxy)

        // 2. Apply crop & rotation & trigger full scan
        engine.setCropRect(NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        engine.updateSettings(ScanSettingsPatch(rotation: .deg90, colorProfile: .displayP3Convert))
        engine.startScan()

        try await waitUntil(timeout: 3.0) { !engine.isBusy && engine.lastSavedURL != nil && engine.viewMode == .scan }
        let savedURL = try XCTUnwrap(engine.lastSavedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(savedURL.lastPathComponent, "artwork-001.tiff")
        XCTAssertEqual(engine.settings.baseFilename, "artwork-002") // auto-incremented!
        XCTAssertNotNil(client.lastScanRequest)

        // Verify saved TIFF has Display P3 ICC profile and 300 DPI metadata
        let imgSrc = try XCTUnwrap(CGImageSourceCreateWithURL(savedURL as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imgSrc, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Int, 300)
        let savedCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imgSrc, 0, nil))
        XCTAssertEqual(savedCG.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // 3. Request 1:1 high-res tile
        let tile = await engine.encodeHighResTile(
            requestID: 99,
            normalizedRect: NormalizedCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            maxPixelWidth: 1200
        )
        XCTAssertNotNil(tile)
        XCTAssertEqual(tile?.info.kind, .highResTile)
        XCTAssertEqual(tile?.info.requestID, 99)

        // 4. Re-export with changed format (HEIC)
        engine.updateSettings(ScanSettingsPatch(outputFormat: .heic, quality: 0.90))
        engine.exportCurrentScan()
        try await waitUntil(timeout: 3.0) { !engine.isBusy && engine.lastSavedURL?.lastPathComponent == "artwork-002.heic" }
        let reExportURL = try XCTUnwrap(engine.lastSavedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reExportURL.path))
    }

    func testCancelMidScanResetsStateCleanly() async throws {
        let client = MockESCLClient()
        client.scanDelayNanoseconds = 2_000_000_000 // 2 seconds
        client.progressChunks = 10
        let (engine, browser, _, tmpDir) = makeIsolatedEngine(client: client)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scanner = DiscoveredScanner(
            id: "mock-hp",
            name: "Mock HP 3830",
            host: "mock.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: nil,
            uuid: nil
        )
        engine.startDiscovery()
        browser.emit([scanner])
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }

        engine.startScan()
        try await waitUntil(timeout: 1.0) { engine.isBusy }
        try await Task.sleep(for: .milliseconds(250))

        engine.cancelActiveOperation()
        try await waitUntil(timeout: 2.0) { !engine.isBusy }
        XCTAssertEqual(engine.statusText, "Scan cancelled")
        XCTAssertNil(engine.lastSavedURL)
        XCTAssertTrue(client.wasCancelled)
    }

    func testAutoTrimOnScanManualTrimAndRestoreFull() async throws {
        let client = MockESCLClient()
        client.syntheticWhiteMarginFraction = 0.20
        let (engine, browser, _, tmpDir) = makeIsolatedEngine(client: client)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scanner = DiscoveredScanner(
            id: "mock-hp",
            name: "Mock HP 3830",
            host: "mock.local",
            port: 8080,
            useTLS: false,
            rootPath: "eSCL",
            modelName: "Mock HP 3830",
            uuid: "mock-hp"
        )
        engine.startDiscovery()
        browser.emit([scanner])
        try await waitUntil(timeout: 2.0) { engine.capabilities != nil }

        // 1. Preview + manual Trim Empty Space snaps marquee tightly around content and supports Cmd+Z undo/redo
        engine.startPreview()
        try await waitUntil(timeout: 3.0) { !engine.isBusy && engine.rawPreviewBuffer != nil }
        XCTAssertTrue(engine.cropRect.isFull)

        engine.trimEmptySpace()
        try await waitUntil(timeout: 2.0) { !engine.cropRect.isFull }
        XCTAssertEqual(engine.cropRect.x, 0.20, accuracy: 0.03)
        XCTAssertEqual(engine.cropRect.y, 0.20, accuracy: 0.03)
        XCTAssertEqual(engine.cropRect.width, 0.60, accuracy: 0.04)
        XCTAssertEqual(engine.cropRect.height, 0.60, accuracy: 0.04)
        XCTAssertTrue(engine.undoManager.canUndo)

        engine.undo()
        XCTAssertTrue(engine.cropRect.isFull)
        XCTAssertTrue(engine.undoManager.canRedo)

        engine.redo()
        XCTAssertFalse(engine.cropRect.isFull)

        // Reset marquee to full page, enable Auto-Trim on scan, and run a scan
        engine.resetCrop()
        engine.updateSettings(ScanSettingsPatch(autoTrimEmptySpace: true))
        XCTAssertTrue(engine.settings.autoTrimEmptySpace)
        XCTAssertTrue(engine.preferences.autoTrimEmptySpace)

        engine.startScan()
        try await waitUntil(timeout: 3.0) { !engine.isBusy && engine.lastSavedURL != nil && engine.viewMode == .scan }
        XCTAssertTrue(engine.isScanTrimmed)
        XCTAssertTrue(engine.undoManager.canUndo)

        let rawScan = try XCTUnwrap(engine.rawScanBuffer)
        let savedURL = try XCTUnwrap(engine.lastSavedURL)
        let trimmedSrc = try XCTUnwrap(CGImageSourceCreateWithURL(savedURL as CFURL, nil))
        let trimmedCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(trimmedSrc, 0, nil))
        XCTAssertLessThan(trimmedCG.width, rawScan.width)
        XCTAssertLessThan(trimmedCG.height, rawScan.height)
        let snapTrimmed = engine.makeSnapshot()
        XCTAssertTrue(snapTrimmed.isScanTrimmed)
        XCTAssertEqual(snapTrimmed.scanPixelWidth, trimmedCG.width)
        XCTAssertEqual(snapTrimmed.scanPixelHeight, trimmedCG.height)

        // 2. Undo (Cmd+Z) restores full scan non-destructively and re-export writes full dimensions
        engine.undo()
        XCTAssertFalse(engine.isScanTrimmed)
        XCTAssertTrue(engine.undoManager.canRedo)
        let snapRestored = engine.makeSnapshot()
        XCTAssertEqual(snapRestored.scanPixelWidth, rawScan.width)
        XCTAssertEqual(snapRestored.scanPixelHeight, rawScan.height)

        engine.exportCurrentScan()
        try await waitUntil(timeout: 3.0) { !engine.isBusy && engine.lastSavedURL?.lastPathComponent == "artwork-002.tiff" }
        let restoredURL = try XCTUnwrap(engine.lastSavedURL)
        let restoredSrc = try XCTUnwrap(CGImageSourceCreateWithURL(restoredURL as CFURL, nil))
        let restoredCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(restoredSrc, 0, nil))
        XCTAssertEqual(restoredCG.width, rawScan.width)
        XCTAssertEqual(restoredCG.height, rawScan.height)

        // 3. Redo (Shift+Cmd+Z) re-applies trim cleanly, and manual Trim after undo works too
        engine.redo()
        XCTAssertTrue(engine.isScanTrimmed)
        XCTAssertEqual(engine.makeSnapshot().scanPixelWidth, trimmedCG.width)
        XCTAssertEqual(engine.makeSnapshot().scanPixelHeight, trimmedCG.height)

        engine.undo()
        XCTAssertFalse(engine.isScanTrimmed)
        engine.trimEmptySpace()
        try await waitUntil(timeout: 2.0) { engine.isScanTrimmed }
        XCTAssertEqual(engine.makeSnapshot().scanPixelWidth, trimmedCG.width)
        XCTAssertEqual(engine.makeSnapshot().scanPixelHeight, trimmedCG.height)
    }

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
