import Foundation
import CoreGraphics

// MARK: - Discovered Scanner

struct DiscoveredScanner: Identifiable, Hashable, Sendable {
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

struct ScannerCapabilities: Sendable, Equatable {
    let version: String
    let makeAndModel: String
    let serialNumber: String?
    let platen: InputSourceCaps?
    let adf: InputSourceCaps?
    let brightnessRange: ToneRange?
    let contrastRange: ToneRange?

    struct ToneRange: Sendable, Equatable {
        let min: Int
        let max: Int
        let normal: Int
        let step: Int
    }

    struct InputSourceCaps: Sendable, Equatable {
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

struct ScannerStatus: Sendable, Equatable {
    let state: String          // "Idle", "Processing", "Stopped"
    let adfState: String?      // "ScannerAdfEmpty", "ScannerAdfLoaded", etc.
}

struct ScanImageInfo: Sendable, Equatable {
    let jobUUID: String?
    let actualWidth: Int
    let actualHeight: Int
    let actualBytesPerLine: Int
}

// MARK: - Scan Options

enum ScanInputSource: String, CaseIterable, Sendable {
    case platen = "Platen"
    case feeder = "Feeder"

    var displayName: String {
        switch self {
        case .platen: return "Flatbed"
        case .feeder: return "Document Feeder (ADF)"
        }
    }
}

enum ScanColorMode: String, CaseIterable, Sendable {
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

enum ScanIntent: String, CaseIterable, Sendable {
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

enum TransferFormat: String, CaseIterable, Sendable {
    case rawOctetStream = "application/octet-stream"
    case jpeg = "image/jpeg"

    var displayName: String {
        switch self {
        case .rawOctetStream: return "RAW (Lossless)"
        case .jpeg: return "Fast Wi-Fi (JPEG)"
        }
    }
}

enum ScanRotation: Int, CaseIterable, Sendable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270

    var displayName: String { "\(rawValue)°" }
}

enum ColorProfileMode: String, CaseIterable, Sendable {
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

enum OutputFormat: String, CaseIterable, Sendable {
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

struct ToneAdjustments: Equatable, Sendable {
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
struct NormalizedCropRect: Equatable, Sendable {
    var x: Double = 0.0
    var y: Double = 0.0
    var width: Double = 1.0
    var height: Double = 1.0

    static let full = NormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        abs(x) < 0.001 && abs(y) < 0.001 && abs(width - 1.0) < 0.001 && abs(height - 1.0) < 0.001
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
