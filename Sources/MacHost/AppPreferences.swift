import Foundation
import Security

struct PairedCompanionDevice: Codable, Equatable, Identifiable, Sendable {
    let token: String
    var clientName: String
    let pairedAt: Date
    var lastSeenAt: Date
    var apnsDeviceToken: String?
    var apnsEnvironment: PushEnvironment?
    var apnsEnvironmentVerified: Bool
    var apnsBundleID: String?
    var apnsTeamID: String?
    var apnsRegistrationError: String?
    var pushNotificationsEnabled: Bool

    var id: String { token }

    init(
        token: String,
        clientName: String,
        pairedAt: Date,
        lastSeenAt: Date,
        apnsDeviceToken: String? = nil,
        apnsEnvironment: PushEnvironment? = nil,
        apnsEnvironmentVerified: Bool = false,
        apnsBundleID: String? = nil,
        apnsTeamID: String? = nil,
        apnsRegistrationError: String? = nil,
        pushNotificationsEnabled: Bool = true
    ) {
        self.token = token
        self.clientName = clientName
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.apnsDeviceToken = apnsDeviceToken
        self.apnsEnvironment = apnsEnvironment
        self.apnsEnvironmentVerified = apnsEnvironmentVerified
        self.apnsBundleID = apnsBundleID
        self.apnsTeamID = apnsTeamID
        self.apnsRegistrationError = apnsRegistrationError
        self.pushNotificationsEnabled = pushNotificationsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case clientName
        case pairedAt
        case lastSeenAt
        case apnsDeviceToken
        case apnsEnvironment
        case apnsEnvironmentVerified
        case apnsBundleID
        case apnsTeamID
        case apnsRegistrationError
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
        self.apnsEnvironmentVerified = try c.decodeIfPresent(Bool.self, forKey: .apnsEnvironmentVerified) ?? false
        self.apnsBundleID = try c.decodeIfPresent(String.self, forKey: .apnsBundleID)
        self.apnsTeamID = try c.decodeIfPresent(String.self, forKey: .apnsTeamID)
        self.apnsRegistrationError = try c.decodeIfPresent(String.self, forKey: .apnsRegistrationError)
        self.pushNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushNotificationsEnabled) ?? true
    }
}

enum APNsSecretLoadResult: Equatable, Sendable {
    case found(String)
    case notFound
    case unavailable(OSStatus)
}

protocol APNsSecretStoring: Sendable {
    func loadPrivateKeyResult() -> APNsSecretLoadResult
    @discardableResult
    func savePrivateKeyPEM(_ pem: String?) -> Bool
}

extension APNsSecretStoring {
    func loadPrivateKeyPEM() -> String? {
        if case .found(let pem) = loadPrivateKeyResult() {
            return pem
        }
        return nil
    }
}

struct KeychainAPNsSecretStore: APNsSecretStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.chromascan.apns.authkey",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    func loadPrivateKeyResult() -> APNsSecretLoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let pem = String(data: data, encoding: .utf8),
           !pem.isEmpty {
            return .found(pem)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        return .unavailable(status)
    }

    @discardableResult
    func savePrivateKeyPEM(_ pem: String?) -> Bool {
        let clean = pem?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let clean, !clean.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = clean.data(using: .utf8) else {
            return false
        }

        // Update existing item in-place first so a failed write never erases a working key.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}

final class InMemoryAPNsSecretStore: APNsSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPEM: String?
    private var simulatedUnavailableStatus: OSStatus?

    init(initialPEM: String? = nil, simulatedUnavailableStatus: OSStatus? = nil) {
        self.storedPEM = initialPEM
        self.simulatedUnavailableStatus = simulatedUnavailableStatus
    }

    func loadPrivateKeyResult() -> APNsSecretLoadResult {
        lock.lock()
        defer { lock.unlock() }
        if let status = simulatedUnavailableStatus {
            return .unavailable(status)
        }
        if let storedPEM, !storedPEM.isEmpty {
            return .found(storedPEM)
        }
        return .notFound
    }

    @discardableResult
    func savePrivateKeyPEM(_ pem: String?) -> Bool {
        let clean = pem?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if simulatedUnavailableStatus != nil {
            return false
        }
        storedPEM = (clean?.isEmpty == false) ? clean : nil
        return true
    }
}

@MainActor
final class AppPreferences {
    private let defaults: UserDefaults
    private let apnsSearchDirectoryURLs: [URL]
    private let secretStore: any APNsSecretStoring
    private let buildTeamID: String?
    private let buildCompanionBundleID: String?
    private var cachedLocalAPNsConfig: APNsLocalDirectoryConfig?

