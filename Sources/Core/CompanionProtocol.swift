import Foundation

// MARK: - Protocol Constants

enum CompanionConstants {
    static let bonjourServiceType = "_chromascan._tcp"
    static let bonjourDomain = "local."
    static let protocolVersion = 1
    static let maximumMessageSize = 16 * 1024 * 1024 // 16 MB
    static let binaryHeaderLength = 9 // 1B frameKind + 4B generation + 4B requestID
}

// MARK: - Shared Companion Enums & Snapshot

enum CompanionOperation: String, Codable, Sendable, Equatable {
    case preview
    case scan
    case export
}

enum PushEnvironment: String, Codable, Sendable, Equatable {
    case sandbox
    case production

    var opposite: PushEnvironment {
        switch self {
        case .sandbox: return .production
        case .production: return .sandbox
        }
    }
}

enum CompanionImageKind: String, Codable, Sendable, Equatable {
    case previewProxy
    case scanProxy
    case highResTile
    case photosCopy

    var frameKind: CompanionFrameKind {
        switch self {
        case .previewProxy: return .previewProxy
        case .scanProxy: return .scanProxy
        case .highResTile: return .highResTile
        case .photosCopy: return .photosCopy
        }
    }
}

enum CompanionFrameKind: UInt8, Sendable, Equatable {
    case previewProxy = 1
    case scanProxy = 2
    case highResTile = 3
    case photosCopy = 4

    var imageKind: CompanionImageKind {
        switch self {
        case .previewProxy: return .previewProxy
        case .scanProxy: return .scanProxy
        case .highResTile: return .highResTile
        case .photosCopy: return .photosCopy
        }
    }
}

struct SessionSnapshot: Codable, Equatable, Sendable {
    let scanners: [DiscoveredScanner]
    let selectedScannerID: String?
    let capabilities: ScannerCapabilities?
    let scannerStatus: ScannerStatus?
    let settings: ScanSessionSettings
    let cropRect: NormalizedCropRect
    let viewMode: CanvasViewMode
    let isBusy: Bool
    let activeOperation: CompanionOperation?
    let statusText: String
    let isErrorStatus: Bool
    let hasPreviewImage: Bool
    let hasScanImage: Bool
    let platenAspectRatio: Double
    let lastSavedFilename: String?
    let saveFolderDisplayName: String
    let outputPreviewSummary: String
    let activeImageGeneration: UInt32
    let scanPixelWidth: Int?
    let scanPixelHeight: Int?
    let scanDPI: Int?
    let isScanTrimmed: Bool

    var selectedScanner: DiscoveredScanner? {
        guard let selectedScannerID else { return nil }
        return scanners.first(where: { $0.id == selectedScannerID })
    }
}

struct CompanionImageReadyInfo: Codable, Equatable, Sendable {
    let kind: CompanionImageKind
    let generation: UInt32
    let requestID: UInt32
    let width: Int
    let height: Int
    let trueWidth: Int
    let trueHeight: Int
    let dpi: Int
    let normalizedRect: NormalizedCropRect?
    let summaryText: String
}

struct EncodedCompanionImage: Sendable {
    let info: CompanionImageReadyInfo
    let data: Data
}

// MARK: - Client -> Host Messages

enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, clientName: String, pin: String?, authToken: String?)
    case selectScanner(scannerID: String)
    case refreshScanners
    case addManualScanner(host: String, port: Int, useTLS: Bool)
    case updateSettings(patch: ScanSettingsPatch)
    case setCropRect(cropRect: NormalizedCropRect)
    case trimEmptySpace
    case setViewMode(mode: CanvasViewMode)
    case triggerPreview
    case triggerScan
    case triggerExport
    case cancel
    case requestTile(requestID: UInt32, normalizedRect: NormalizedCropRect, maxPixelWidth: Int)
    case requestPhotosCopy(requestID: UInt32, format: OutputFormat, quality: Double)
    case registerPushToken(
        deviceToken: String?,
        environment: PushEnvironment,
        enabled: Bool,
        bundleID: String? = nil,
        teamID: String? = nil,
        registrationError: String? = nil
    )
    case registerLiveActivityToken(activityPushToken: String?, environment: PushEnvironment, bundleID: String? = nil)
    case ping
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case clientName
        case pin
        case authToken
        case scannerID
        case host
        case port
        case useTLS
        case patch
        case cropRect
        case mode
        case requestID
        case normalizedRect
        case maxPixelWidth
        case format
        case quality
        case deviceToken
        case activityPushToken
        case environment
        case enabled
        case bundleID
        case teamID
        case registrationError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                clientName: try c.decode(String.self, forKey: .clientName),
                pin: try c.decodeIfPresent(String.self, forKey: .pin),
                authToken: try c.decodeIfPresent(String.self, forKey: .authToken)
            )
        case "selectScanner":
            self = .selectScanner(scannerID: try c.decode(String.self, forKey: .scannerID))
        case "refreshScanners":
            self = .refreshScanners
        case "addManualScanner":
            self = .addManualScanner(
                host: try c.decode(String.self, forKey: .host),
                port: try c.decode(Int.self, forKey: .port),
                useTLS: try c.decode(Bool.self, forKey: .useTLS)
            )
        case "updateSettings":
            self = .updateSettings(patch: try c.decode(ScanSettingsPatch.self, forKey: .patch))
        case "setCropRect":
            self = .setCropRect(cropRect: try c.decode(NormalizedCropRect.self, forKey: .cropRect))
        case "trimEmptySpace":
            self = .trimEmptySpace
        case "setViewMode":
            self = .setViewMode(mode: try c.decode(CanvasViewMode.self, forKey: .mode))
        case "triggerPreview":
            self = .triggerPreview
        case "triggerScan":
            self = .triggerScan
        case "triggerExport":
            self = .triggerExport
        case "cancel":
            self = .cancel
        case "requestTile":
            self = .requestTile(
                requestID: try c.decode(UInt32.self, forKey: .requestID),
                normalizedRect: try c.decode(NormalizedCropRect.self, forKey: .normalizedRect),
                maxPixelWidth: try c.decode(Int.self, forKey: .maxPixelWidth)
            )
        case "requestPhotosCopy":
            self = .requestPhotosCopy(
                requestID: try c.decode(UInt32.self, forKey: .requestID),
                format: try c.decode(OutputFormat.self, forKey: .format),
                quality: try c.decode(Double.self, forKey: .quality)
            )
        case "registerPushToken":
            self = .registerPushToken(
                deviceToken: try c.decodeIfPresent(String.self, forKey: .deviceToken),
                environment: try c.decode(PushEnvironment.self, forKey: .environment),
                enabled: try c.decode(Bool.self, forKey: .enabled),
                bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID),
                teamID: try c.decodeIfPresent(String.self, forKey: .teamID),
                registrationError: try c.decodeIfPresent(String.self, forKey: .registrationError)
            )
        case "registerLiveActivityToken":
            self = .registerLiveActivityToken(
                activityPushToken: try c.decodeIfPresent(String.self, forKey: .activityPushToken),
                environment: try c.decode(PushEnvironment.self, forKey: .environment),
                bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID)
            )
        case "ping":
            self = .ping
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ClientMessage type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let protocolVersion, let clientName, let pin, let authToken):
            try c.encode("hello", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(clientName, forKey: .clientName)
            try c.encodeIfPresent(pin, forKey: .pin)
            try c.encodeIfPresent(authToken, forKey: .authToken)
        case .selectScanner(let scannerID):
            try c.encode("selectScanner", forKey: .type)
            try c.encode(scannerID, forKey: .scannerID)
        case .refreshScanners:
            try c.encode("refreshScanners", forKey: .type)
        case .addManualScanner(let host, let port, let useTLS):
            try c.encode("addManualScanner", forKey: .type)
            try c.encode(host, forKey: .host)
            try c.encode(port, forKey: .port)
            try c.encode(useTLS, forKey: .useTLS)
        case .updateSettings(let patch):
            try c.encode("updateSettings", forKey: .type)
            try c.encode(patch, forKey: .patch)
        case .setCropRect(let cropRect):
            try c.encode("setCropRect", forKey: .type)
            try c.encode(cropRect, forKey: .cropRect)
        case .trimEmptySpace:
            try c.encode("trimEmptySpace", forKey: .type)
        case .setViewMode(let mode):
            try c.encode("setViewMode", forKey: .type)
            try c.encode(mode, forKey: .mode)
        case .triggerPreview:
            try c.encode("triggerPreview", forKey: .type)
        case .triggerScan:
            try c.encode("triggerScan", forKey: .type)
        case .triggerExport:
            try c.encode("triggerExport", forKey: .type)
        case .cancel:
            try c.encode("cancel", forKey: .type)
        case .requestTile(let requestID, let normalizedRect, let maxPixelWidth):
            try c.encode("requestTile", forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(normalizedRect, forKey: .normalizedRect)
            try c.encode(maxPixelWidth, forKey: .maxPixelWidth)
        case .requestPhotosCopy(let requestID, let format, let quality):
            try c.encode("requestPhotosCopy", forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(format, forKey: .format)
            try c.encode(quality, forKey: .quality)
        case .registerPushToken(let deviceToken, let environment, let enabled, let bundleID, let teamID, let registrationError):
            try c.encode("registerPushToken", forKey: .type)
            try c.encodeIfPresent(deviceToken, forKey: .deviceToken)
            try c.encode(environment, forKey: .environment)
            try c.encode(enabled, forKey: .enabled)
            try c.encodeIfPresent(bundleID, forKey: .bundleID)
            try c.encodeIfPresent(teamID, forKey: .teamID)
            try c.encodeIfPresent(registrationError, forKey: .registrationError)
        case .registerLiveActivityToken(let activityPushToken, let environment, let bundleID):
            try c.encode("registerLiveActivityToken", forKey: .type)
            try c.encodeIfPresent(activityPushToken, forKey: .activityPushToken)
            try c.encode(environment, forKey: .environment)
            try c.encodeIfPresent(bundleID, forKey: .bundleID)
        case .ping:
            try c.encode("ping", forKey: .type)
        }
    }
}

