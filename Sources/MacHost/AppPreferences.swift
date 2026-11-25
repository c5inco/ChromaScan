import Foundation
import Security

struct PairedCompanionDevice: Codable, Equatable, Identifiable, Sendable {
    let token: String
    var clientName: String
    let pairedAt: Date
    var lastSeenAt: Date
    var apnsDeviceToken: String?
    var apnsEnvironment: PushEnvironment?
    var apnsBundleID: String?
    var pushNotificationsEnabled: Bool

    var id: String { token }

    init(
        token: String,
        clientName: String,
        pairedAt: Date,
        lastSeenAt: Date,
        apnsDeviceToken: String? = nil,
        apnsEnvironment: PushEnvironment? = nil,
        apnsBundleID: String? = nil,
        pushNotificationsEnabled: Bool = true
    ) {
        self.token = token
        self.clientName = clientName
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.apnsDeviceToken = apnsDeviceToken
        self.apnsEnvironment = apnsEnvironment
        self.apnsBundleID = apnsBundleID
        self.pushNotificationsEnabled = pushNotificationsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case clientName
        case pairedAt
        case lastSeenAt
        case apnsDeviceToken
        case apnsEnvironment
        case apnsBundleID
        case pushNotificationsEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try c.decode(String.self, forKey: .token)
        self.clientName = try c.decode(String.self, forKey: .clientName)
        self.pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        self.lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        self.apnsDeviceToken = try c.decodeIfPresent(String.self, forKey: .apnsDeviceToken)
        self.apnsEnvironment = try c.decodeIfPresent(PushEnvironment.self, forKey: .apnsEnvironment)
        self.apnsBundleID = try c.decodeIfPresent(String.self, forKey: .apnsBundleID)
        self.pushNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushNotificationsEnabled) ?? true
    }
}

@MainActor
final class AppPreferences {
    private let defaults: UserDefaults
    private let apnsDirectoryURL: URL?

    init(
        defaults: UserDefaults = .standard,
        apnsDirectoryURL: URL? = nil
    ) {
        self.defaults = defaults
        if let apnsDirectoryURL {
            self.apnsDirectoryURL = apnsDirectoryURL
        } else if defaults === UserDefaults.standard {
            self.apnsDirectoryURL = APNsLocalDirectoryConfig.defaultDirectoryURL
        } else {
            self.apnsDirectoryURL = nil
        }
    }

    private enum Key {
        static let resolution = "scan.resolution"
        static let colorMode = "scan.colorMode"
        static let intent = "scan.intent"
        static let transferFormat = "scan.transferFormat"
        static let rotation = "scan.rotation"
        static let autoTrimEmptySpace = "scan.autoTrimEmptySpace"
        static let colorProfile = "output.colorProfile"
        static let outputFormat = "output.format"
        static let quality = "output.quality"
        static let saveFolderPath = "output.saveFolderPath"
        static let baseFilename = "output.baseFilename"
        static let autoIncrement = "output.autoIncrement"
        static let companionServerEnabled = "companion.serverEnabled"
        static let pairingPIN = "companion.pairingPIN"
        static let companionHostID = "companion.hostID"
        static let pairedDevices = "companion.pairedDevices"
        static let keepRunningInMenuBar = "companion.keepRunningInMenuBar"
        static let apnsKeyID = "companion.apns.keyID"
        static let apnsTeamID = "companion.apns.teamID"
        static let apnsBundleID = "companion.apns.bundleID"
        static let apnsPrivateKeyFallback = "companion.apns.privateKeyPEM"
    }

    private static let apnsKeychainService = "com.chromascan.apns.authkey"
    private static let apnsKeychainAccount = "default"
    private static let defaultIOSBundleID = "com.chromascan.remote"

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