    init(
        defaults: UserDefaults = .standard,
        apnsDirectoryURL: URL? = nil,
        apnsSearchDirectoryURLs: [URL]? = nil,
        secretStore: (any APNsSecretStoring)? = nil,
        buildTeamID: String? = nil,
        buildCompanionBundleID: String? = nil
    ) {
        self.defaults = defaults
        let isStandard = (defaults === UserDefaults.standard)
        if let apnsSearchDirectoryURLs {
            self.apnsSearchDirectoryURLs = apnsSearchDirectoryURLs
        } else if let apnsDirectoryURL {
            self.apnsSearchDirectoryURLs = [apnsDirectoryURL]
        } else if isStandard {
            self.apnsSearchDirectoryURLs = APNsLocalDirectoryConfig.defaultSearchDirectoryURLs
        } else {
            self.apnsSearchDirectoryURLs = []
        }

        if let secretStore {
            self.secretStore = secretStore
        } else if isStandard {
            self.secretStore = KeychainAPNsSecretStore()
        } else {
            self.secretStore = InMemoryAPNsSecretStore()
        }

        self.buildTeamID = Self.sanitizedBuildSetting(
            buildTeamID ?? (isStandard ? Bundle.main.object(forInfoDictionaryKey: "ChromaScanTeamID") as? String : nil)
        )
        self.buildCompanionBundleID = Self.sanitizedBuildSetting(
            buildCompanionBundleID ?? (isStandard ? Bundle.main.object(forInfoDictionaryKey: "ChromaScanCompanionBundleID") as? String : nil)
        )
        self.cachedLocalAPNsConfig = APNsLocalDirectoryConfig.discoverFirst(in: self.apnsSearchDirectoryURLs)
        migrateLegacyUserDefaultsAPNsKeyIfNeeded()
    }

    private func migrateLegacyUserDefaultsAPNsKeyIfNeeded() {
        guard let legacyPEM = defaults.string(forKey: Key.apnsPrivateKeyFallback)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyPEM.isEmpty else {
            return
        }
        switch secretStore.loadPrivateKeyResult() {
        case .found:
            // Keychain already holds a key; safe to purge legacy plaintext copy.
            defaults.removeObject(forKey: Key.apnsPrivateKeyFallback)
        case .notFound:
            if secretStore.savePrivateKeyPEM(legacyPEM) {
                defaults.removeObject(forKey: Key.apnsPrivateKeyFallback)
            }
        case .unavailable:
            // Leave legacy value untouched until Keychain becomes accessible.
            break
        }
    }

    private static func sanitizedBuildSetting(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
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
        bundleID: String? = nil,
        teamID: String? = nil,
        registrationError: String? = nil
    ) {
        var list = pairedDevices
        guard let idx = list.firstIndex(where: { $0.token == authToken }) else { return }
        list[idx].pushNotificationsEnabled = enabled
        if let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            list[idx].apnsBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let teamID = Self.sanitizedBuildSetting(teamID) {
            list[idx].apnsTeamID = teamID
        }

        let cleanToken = deviceToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanError = registrationError?.trimmingCharacters(in: .whitespacesAndNewlines)

        if !enabled {
            list[idx].apnsDeviceToken = nil
            list[idx].apnsEnvironment = environment
            list[idx].apnsEnvironmentVerified = false
            list[idx].apnsRegistrationError = nil
        } else if let cleanError, !cleanError.isEmpty {
            list[idx].apnsDeviceToken = nil
            list[idx].apnsEnvironment = environment
            list[idx].apnsEnvironmentVerified = false
            list[idx].apnsRegistrationError = cleanError
        } else if let cleanToken, !cleanToken.isEmpty {
            let tokenChanged = (list[idx].apnsDeviceToken != cleanToken)
            list[idx].apnsDeviceToken = cleanToken
            if tokenChanged || !list[idx].apnsEnvironmentVerified {
                list[idx].apnsEnvironment = environment
                if tokenChanged {
                    list[idx].apnsEnvironmentVerified = false
                }
            }
            list[idx].apnsRegistrationError = nil
        } else {
            if !list[idx].apnsEnvironmentVerified {
                list[idx].apnsEnvironment = environment
            }
        }
        list[idx].lastSeenAt = Date()
        pairedDevices = list
    }