// MARK: - Host -> Client Messages

enum HostMessage: Equatable, Sendable {
    case welcome(protocolVersion: Int, hostID: String, hostName: String, authToken: String, snapshot: SessionSnapshot)
    case authRequired(hostID: String, hostName: String, reason: String?)
    case snapshot(snapshot: SessionSnapshot)
    case progress(operation: CompanionOperation, bytesReceived: Int64, expectedBytes: Int64, elapsedSeconds: Double, statusText: String, estimatedRemainingSeconds: Double? = nil)
    case imageReady(CompanionImageReadyInfo)
    case scanCompleted(filename: String, pixelWidth: Int, pixelHeight: Int, fileSizeBytes: Int64, elapsedSeconds: Double)
    case exportCompleted(filename: String, fileSizeBytes: Int64, elapsedSeconds: Double)
    case pushStatus(apnsConfigured: Bool)
    case error(title: String, message: String)
    case pong
}

extension HostMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case hostID
        case hostName
        case authToken
        case snapshot
        case reason
        case operation
        case bytesReceived
        case expectedBytes
        case elapsedSeconds
        case statusText
        case estimatedRemainingSeconds
        case kind
        case generation
        case requestID
        case width
        case height
        case trueWidth
        case trueHeight
        case dpi
        case normalizedRect
        case summaryText
        case filename
        case pixelWidth
        case pixelHeight
        case fileSizeBytes
        case apnsConfigured
        case title
        case message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                hostID: try c.decode(String.self, forKey: .hostID),
                hostName: try c.decode(String.self, forKey: .hostName),
                authToken: try c.decode(String.self, forKey: .authToken),
                snapshot: try c.decode(SessionSnapshot.self, forKey: .snapshot)
            )
        case "authRequired":
            self = .authRequired(
                hostID: try c.decode(String.self, forKey: .hostID),
                hostName: try c.decode(String.self, forKey: .hostName),
                reason: try c.decodeIfPresent(String.self, forKey: .reason)
            )
        case "snapshot":
            self = .snapshot(snapshot: try c.decode(SessionSnapshot.self, forKey: .snapshot))
        case "progress":
            self = .progress(
                operation: try c.decode(CompanionOperation.self, forKey: .operation),
                bytesReceived: try c.decode(Int64.self, forKey: .bytesReceived),
                expectedBytes: try c.decode(Int64.self, forKey: .expectedBytes),
                elapsedSeconds: try c.decode(Double.self, forKey: .elapsedSeconds),
                statusText: try c.decode(String.self, forKey: .statusText),
                estimatedRemainingSeconds: try c.decodeIfPresent(Double.self, forKey: .estimatedRemainingSeconds)
            )
        case "imageReady":
            let info = CompanionImageReadyInfo(
                kind: try c.decode(CompanionImageKind.self, forKey: .kind),
                generation: try c.decode(UInt32.self, forKey: .generation),
                requestID: try c.decode(UInt32.self, forKey: .requestID),
                width: try c.decode(Int.self, forKey: .width),
                height: try c.decode(Int.self, forKey: .height),
                trueWidth: try c.decode(Int.self, forKey: .trueWidth),
                trueHeight: try c.decode(Int.self, forKey: .trueHeight),
                dpi: try c.decode(Int.self, forKey: .dpi),
                normalizedRect: try c.decodeIfPresent(NormalizedCropRect.self, forKey: .normalizedRect),
                summaryText: try c.decode(String.self, forKey: .summaryText)
            )
            self = .imageReady(info)
        case "scanCompleted":
            self = .scanCompleted(
                filename: try c.decode(String.self, forKey: .filename),
                pixelWidth: try c.decode(Int.self, forKey: .pixelWidth),
                pixelHeight: try c.decode(Int.self, forKey: .pixelHeight),
                fileSizeBytes: try c.decode(Int64.self, forKey: .fileSizeBytes),
                elapsedSeconds: try c.decode(Double.self, forKey: .elapsedSeconds)
            )
        case "exportCompleted":
            self = .exportCompleted(
                filename: try c.decode(String.self, forKey: .filename),
                fileSizeBytes: try c.decode(Int64.self, forKey: .fileSizeBytes),
                elapsedSeconds: try c.decode(Double.self, forKey: .elapsedSeconds)
            )
        case "pushStatus":
            self = .pushStatus(apnsConfigured: try c.decode(Bool.self, forKey: .apnsConfigured))
        case "error":
            self = .error(
                title: try c.decode(String.self, forKey: .title),
                message: try c.decode(String.self, forKey: .message)
            )
        case "pong":
            self = .pong
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown HostMessage type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .welcome(let protocolVersion, let hostID, let hostName, let authToken, let snapshot):
            try c.encode("welcome", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(hostID, forKey: .hostID)
            try c.encode(hostName, forKey: .hostName)
            try c.encode(authToken, forKey: .authToken)
            try c.encode(snapshot, forKey: .snapshot)
        case .authRequired(let hostID, let hostName, let reason):
            try c.encode("authRequired", forKey: .type)
            try c.encode(hostID, forKey: .hostID)
            try c.encode(hostName, forKey: .hostName)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .snapshot(let snapshot):
            try c.encode("snapshot", forKey: .type)
            try c.encode(snapshot, forKey: .snapshot)
        case .progress(let operation, let bytesReceived, let expectedBytes, let elapsedSeconds, let statusText, let estimatedRemainingSeconds):
            try c.encode("progress", forKey: .type)
            try c.encode(operation, forKey: .operation)
            try c.encode(bytesReceived, forKey: .bytesReceived)
            try c.encode(expectedBytes, forKey: .expectedBytes)
            try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
            try c.encode(statusText, forKey: .statusText)
            try c.encodeIfPresent(estimatedRemainingSeconds, forKey: .estimatedRemainingSeconds)
        case .imageReady(let info):
            try c.encode("imageReady", forKey: .type)
            try c.encode(info.kind, forKey: .kind)
            try c.encode(info.generation, forKey: .generation)
            try c.encode(info.requestID, forKey: .requestID)
            try c.encode(info.width, forKey: .width)
            try c.encode(info.height, forKey: .height)
            try c.encode(info.trueWidth, forKey: .trueWidth)
            try c.encode(info.trueHeight, forKey: .trueHeight)
            try c.encode(info.dpi, forKey: .dpi)
            try c.encodeIfPresent(info.normalizedRect, forKey: .normalizedRect)
            try c.encode(info.summaryText, forKey: .summaryText)
        case .scanCompleted(let filename, let pixelWidth, let pixelHeight, let fileSizeBytes, let elapsedSeconds):
            try c.encode("scanCompleted", forKey: .type)
            try c.encode(filename, forKey: .filename)
            try c.encode(pixelWidth, forKey: .pixelWidth)
            try c.encode(pixelHeight, forKey: .pixelHeight)
            try c.encode(fileSizeBytes, forKey: .fileSizeBytes)
            try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
        case .exportCompleted(let filename, let fileSizeBytes, let elapsedSeconds):
            try c.encode("exportCompleted", forKey: .type)
            try c.encode(filename, forKey: .filename)
            try c.encode(fileSizeBytes, forKey: .fileSizeBytes)
            try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
        case .pushStatus(let apnsConfigured):
            try c.encode("pushStatus", forKey: .type)
            try c.encode(apnsConfigured, forKey: .apnsConfigured)
        case .error(let title, let message):
            try c.encode("error", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(message, forKey: .message)
        case .pong:
            try c.encode("pong", forKey: .type)
        }
    }
}

