import XCTest
import CoreGraphics
import ImageIO
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
}