    func updateAPNsEnvironment(_ environment: PushEnvironment, forDeviceToken apnsDeviceToken: String) {
        var list = pairedDevices
        var changed = false
        for idx in list.indices where list[idx].apnsDeviceToken == apnsDeviceToken {
            if list[idx].apnsEnvironment != environment || !list[idx].apnsEnvironmentVerified {
                list[idx].apnsEnvironment = environment
                list[idx].apnsEnvironmentVerified = true
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
            list[idx].apnsEnvironmentVerified = false
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
        cachedLocalAPNsConfig
    }

    func refreshLocalAPNsConfig() {
        cachedLocalAPNsConfig = APNsLocalDirectoryConfig.discoverFirst(in: apnsSearchDirectoryURLs)
    }

    var inferredDeviceBundleID: String? {
        pushEligibleDevices.compactMap(\.apnsBundleID).first(where: { !$0.isEmpty })
            ?? pairedDevices.filter(\.pushNotificationsEnabled).compactMap(\.apnsBundleID).first(where: { !$0.isEmpty })
    }

    /// Returns a paired device Team ID only when push-enabled devices with a reported team
    /// agree unambiguously on one Team ID (never letting an opted-out or mismatched device hijack the issuer).
    var unambiguousDeviceTeamID: String? {
        let candidates = Set(
            pairedDevices
                .filter { $0.pushNotificationsEnabled && ($0.apnsDeviceToken?.isEmpty == false) }
                .compactMap(\.apnsTeamID)
                .filter { !$0.isEmpty }
        )
        return candidates.count == 1 ? candidates.first : nil
    }

    var mismatchedTeamDeviceNames: [String] {
        guard let activeTeam = apnsConfiguration?.teamID, !activeTeam.isEmpty else { return [] }
        return pushEligibleDevices.compactMap { device in
            guard let devTeam = device.apnsTeamID, !devTeam.isEmpty else { return nil }
            return devTeam.caseInsensitiveCompare(activeTeam) == .orderedSame ? nil : device.clientName
        }
    }

    var latestDevicePushRegistrationError: String? {
        pairedDevices
            .filter { $0.pushNotificationsEnabled && ($0.apnsDeviceToken?.isEmpty ?? true) }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .compactMap(\.apnsRegistrationError)
            .first(where: { !$0.isEmpty })
    }

    var apnsKeychainUnavailableStatus: OSStatus? {
        if case .unavailable(let status) = secretStore.loadPrivateKeyResult() {
            return status
        }
        return nil
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
            if let buildBundle = buildCompanionBundleID {
                return buildBundle
            }
            return Self.defaultIOSBundleID
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apnsBundleID) }
    }

    /// Resolves Key ID from the same source as the active private key (never mixing Keychain
    /// metadata with a directory `.p8` file).
    var effectiveAPNsKeyID: String {
        switch secretStore.loadPrivateKeyResult() {
        case .found:
            return apnsKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        case .unavailable:
            return apnsKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        case .notFound:
            if let dirKeyID = discoveredLocalAPNsConfig?.keyID, !dirKeyID.isEmpty {
                return dirKeyID
            }
            return apnsKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Issuer Team ID precedence:
    /// 1. Explicit Team ID configured with the active key source (Keychain prefs or directory apns.env)
    /// 2. Local signed build's Team ID (`Info.plist` `ChromaScanTeamID`)
    /// 3. Unambiguous paired push-eligible device Team ID
    var effectiveAPNsTeamID: String {
        switch secretStore.loadPrivateKeyResult() {
        case .found, .unavailable:
            let stored = apnsTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty { return stored }
            if let buildTeamID { return buildTeamID }
            return unambiguousDeviceTeamID ?? ""
        case .notFound:
            if let discovered = discoveredLocalAPNsConfig?.teamID, !discovered.isEmpty {
                return discovered
            }
            if let buildTeamID { return buildTeamID }
            if let deviceTeam = unambiguousDeviceTeamID {
                return deviceTeam
            }
            return apnsTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var effectiveAPNsPrivateKeyPEM: String? {
        switch secretStore.loadPrivateKeyResult() {
        case .found(let stored):
            return stored
        case .unavailable:
            return nil
        case .notFound:
            return discoveredLocalAPNsConfig?.privateKeyPEM
        }
    }

    var isUsingLocalAPNsDirectoryKey: Bool {
        if case .notFound = secretStore.loadPrivateKeyResult() {
            return discoveredLocalAPNsConfig?.privateKeyPEM != nil
        }
        return false
    }

    var apnsPrivateKeyPEM: String? {
        get {
            secretStore.loadPrivateKeyPEM()
        }
        set {
            _ = saveAPNsPrivateKeyPEM(newValue)
        }
    }

    @discardableResult
    func saveAPNsPrivateKeyPEM(_ pem: String?) -> Bool {
        let saved = secretStore.savePrivateKeyPEM(pem)
        if saved {
            defaults.removeObject(forKey: Key.apnsPrivateKeyFallback)
        }
        return saved
    }

    var apnsConfiguration: APNsConfiguration? {
        switch secretStore.loadPrivateKeyResult() {
        case .found(let pem):
            let config = APNsConfiguration(
                keyID: apnsKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
                teamID: effectiveAPNsTeamID,
                bundleID: apnsBundleID,
                privateKeyPEM: pem
            )
            return config.isComplete ? config : nil
        case .unavailable:
            return nil
        case .notFound:
            guard let local = discoveredLocalAPNsConfig,
                  local.configurationError == nil,
                  let pem = local.privateKeyPEM, !pem.isEmpty,
                  let keyID = local.keyID, !keyID.isEmpty else {
                return nil
            }
            let config = APNsConfiguration(
                keyID: keyID,
                teamID: effectiveAPNsTeamID,
                bundleID: apnsBundleID,
                privateKeyPEM: pem
            )
            return config.isComplete ? config : nil
        }
    }

    var isAPNsConfigured: Bool {
        apnsConfiguration != nil
    }

    @discardableResult
    func clearAPNsConfiguration() -> Bool {
        let clearedKey = saveAPNsPrivateKeyPEM(nil)
        if clearedKey {
            apnsKeyID = ""
            apnsTeamID = ""
            apnsBundleID = ""
        }
        return clearedKey
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