    var autoTrimEmptySpace: Bool {
        get { defaults.bool(forKey: Key.autoTrimEmptySpace) }
        set { defaults.set(newValue, forKey: Key.autoTrimEmptySpace) }
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

    // MARK: - Companion Preferences

    var companionServerEnabled: Bool {
        get {
            if defaults.object(forKey: Key.companionServerEnabled) == nil { return true }
            return defaults.bool(forKey: Key.companionServerEnabled)
        }
        set { defaults.set(newValue, forKey: Key.companionServerEnabled) }
    }

    var keepRunningInMenuBar: Bool {
        get { defaults.bool(forKey: Key.keepRunningInMenuBar) }
        set { defaults.set(newValue, forKey: Key.keepRunningInMenuBar) }
    }

    var companionHostID: String {
        if let existing = defaults.string(forKey: Key.companionHostID), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Key.companionHostID)
        return generated
    }

    var pairingPIN: String {
        get {
            if let existing = defaults.string(forKey: Key.pairingPIN),
               existing.count == 6,
               existing.allSatisfy(\.isNumber) {
                return existing
            }
            return regeneratePairingPIN()
        }
        set {
            defaults.set(newValue, forKey: Key.pairingPIN)
        }
    }

    @discardableResult
    func regeneratePairingPIN() -> String {
        var randomValue: UInt32 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &randomValue)
        let pinInt: UInt32
        if status == errSecSuccess {
            pinInt = randomValue % 1_000_000
        } else {
            pinInt = UInt32.random(in: 0..<1_000_000)
        }
        let formatted = String(format: "%06u", pinInt)
        defaults.set(formatted, forKey: Key.pairingPIN)
        return formatted
    }

    var pairedDevices: [PairedCompanionDevice] {
        get {
            guard let data = defaults.data(forKey: Key.pairedDevices),
                  let decoded = try? JSONDecoder().decode([PairedCompanionDevice].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                defaults.set(encoded, forKey: Key.pairedDevices)
            }
        }
    }

    func mintPairedDevice(clientName: String) -> PairedCompanionDevice {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let device = PairedCompanionDevice(
            token: token,
            clientName: clientName,
            pairedAt: now,
            lastSeenAt: now
        )
        var list = pairedDevices
        list.append(device)
        pairedDevices = list
        return device
    }

    func validateToken(_ token: String, clientName: String?) -> Bool {
        var list = pairedDevices
        guard let idx = list.firstIndex(where: { $0.token == token }) else {
            return false
        }
        list[idx].lastSeenAt = Date()
        if let clientName, !clientName.isEmpty {
            list[idx].clientName = clientName
        }
        pairedDevices = list
        return true
    }

    func revokeAllPairedDevices() {
        pairedDevices = []
    }

    func updatePushRegistration(
        forAuthToken authToken: String,
        deviceToken: String?,
        environment: PushEnvironment,
        enabled: Bool,
        bundleID: String? = nil
    ) {
        var list = pairedDevices
        guard let idx = list.firstIndex(where: { $0.token == authToken }) else { return }
        list[idx].pushNotificationsEnabled = enabled
        list[idx].apnsEnvironment = environment
        if let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list[idx].apnsBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let deviceToken, !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list[idx].apnsDeviceToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !enabled {
            list[idx].apnsDeviceToken = nil
        }
        list[idx].lastSeenAt = Date()
        pairedDevices = list
    }

    func updateAPNsEnvironment(_ environment: PushEnvironment, forDeviceToken apnsDeviceToken: String) {
        var list = pairedDevices
        var changed = false
        for idx in list.indices where list[idx].apnsDeviceToken == apnsDeviceToken {
            if list[idx].apnsEnvironment != environment {
                list[idx].apnsEnvironment = environment
                changed = true
            }
        }
        if changed {
            pairedDevices = list
        }
    }

    func clearAPNsToken(_ apnsDeviceToken: String) {
        var list = pairedDevices
        var changed = false
        for idx in list.indices where list[idx].apnsDeviceToken == apnsDeviceToken {
            list[idx].apnsDeviceToken = nil
            changed = true
        }
        if changed {
            pairedDevices = list
        }
    }

    var pushEligibleDevices: [PairedCompanionDevice] {
        pairedDevices.filter {
            $0.pushNotificationsEnabled
                && ($0.apnsDeviceToken?.isEmpty == false)
        }
    }

    // MARK: - APNs Push Configuration (Direct Mac -> APNs)

    var discoveredLocalAPNsConfig: APNsLocalDirectoryConfig? {
        guard let apnsDirectoryURL else { return nil }
        return APNsLocalDirectoryConfig.discover(in: apnsDirectoryURL)
    }

    var inferredDeviceBundleID: String? {
        pairedDevices.compactMap(\.apnsBundleID).first(where: { !$0.isEmpty })
    }

    var apnsKeyID: String {
        get { defaults.string(forKey: Key.apnsKeyID) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apnsKeyID) }
    }

    var apnsTeamID: String {
        get { defaults.string(forKey: Key.apnsTeamID) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apnsTeamID) }
    }

    var apnsBundleID: String {
        get {
            let stored = defaults.string(forKey: Key.apnsBundleID) ?? ""
            if !stored.isEmpty { return stored }
            if let discovered = discoveredLocalAPNsConfig?.bundleID, !discovered.isEmpty {
                return discovered
            }
            if let deviceBundle = inferredDeviceBundleID {
                return deviceBundle
            }
            return Self.defaultIOSBundleID
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apnsBundleID) }
    }

    var effectiveAPNsKeyID: String {
        let stored = apnsKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return discoveredLocalAPNsConfig?.keyID ?? ""
    }

    var effectiveAPNsTeamID: String {
        let stored = apnsTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return discoveredLocalAPNsConfig?.teamID ?? ""
    }

    var effectiveAPNsPrivateKeyPEM: String? {
        if let stored = apnsPrivateKeyPEM, !stored.isEmpty {
            return stored
        }
        return discoveredLocalAPNsConfig?.privateKeyPEM
    }

    var isUsingLocalAPNsDirectoryKey: Bool {
        apnsPrivateKeyPEM == nil && discoveredLocalAPNsConfig?.privateKeyPEM != nil
    }

    var apnsPrivateKeyPEM: String? {
        get {
            if defaults === UserDefaults.standard {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.apnsKeychainService,
                    kSecAttrAccount as String: Self.apnsKeychainAccount,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess,
                   let data = result as? Data,
                   let pem = String(data: data, encoding: .utf8),
                   !pem.isEmpty {
                    return pem
                }
            }
            let fallback = defaults.string(forKey: Key.apnsPrivateKeyFallback)
            return (fallback?.isEmpty == false) ? fallback : nil
        }
        set {
            let clean = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if defaults === UserDefaults.standard {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.apnsKeychainService,
                    kSecAttrAccount as String: Self.apnsKeychainAccount
                ]
                SecItemDelete(deleteQuery as CFDictionary)
                if let clean, !clean.isEmpty, let data = clean.data(using: .utf8) {
                    var addQuery = deleteQuery
                    addQuery[kSecValueData as String] = data
                    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    let status = SecItemAdd(addQuery as CFDictionary, nil)
                    if status == errSecSuccess {
                        defaults.removeObject(forKey: Key.apnsPrivateKeyFallback)
                        return
                    }
                } else {
                    defaults.removeObject(forKey: Key.apnsPrivateKeyFallback)
                    return
                }
            }

            if let clean, !clean.isEmpty {
                defaults.set(clean, forKey: Key.apnsPrivateKeyFallback)
            } else {
                defaults.removeObject(forKey: Key.apnsPrivateKeyFallback)
            }
        }
    }

    var apnsConfiguration: APNsConfiguration? {
        guard let pem = effectiveAPNsPrivateKeyPEM, !pem.isEmpty else { return nil }
        let config = APNsConfiguration(
            keyID: effectiveAPNsKeyID,
            teamID: effectiveAPNsTeamID,
            bundleID: apnsBundleID,
            privateKeyPEM: pem
        )
        return config.isComplete ? config : nil
    }

    var isAPNsConfigured: Bool {
        apnsConfiguration != nil
    }

    func clearAPNsConfiguration() {
        apnsKeyID = ""
        apnsTeamID = ""
        apnsBundleID = ""
        apnsPrivateKeyPEM = nil
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
