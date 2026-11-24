import Foundation

@MainActor
final class AppPreferences {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let resolution = "scan.resolution"
        static let colorMode = "scan.colorMode"
        static let intent = "scan.intent"
        static let transferFormat = "scan.transferFormat"
        static let rotation = "scan.rotation"
        static let colorProfile = "output.colorProfile"
        static let outputFormat = "output.format"
        static let quality = "output.quality"
        static let saveFolderPath = "output.saveFolderPath"
        static let baseFilename = "output.baseFilename"
        static let autoIncrement = "output.autoIncrement"
    }

    var resolution: Int {
        get {
            let v = defaults.integer(forKey: Key.resolution)
            return v > 0 ? v : 1200
        }
        set { defaults.set(newValue, forKey: Key.resolution) }
    }

    var colorMode: ScanColorMode {
        get { ScanColorMode(rawValue: defaults.string(forKey: Key.colorMode) ?? "") ?? .rgb24 }
        set { defaults.set(newValue.rawValue, forKey: Key.colorMode) }
    }

    var intent: ScanIntent {
        get { ScanIntent(rawValue: defaults.string(forKey: Key.intent) ?? "") ?? .photo }
        set { defaults.set(newValue.rawValue, forKey: Key.intent) }
    }

    var transferFormat: TransferFormat {
        get { TransferFormat(rawValue: defaults.string(forKey: Key.transferFormat) ?? "") ?? .rawOctetStream }
        set { defaults.set(newValue.rawValue, forKey: Key.transferFormat) }
    }

    var rotation: ScanRotation {
        get { ScanRotation(rawValue: defaults.integer(forKey: Key.rotation)) ?? .deg0 }
        set { defaults.set(newValue.rawValue, forKey: Key.rotation) }
    }

    var colorProfile: ColorProfileMode {
        get { ColorProfileMode(rawValue: defaults.string(forKey: Key.colorProfile) ?? "") ?? .displayP3Convert }
        set { defaults.set(newValue.rawValue, forKey: Key.colorProfile) }
    }

    var outputFormat: OutputFormat {
        get { OutputFormat(rawValue: defaults.string(forKey: Key.outputFormat) ?? "") ?? .tiffLZW }
        set { defaults.set(newValue.rawValue, forKey: Key.outputFormat) }
    }

    var quality: Double {
        get {
            let v = defaults.double(forKey: Key.quality)
            return v > 0 ? v : 0.92
        }
        set { defaults.set(newValue, forKey: Key.quality) }
    }

    var saveFolderURL: URL {
        get {
            if let path = defaults.string(forKey: Key.saveFolderPath), !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set { defaults.set(newValue.path, forKey: Key.saveFolderPath) }
    }

    var baseFilename: String {
        get {
            let s = defaults.string(forKey: Key.baseFilename) ?? ""
            return s.isEmpty ? "scan-001" : s
        }
        set { defaults.set(newValue, forKey: Key.baseFilename) }
    }

    var autoIncrement: Bool {
        get {
            if defaults.object(forKey: Key.autoIncrement) == nil { return true }
            return defaults.bool(forKey: Key.autoIncrement)
        }
        set { defaults.set(newValue, forKey: Key.autoIncrement) }
    }
}

enum FilenameHelper {
    /// Increments a trailing number preserving zero padding (e.g. "scan-001" -> "scan-002", "page-9" -> "page-10").
    /// If there is no trailing number, appends "-002".
    static func incrementedFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "scan-002" }

        let digitEnd = trimmed.endIndex
        var digitStart = digitEnd
        while digitStart > trimmed.startIndex {
            let prev = trimmed.index(before: digitStart)
            if trimmed[prev].isASCII && trimmed[prev].isNumber {
                digitStart = prev
            } else {
                break
            }
        }

        if digitStart < digitEnd {
            let prefix = trimmed[..<digitStart]
            let digits = trimmed[digitStart..<digitEnd]
            if let num = Int(digits) {
                let width = digits.count
                let formatted = String(format: "%0*d", width, num + 1)
                return "\(prefix)\(formatted)"
            }
        }
        return "\(trimmed)-002"
    }

    /// Returns a non-colliding URL in `folder` for `baseName.ext`.
    static func uniqueDestinationURL(in folder: URL, baseName: String, ext: String) -> URL {
        let cleanBase = baseName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let stem = cleanBase.isEmpty ? "scan" : cleanBase
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
