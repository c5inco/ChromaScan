import Foundation
import CoreGraphics

// MARK: - Discovered Scanner

struct DiscoveredScanner: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let useTLS: Bool
    let rootPath: String
    let modelName: String?
    let uuid: String?

    var baseURL: URL {
        let scheme = useTLS ? "https" : "http"
        let trimmedRoot = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let portPart = ((useTLS && port == 443) || (!useTLS && port == 80)) ? "" : ":\(port)"
        return URL(string: "\(scheme)://\(cleanHost)\(portPart)/\(trimmedRoot)")!
    }

    var displayTitle: String {
        if let modelName, !modelName.isEmpty, modelName != name {
            return name
        }
        return name
    }
}

// MARK: - eSCL Capabilities

struct ScannerCapabilities: Codable, Sendable, Equatable {
    let version: String
    let makeAndModel: String
    let serialNumber: String?
    let platen: InputSourceCaps?
    let adf: InputSourceCaps?
    let brightnessRange: ToneRange?
    let contrastRange: ToneRange?

    struct ToneRange: Codable, Sendable, Equatable {
        let min: Int
        let max: Int
        let normal: Int
        let step: Int
    }

    struct InputSourceCaps: Codable, Sendable, Equatable {
        let minWidth: Int       // in 1/300" units
        let maxWidth: Int       // in 1/300" units
        let minHeight: Int      // in 1/300" units
        let maxHeight: Int      // in 1/300" units
        let discreteResolutions: [Int]
        let colorModes: [String]
        let documentFormats: [String]
        let intents: [String]
        let contentTypes: [String]
        let maxOpticalResolution: Int

        var maxWidthInches: Double { Double(maxWidth) / 300.0 }
        var maxHeightInches: Double { Double(maxHeight) / 300.0 }
        var supportsRawOctetStream: Bool { documentFormats.contains("application/octet-stream") }
        var supportsJPEG: Bool { documentFormats.contains("image/jpeg") }
    }

    func caps(for source: ScanInputSource) -> InputSourceCaps? {
        switch source {
        case .platen: return platen
        case .feeder: return adf
        }
    }
}

struct ScannerStatus: Codable, Sendable, Equatable {
    let state: String          // "Idle", "Processing", "Stopped"
    let adfState: String?      // "ScannerAdfEmpty", "ScannerAdfLoaded", etc.
}

struct ScanImageInfo: Codable, Sendable, Equatable {
    let jobUUID: String?
    let actualWidth: Int
    let actualHeight: Int
    let actualBytesPerLine: Int
}

struct ScanDownloadResult: Sendable {
    let data: Data
    let contentType: String
    let imageInfo: ScanImageInfo?
    let jobLocation: URL
}

// MARK: - Canvas View Mode

enum CanvasViewMode: String, CaseIterable, Codable, Sendable {
    case preview = "preview"
    case scan = "scan"

    var segmentIndex: Int {
        switch self {
        case .preview: return 0
        case .scan: return 1
        }
    }

    init(segmentIndex: Int) {
        self = (segmentIndex == 1) ? .scan : .preview
    }
}

// MARK: - Scan Options

enum ScanInputSource: String, CaseIterable, Codable, Sendable {
    case platen = "Platen"
    case feeder = "Feeder"

    var displayName: String {
        switch self {
        case .platen: return "Flatbed"
        case .feeder: return "Document Feeder (ADF)"
        }
    }
}

enum ScanColorMode: String, CaseIterable, Codable, Sendable {
    case rgb24 = "RGB24"
    case grayscale8 = "Grayscale8"

    var displayName: String {
        switch self {
        case .rgb24: return "Color (24-bit RGB)"
        case .grayscale8: return "Grayscale (8-bit)"
        }
    }

    var bytesPerPixel: Int {
        switch self {
        case .rgb24: return 3
        case .grayscale8: return 1
        }
    }
}