// MARK: - Binary Image Frame Pack / Unpack

enum CompanionBinaryFrameError: Error, LocalizedError, Equatable {
    case truncatedHeader(Int)
    case unknownFrameKind(UInt8)
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .truncatedHeader(let len):
            return "Binary frame too short (\(len) bytes; need at least \(CompanionConstants.binaryHeaderLength))."
        case .unknownFrameKind(let raw):
            return "Unknown companion binary frame kind: \(raw)."
        case .emptyPayload:
            return "Binary frame contained no image payload."
        }
    }
}

struct CompanionBinaryFrame: Equatable, Sendable {
    let kind: CompanionFrameKind
    let generation: UInt32
    let requestID: UInt32
    let payload: Data

    func pack() -> Data {
        var out = Data(capacity: CompanionConstants.binaryHeaderLength + payload.count)
        out.append(kind.rawValue)
        var genBE = generation.bigEndian
        withUnsafeBytes(of: &genBE) { out.append(contentsOf: $0) }
        var reqBE = requestID.bigEndian
        withUnsafeBytes(of: &reqBE) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func unpack(_ data: Data) throws -> CompanionBinaryFrame {
        guard data.count >= CompanionConstants.binaryHeaderLength else {
            throw CompanionBinaryFrameError.truncatedHeader(data.count)
        }
        let kindByte = data[data.startIndex]
        guard let kind = CompanionFrameKind(rawValue: kindByte) else {
            throw CompanionBinaryFrameError.unknownFrameKind(kindByte)
        }
        let payloadStart = data.index(data.startIndex, offsetBy: CompanionConstants.binaryHeaderLength)
        guard payloadStart < data.endIndex else {
            throw CompanionBinaryFrameError.emptyPayload
        }

        let gen = readUInt32BigEndian(from: data, offset: 1)
        let reqID = readUInt32BigEndian(from: data, offset: 5)
        let payload = Data(data[payloadStart...])
        return CompanionBinaryFrame(kind: kind, generation: gen, requestID: reqID, payload: payload)
    }

    private static func readUInt32BigEndian(from data: Data, offset: Int) -> UInt32 {
        let i0 = data.index(data.startIndex, offsetBy: offset)
        let b0 = UInt32(data[i0])
        let b1 = UInt32(data[data.index(after: i0)])
        let b2 = UInt32(data[data.index(i0, offsetBy: 2)])
        let b3 = UInt32(data[data.index(i0, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