enum ScanIntent: String, CaseIterable, Codable, Sendable {
    case photo = "Photo"
    case document = "Document"
    case textAndGraphic = "TextAndGraphic"

    var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .document: return "Document"
        case .textAndGraphic: return "Text & Graphic"
        }
    }

    var contentType: String {
        switch self {
        case .photo: return "Photo"
        case .document: return "Text"
        case .textAndGraphic: return "TextAndPhoto"
        }
    }
}

enum TransferFormat: String, CaseIterable, Codable, Sendable {
    case rawOctetStream = "application/octet-stream"
    case jpeg = "image/jpeg"

    var displayName: String {
        switch self {
        case .rawOctetStream: return "RAW (Lossless)"
        case .jpeg: return "Fast Wi-Fi (JPEG)"
        }
    }
}

enum ScanRotation: Int, CaseIterable, Codable, Sendable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270

    var displayName: String { "\(rawValue)°" }
}

enum ColorProfileMode: String, CaseIterable, Codable, Sendable {
    case displayP3Convert = "p3_convert"
    case displayP3Assign = "p3_assign"
    case sRGB = "srgb"

    var displayName: String {
        switch self {
        case .displayP3Convert: return "Display P3 (Convert from sRGB)"
        case .displayP3Assign: return "Display P3 (Assign — Vivid)"
        case .sRGB: return "sRGB IEC61966-2.1"
        }
    }

    var shortName: String {
        switch self {
        case .displayP3Convert: return "Display P3 (Accurate)"
        case .displayP3Assign: return "Display P3 (Vivid)"
        case .sRGB: return "sRGB"
        }
    }
}

enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case tiffLZW = "tiff_lzw"
    case tiffUncompressed = "tiff_uncompressed"
    case png = "png"
    case jpeg = "jpeg"
    case heic = "heic"

    var displayName: String {
        switch self {
        case .tiffLZW: return "TIFF (LZW Lossless)"
        case .tiffUncompressed: return "TIFF (Uncompressed)"
        case .png: return "PNG (Lossless)"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .tiffLZW, .tiffUncompressed: return "tiff"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var uti: String {
        switch self {
        case .tiffLZW, .tiffUncompressed: return "public.tiff"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        }
    }

    var supportsQuality: Bool {
        self == .jpeg || self == .heic
    }
}

struct ToneAdjustments: Codable, Equatable, Sendable {
    var blackPoint: Double = 0.0   // 0.0 ... 0.25
    var whitePoint: Double = 1.0   // 0.75 ... 1.0
    var gamma: Double = 1.0        // 0.50 ... 2.00

    var isIdentity: Bool {
        abs(blackPoint) < 0.0001 && abs(whitePoint - 1.0) < 0.0001 && abs(gamma - 1.0) < 0.0001
    }

    /// Generates a 256-entry LUT mapping input 0..255 to output 0..255.
    func makeLUT() -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 256)
        let bp = max(0.0, min(0.5, blackPoint))
        let wp = max(bp + 0.01, min(1.0, whitePoint))
        let invRange = 1.0 / (wp - bp)
        let invGamma = 1.0 / max(0.1, gamma)
        for i in 0..<256 {
            let x = Double(i) / 255.0
            let stretched = max(0.0, min(1.0, (x - bp) * invRange))
            let curved = pow(stretched, invGamma)
            lut[i] = UInt8(max(0, min(255, Int((curved * 255.0).rounded()))))
        }
        return lut
    }
}

/// Normalized crop rectangle in physical flatbed coordinates (origin top-left, 0...1).
struct NormalizedCropRect: Codable, Equatable, Sendable {
    var x: Double = 0.0
    var y: Double = 0.0
    var width: Double = 1.0
    var height: Double = 1.0

    static let full = NormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        abs(x) < 0.001 && abs(y) < 0.001 && abs(width - 1.0) < 0.001 && abs(height - 1.0) < 0.001
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: Double = 0.0, y: Double = 0.0, width: Double = 1.0, height: Double = 1.0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }

    func clamped(minSize: Double = 0.02) -> NormalizedCropRect {
        let cx = max(0.0, min(1.0 - minSize, x))
        let cy = max(0.0, min(1.0 - minSize, y))
        let cw = max(minSize, min(1.0 - cx, width))
        let ch = max(minSize, min(1.0 - cy, height))
        return NormalizedCropRect(x: cx, y: cy, width: cw, height: ch)
    }

    /// Convert to eSCL ThreeHundredthsOfInches scan region for given input caps.
    func toESCLRegion(maxWidth: Int, maxHeight: Int) -> (xOffset: Int, yOffset: Int, width: Int, height: Int) {
        let c = clamped()
        let xOff = max(0, Int((c.x * Double(maxWidth)).rounded()))
        let yOff = max(0, Int((c.y * Double(maxHeight)).rounded()))
        let w = max(8, min(maxWidth - xOff, Int((c.width * Double(maxWidth)).rounded())))
        let h = max(8, min(maxHeight - yOff, Int((c.height * Double(maxHeight)).rounded())))
        return (xOff, yOff, w, h)
    }

    /// Maps physical platen coordinates to displayed rotated coordinates (origin top-left, 0...1).
    func physicalToDisplay(rotation: ScanRotation) -> CGRect {
        let p1 = Self.mapPointToDisplay(CGPoint(x: x, y: y), rotation: rotation)
        let p2 = Self.mapPointToDisplay(CGPoint(x: x + width, y: y + height), rotation: rotation)
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        return CGRect(x: minX, y: minY, width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    /// Maps displayed rotated coordinates (origin top-left, 0...1) back to physical platen coordinates.
    static func fromDisplayRect(_ rect: CGRect, rotation: ScanRotation) -> NormalizedCropRect {
        let p1 = mapPointToPhysical(CGPoint(x: rect.minX, y: rect.minY), rotation: rotation)
        let p2 = mapPointToPhysical(CGPoint(x: rect.maxX, y: rect.maxY), rotation: rotation)
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        return NormalizedCropRect(
            x: Double(minX),
            y: Double(minY),
            width: Double(abs(p2.x - p1.x)),
            height: Double(abs(p2.y - p1.y))
        ).clamped()
    }

    static func mapPointToDisplay(_ p: CGPoint, rotation: ScanRotation) -> CGPoint {
        switch rotation {
        case .deg0: return p
        case .deg90: return CGPoint(x: 1.0 - p.y, y: p.x)
        case .deg180: return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
        case .deg270: return CGPoint(x: p.y, y: 1.0 - p.x)
        }
    }

    static func mapPointToPhysical(_ p: CGPoint, rotation: ScanRotation) -> CGPoint {
        switch rotation {
        case .deg0: return p
        case .deg90: return CGPoint(x: p.y, y: 1.0 - p.x)
        case .deg180: return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
        case .deg270: return CGPoint(x: 1.0 - p.y, y: p.x)
        }
    }
}

// MARK: - Shared Session Settings & Patch

struct ScanSessionSettings: Codable, Equatable, Sendable {
    var inputSource: ScanInputSource = .platen
    var resolution: Int = 1200
    var colorMode: ScanColorMode = .rgb24
    var intent: ScanIntent = .photo
    var transferFormat: TransferFormat = .rawOctetStream
    var rotation: ScanRotation = .deg0
    var autoTrimEmptySpace: Bool = false
    var hardwareBrightness: Int = 1000
    var hardwareContrast: Int = 1000
    var colorProfile: ColorProfileMode = .displayP3Convert
    var outputFormat: OutputFormat = .tiffLZW
    var quality: Double = 0.92
    var previewCompressionEnabled: Bool = true
    var toneAdjustments: ToneAdjustments = ToneAdjustments()
    var baseFilename: String = "scan-001"
    var autoIncrement: Bool = true
}

struct ScanSettingsPatch: Codable, Equatable, Sendable {
    var inputSource: ScanInputSource?
    var resolution: Int?
    var colorMode: ScanColorMode?
    var intent: ScanIntent?
    var transferFormat: TransferFormat?
    var rotation: ScanRotation?
    var autoTrimEmptySpace: Bool?
    var hardwareBrightness: Int?
    var hardwareContrast: Int?
    var resetHardwareTone: Bool?
    var colorProfile: ColorProfileMode?
    var outputFormat: OutputFormat?
    var quality: Double?
    var previewCompressionEnabled: Bool?
    var toneAdjustments: ToneAdjustments?
    var resetSoftwareTone: Bool?
    var baseFilename: String?
    var autoIncrement: Bool?

    init(
        inputSource: ScanInputSource? = nil,
        resolution: Int? = nil,
        colorMode: ScanColorMode? = nil,
        intent: ScanIntent? = nil,
        transferFormat: TransferFormat? = nil,
        rotation: ScanRotation? = nil,
        autoTrimEmptySpace: Bool? = nil,
        hardwareBrightness: Int? = nil,
        hardwareContrast: Int? = nil,
        resetHardwareTone: Bool? = nil,
        colorProfile: ColorProfileMode? = nil,
        outputFormat: OutputFormat? = nil,
        quality: Double? = nil,
        previewCompressionEnabled: Bool? = nil,
        toneAdjustments: ToneAdjustments? = nil,
        resetSoftwareTone: Bool? = nil,
        baseFilename: String? = nil,
        autoIncrement: Bool? = nil
    ) {
        self.inputSource = inputSource
        self.resolution = resolution
        self.colorMode = colorMode
        self.intent = intent
        self.transferFormat = transferFormat
        self.rotation = rotation
        self.autoTrimEmptySpace = autoTrimEmptySpace
        self.hardwareBrightness = hardwareBrightness
        self.hardwareContrast = hardwareContrast
        self.resetHardwareTone = resetHardwareTone
        self.colorProfile = colorProfile
        self.outputFormat = outputFormat
        self.quality = quality
        self.previewCompressionEnabled = previewCompressionEnabled
        self.toneAdjustments = toneAdjustments
        self.resetSoftwareTone = resetSoftwareTone
        self.baseFilename = baseFilename
        self.autoIncrement = autoIncrement
    }

    var affectsDisplayRendering: Bool {
        rotation != nil
            || colorProfile != nil
            || outputFormat != nil
            || quality != nil
            || previewCompressionEnabled != nil
            || toneAdjustments != nil
            || resetSoftwareTone == true
    }
}

struct ScanJobRequest: Sendable {
    let version: String
    let inputSource: ScanInputSource
    let resolution: Int
    let colorMode: ScanColorMode
    let intent: ScanIntent
    let isPreview: Bool
    let transferFormat: TransferFormat
    let region: (xOffset: Int, yOffset: Int, width: Int, height: Int)
    let brightness: Int?
    let contrast: Int?

    var expectedPixelWidth: Int {
        Int((Double(region.width) * Double(resolution) / 300.0).rounded())
    }

    var expectedPixelHeight: Int {
        Int((Double(region.height) * Double(resolution) / 300.0).rounded())
    }

    var expectedRawByteCount: Int64 {
        Int64(expectedPixelWidth) * Int64(expectedPixelHeight) * Int64(colorMode.bytesPerPixel)
    }
}

/// Raw uncompressed pixel buffer (RGB24 or Grayscale8) held in memory.
struct RawImageBuffer: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let colorMode: ScanColorMode
    let dpi: Int
}

struct ExportSettings: Sendable {
    let rotation: ScanRotation
    let colorProfile: ColorProfileMode
    let toneAdjustments: ToneAdjustments
    let format: OutputFormat
    let quality: Double
    let scannerMakeAndModel: String?
}
