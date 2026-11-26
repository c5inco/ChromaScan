import Foundation
import CryptoKit
import OSLog

private let apnsLog = Logger(subsystem: "com.chromascan.apns", category: "push")

// MARK: - APNs Configuration & Payload

struct APNsConfiguration: Equatable, Sendable {
    let keyID: String
    let teamID: String
    let bundleID: String
    let privateKeyPEM: String

    var isComplete: Bool {
        !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func validatePrivateKeyPEM(_ pem: String) throws -> P256.Signing.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
    }

    /// Extracts Apple's 10-character Key ID from default downloaded filenames like `AuthKey_9A8B7C6D5E.p8`.
    static func extractKeyID(fromFilename filename: String) -> String? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("AuthKey_") else { return nil }
        let candidate = String(stem.dropFirst("AuthKey_".count))
        guard candidate.count == 10, candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return candidate
    }
}

/// Optional local-machine APNs config discovered from `~/.config/chromascan/apns/` (preferred)
/// or `~/.apns/` (legacy fallback), e.g. `AuthKey_<KEYID>.p8` + optional `apns.env`.
/// Keeps private keys strictly outside git while enabling zero-click setup across rebuilds.
struct APNsLocalDirectoryConfig: Equatable, Sendable {
    let keyID: String?
    let teamID: String?
    let bundleID: String?
    let privateKeyPEM: String?
    let keyFilename: String?
    let sourceDirectoryDisplay: String?
    let configurationError: String?

    init(
        keyID: String?,
        teamID: String?,
        bundleID: String?,
        privateKeyPEM: String?,
        keyFilename: String?,
        sourceDirectoryDisplay: String? = nil,
        configurationError: String? = nil
    ) {
        self.keyID = keyID
        self.teamID = teamID
        self.bundleID = bundleID
        self.privateKeyPEM = privateKeyPEM
        self.keyFilename = keyFilename
        self.sourceDirectoryDisplay = sourceDirectoryDisplay
        self.configurationError = configurationError
    }

    static var appConfigDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("chromascan", isDirectory: true)
            .appendingPathComponent("apns", isDirectory: true)
    }

    static var legacyDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apns", isDirectory: true)
    }

    static var defaultDirectoryURL: URL {
        appConfigDirectoryURL
    }

    static var defaultSearchDirectoryURLs: [URL] {
        [appConfigDirectoryURL, legacyDirectoryURL]
    }

    static func discoverFirst(in directories: [URL] = defaultSearchDirectoryURLs) -> APNsLocalDirectoryConfig? {
        var metadataOnlyFallback: APNsLocalDirectoryConfig?
        for directory in directories {
            guard let found = discover(in: directory) else { continue }
            if found.privateKeyPEM != nil || found.configurationError != nil {
                return found
            }
            if metadataOnlyFallback == nil {
                metadataOnlyFallback = found
            }
        }
        return metadataOnlyFallback
    }

    static func displayPath(for directoryURL: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let standardized = directoryURL.standardizedFileURL.path
        if standardized == home {
            return "~"
        }
        if standardized.hasPrefix(home + "/") {
            return "~" + String(standardized.dropFirst(home.count))
        }
        return standardized
    }

    static func discover(in directoryURL: URL = defaultDirectoryURL) -> APNsLocalDirectoryConfig? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let displayDir = displayPath(for: directoryURL)

        // 1. Parse optional env file (`apns.env` or `config.env`)
        var envValues: [String: String] = [:]
        for envName in ["apns.env", "config.env"] {
            let envURL = directoryURL.appendingPathComponent(envName)
            if let text = try? String(contentsOf: envURL, encoding: .utf8) {
                envValues = parseEnvFile(text)
                break
            }
        }

        let configuredKeyFile = firstNonEmpty(envValues["APNS_KEY_FILE"], envValues["KEY_FILE"])
        let configuredKeyID = firstNonEmpty(envValues["APNS_KEY_ID"], envValues["KEY_ID"])
        let teamID = firstNonEmpty(envValues["APNS_TEAM_ID"], envValues["TEAM_ID"])
        let bundleID = firstNonEmpty(envValues["APNS_BUNDLE_ID"], envValues["BUNDLE_ID"])

        // 2. Discover valid .p8 private keys in directory
        let entries = (try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let p8Files = entries
            .filter { $0.pathExtension.lowercased() == "p8" }
            .sorted { lhs, rhs in
                let lAuth = lhs.lastPathComponent.hasPrefix("AuthKey_")
                let rAuth = rhs.lastPathComponent.hasPrefix("AuthKey_")
                if lAuth != rAuth { return lAuth }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }

        var loadedPEM: String?
        var loadedFilename: String?
        var filenameKeyID: String?
        var configError: String?

        func loadValidKey(at fileURL: URL) -> (pem: String, filename: String, extractedKeyID: String?)? {
            guard let pem = try? String(contentsOf: fileURL, encoding: .utf8),
                  (try? APNsConfiguration.validatePrivateKeyPEM(pem)) != nil else {
                return nil
            }
            return (
                pem: pem.trimmingCharacters(in: .whitespacesAndNewlines),
                filename: fileURL.lastPathComponent,
                extractedKeyID: APNsConfiguration.extractKeyID(fromFilename: fileURL.lastPathComponent)
            )
        }

        if let configuredKeyFile {
            let safeName = URL(fileURLWithPath: configuredKeyFile).lastPathComponent
            if safeName != configuredKeyFile || safeName.isEmpty || safeName == "." || safeName == ".." {
                configError = "Invalid APNS_KEY_FILE '\(configuredKeyFile)' in \(displayDir)/apns.env."
            } else {
                let targetURL = directoryURL.appendingPathComponent(safeName)
                if let key = loadValidKey(at: targetURL) {
                    if let configuredKeyID,
                       let extracted = key.extractedKeyID,
                       extracted.caseInsensitiveCompare(configuredKeyID) != .orderedSame {
                        configError = "APNS_KEY_ID (\(configuredKeyID)) does not match \(safeName) in \(displayDir)."
                    } else {
                        loadedPEM = key.pem
                        loadedFilename = key.filename
                        filenameKeyID = key.extractedKeyID
                    }
                } else {
                    configError = "Configured APNs key \(safeName) is missing or invalid in \(displayDir)."
                }
            }
        } else if let configuredKeyID {
            let validKeys = p8Files.compactMap { loadValidKey(at: $0) }
            if let exactMatch = validKeys.first(where: {
                $0.extractedKeyID?.caseInsensitiveCompare(configuredKeyID) == .orderedSame
            }) {
                loadedPEM = exactMatch.pem
                loadedFilename = exactMatch.filename
                filenameKeyID = exactMatch.extractedKeyID
            } else if validKeys.count == 1, let single = validKeys.first, single.extractedKeyID == nil {
                // Single custom-named .p8 file paired with explicit APNS_KEY_ID
                loadedPEM = single.pem
                loadedFilename = single.filename
            } else if !validKeys.isEmpty {
                configError = "APNS_KEY_ID (\(configuredKeyID)) does not match any AuthKey_\(configuredKeyID).p8 in \(displayDir)."
            }
        } else {
            for fileURL in p8Files {
                if let key = loadValidKey(at: fileURL) {
                    loadedPEM = key.pem
                    loadedFilename = key.filename
                    filenameKeyID = key.extractedKeyID
                    break
                }
            }
        }

        let resolvedKeyID = firstNonEmpty(configuredKeyID, filenameKeyID)

        guard loadedPEM != nil || configError != nil || resolvedKeyID != nil || teamID != nil || bundleID != nil else {
            return nil
        }
        return APNsLocalDirectoryConfig(
            keyID: resolvedKeyID,
            teamID: teamID,
            bundleID: bundleID,
            privateKeyPEM: loadedPEM,
            keyFilename: loadedFilename,
            sourceDirectoryDisplay: displayDir,
            configurationError: configError
        )
    }

    private static func parseEnvFile(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let cleaned = line.hasPrefix("export ") ? String(line.dropFirst("export ".count)) : line
            guard let eq = cleaned.firstIndex(of: "=") else { continue }
            let key = cleaned[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = cleaned[cleaned.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                if value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let trimmed = v?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

struct APNsNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
    let filename: String?
    let collapseID: String?

    static func scanCompleted(
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int64,
        elapsedSeconds: Double
    ) -> APNsNotificationContent {
        let mb = Double(max(0, fileSizeBytes)) / (1024.0 * 1024.0)
        let sizeStr = String(format: "%.1f MB", mb)
        var parts = [filename, "\(pixelWidth)×\(pixelHeight)", sizeStr]
        if elapsedSeconds >= 1.0 {
            let total = Int(elapsedSeconds.rounded())
            if total >= 60 {
                parts.append("\(total / 60)m \(total % 60)s")
            } else {
                parts.append("\(total)s")
            }
        }
        return APNsNotificationContent(
            title: "Scan Complete",
            body: parts.joined(separator: " · "),
            filename: filename,
            collapseID: "chromascan-scan-complete"
        )
    }

    static func testNotification(hostName: String) -> APNsNotificationContent {
        APNsNotificationContent(
            title: "ChromaScan Push Ready",
            body: "Connected to \(hostName). You’ll be notified here when scans finish.",
            filename: nil,
            collapseID: "chromascan-test-push"
        )
    }
}

enum APNsLiveActivityEvent: String, Equatable, Sendable {
    case update
    case end
}

struct APNsLiveActivityPayload: Equatable, Sendable {
    let event: APNsLiveActivityEvent
    let contentState: ScanLiveActivityContentState
    let timestamp: Int
    let dismissalDate: Int?

    init(
        event: APNsLiveActivityEvent,
        contentState: ScanLiveActivityContentState,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        dismissalDate: Int? = nil
    ) {
        self.event = event
        self.contentState = contentState
        self.timestamp = timestamp
        self.dismissalDate = dismissalDate
    }
}

enum APNsDeliveryResult: Equatable, Sendable {
    case delivered(environment: PushEnvironment)
    case unregistered
    case failed(statusCode: Int, reason: String)

    static func friendlyErrorMessage(statusCode: Int, reason: String) -> String {
        switch reason {
        case "InvalidProviderToken":
            return "Invalid APNs token — check that Key ID and Team ID match your .p8 key."
        case "DeviceTokenNotForTopic", "TopicDisallowed":
            return "Bundle ID mismatch — ensure APNs Bundle ID matches your signed iOS app and .p8 key's Team ID."
        case "BadDeviceToken":
            return "Invalid device token for APNs sandbox and production — reopen the iPhone app to refresh."
        case "ExpiredProviderToken":
            return "APNs provider token expired — verify your Mac's system clock."
        case "BadCertificateEnvironment":
            return "APNs environment mismatch between certificate and host."
        default:
            return statusCode > 0 ? "HTTP \(statusCode): \(reason)" : reason
        }
    }
}

// MARK: - Transport & Client Protocols

protocol APNsHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAPNsTransport: APNsHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

protocol APNsPushing: Sendable {
    func send(
        notification: APNsNotificationContent,
        toDeviceToken deviceToken: String,
        preferredEnvironment: PushEnvironment,
        configuration: APNsConfiguration
    ) async -> APNsDeliveryResult

    func sendLiveActivity(
        payload: APNsLiveActivityPayload,
        toActivityPushToken activityPushToken: String,
        preferredEnvironment: PushEnvironment,
        configuration: APNsConfiguration
    ) async -> APNsDeliveryResult
}

// MARK: - ES256 JWT Helper

enum APNsJWTError: Error, LocalizedError {
    case invalidConfiguration
    case invalidPrivateKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Incomplete APNs configuration."
        case .invalidPrivateKey(let detail):
            return "Invalid APNs .p8 private key: \(detail)"
        }
    }
}

enum APNsJWTGenerator {
    static func generateToken(
        configuration: APNsConfiguration,
        issuedAt: Date = Date()
    ) throws -> String {
        let keyID = configuration.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamID = configuration.teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyID.isEmpty, !teamID.isEmpty else {
            throw APNsJWTError.invalidConfiguration
        }

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try APNsConfiguration.validatePrivateKeyPEM(configuration.privateKeyPEM)
        } catch {
            throw APNsJWTError.invalidPrivateKey(error.localizedDescription)
        }

        let headerJSON = try JSONSerialization.data(
            withJSONObject: ["alg": "ES256", "kid": keyID],
            options: [.sortedKeys]
        )
        let iat = Int(issuedAt.timeIntervalSince1970)
        let payloadJSON = try JSONSerialization.data(
            withJSONObject: ["iat": iat, "iss": teamID],
            options: [.sortedKeys]
        )

        let headerB64 = base64URLEncode(headerJSON)
        let payloadB64 = base64URLEncode(payloadJSON)
        let signingInput = "\(headerB64).\(payloadB64)"

        // CryptoKit rawRepresentation is 64-byte IEEE P1363 (r || s), matching RFC 7515 ES256.
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        let signatureB64 = base64URLEncode(signature.rawRepresentation)
        return "\(signingInput).\(signatureB64)"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Direct Mac -> APNs HTTP/2 Push Client

actor APNsClient: APNsPushing {
    /// Signing credential fingerprint independent of `bundleID`/topic so alert and Live Activity
    /// pushes using the same key reuse one cached JWT without tripping Apple's token-refresh limits.
    private struct JWTCredentialFingerprint: Equatable {
        let keyID: String
        let teamID: String
        let privateKeyPEM: String

        init(configuration: APNsConfiguration) {
            self.keyID = configuration.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.teamID = configuration.teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.privateKeyPEM = configuration.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct CachedJWT {
        let token: String
        let issuedAt: Date
        let credential: JWTCredentialFingerprint
    }

    private let transport: any APNsHTTPTransport
    private let jwtLifetime: TimeInterval
    private var cachedJWT: CachedJWT?

    init(
        transport: any APNsHTTPTransport = URLSessionAPNsTransport(),
        jwtLifetime: TimeInterval = 45 * 60
    ) {
        self.transport = transport
        self.jwtLifetime = jwtLifetime
    }

    func send(
        notification: APNsNotificationContent,
        toDeviceToken deviceToken: String,
        preferredEnvironment: PushEnvironment,
        configuration: APNsConfiguration
    ) async -> APNsDeliveryResult {
        let cleanToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            return .failed(statusCode: 0, reason: "Missing device token")
        }

        let jwt: String
        do {
            jwt = try validJWT(for: configuration)
        } catch {
            apnsLog.error("APNs JWT signing failed: \(error.localizedDescription, privacy: .public)")
            return .failed(statusCode: 0, reason: error.localizedDescription)
        }

        var activeJWT = jwt
        var firstResult = await postToAPNs(
            notification: notification,
            deviceToken: cleanToken,
            environment: preferredEnvironment,
            configuration: configuration,
            jwt: activeJWT
        )

        // If the cached JWT expired (e.g. after Mac sleep), invalidate only if unchanged and retry once.
        if case .failed(let status, let reason) = firstResult,
           status == 403,
           reason == "ExpiredProviderToken" {
            invalidateCachedJWT(ifMatching: activeJWT)
            do {
                activeJWT = try validJWT(for: configuration)
                apnsLog.notice("APNs returned ExpiredProviderToken; retrying once with a freshly signed JWT")
                firstResult = await postToAPNs(
                    notification: notification,
                    deviceToken: cleanToken,
                    environment: preferredEnvironment,
                    configuration: configuration,
                    jwt: activeJWT
                )
            } catch {
                apnsLog.error("APNs JWT re-signing failed: \(error.localizedDescription, privacy: .public)")
                return .failed(statusCode: 0, reason: error.localizedDescription)
            }
        }

        // If the iOS build's signing environment differs (e.g. Xcode Release install using sandbox token),
        // retry once against the opposite APNs host automatically.
        if case .failed(let status, let reason) = firstResult,
           status == 400,
           reason == "BadDeviceToken" {
            let fallbackEnv = preferredEnvironment.opposite
            apnsLog.notice("APNs returned BadDeviceToken on \(preferredEnvironment.rawValue, privacy: .public); retrying on \(fallbackEnv.rawValue, privacy: .public)")
            return await postToAPNs(
                notification: notification,
                deviceToken: cleanToken,
                environment: fallbackEnv,
                configuration: configuration,
                jwt: activeJWT
            )
        }

        return firstResult
    }

    func sendLiveActivity(
        payload: APNsLiveActivityPayload,
        toActivityPushToken activityPushToken: String,
        preferredEnvironment: PushEnvironment,
        configuration: APNsConfiguration
    ) async -> APNsDeliveryResult {
        let cleanToken = activityPushToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            return .failed(statusCode: 0, reason: "Missing live activity push token")
        }

        let jwt: String
        do {
            jwt = try validJWT(for: configuration)
        } catch {
            apnsLog.error("APNs JWT signing failed: \(error.localizedDescription, privacy: .public)")
            return .failed(statusCode: 0, reason: error.localizedDescription)
        }

        var activeJWT = jwt
        var firstResult = await postLiveActivityToAPNs(
            payload: payload,
            activityPushToken: cleanToken,
            environment: preferredEnvironment,
            configuration: configuration,
            jwt: activeJWT
        )

        if case .failed(let status, let reason) = firstResult,
           status == 403,
           reason == "ExpiredProviderToken" {
            invalidateCachedJWT(ifMatching: activeJWT)
            do {
                activeJWT = try validJWT(for: configuration)
                apnsLog.notice("APNs Live Activity returned ExpiredProviderToken; retrying once with a freshly signed JWT")
                firstResult = await postLiveActivityToAPNs(
                    payload: payload,
                    activityPushToken: cleanToken,
                    environment: preferredEnvironment,
                    configuration: configuration,
                    jwt: activeJWT
                )
            } catch {
                apnsLog.error("APNs JWT re-signing failed: \(error.localizedDescription, privacy: .public)")
                return .failed(statusCode: 0, reason: error.localizedDescription)
            }
        }

        if case .failed(let status, let reason) = firstResult,
           status == 400,
           reason == "BadDeviceToken" {
            let fallbackEnv = preferredEnvironment.opposite
            apnsLog.notice("APNs Live Activity returned BadDeviceToken on \(preferredEnvironment.rawValue, privacy: .public); retrying on \(fallbackEnv.rawValue, privacy: .public)")
            return await postLiveActivityToAPNs(
                payload: payload,
                activityPushToken: cleanToken,
                environment: fallbackEnv,
                configuration: configuration,
                jwt: activeJWT
            )
        }

        return firstResult
    }

    private func validJWT(for configuration: APNsConfiguration) throws -> String {
        let now = Date()
        let credential = JWTCredentialFingerprint(configuration: configuration)
        if let cached = cachedJWT,
           cached.credential == credential,
           now.timeIntervalSince(cached.issuedAt) < jwtLifetime {
            return cached.token
        }
        let fresh = try APNsJWTGenerator.generateToken(configuration: configuration, issuedAt: now)
        cachedJWT = CachedJWT(token: fresh, issuedAt: now, credential: credential)
        return fresh
    }

    private func invalidateCachedJWT(ifMatching token: String) {
        if cachedJWT?.token == token {
            cachedJWT = nil
        }
    }

    private func postToAPNs(
        notification: APNsNotificationContent,
        deviceToken: String,
        environment: PushEnvironment,
        configuration: APNsConfiguration,
        jwt: String
    ) async -> APNsDeliveryResult {
        let host = (environment == .sandbox)
            ? "api.sandbox.push.apple.com"
            : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(deviceToken)") else {
            return .failed(statusCode: 0, reason: "Invalid APNs device token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(configuration.bundleID.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let collapseID = notification.collapseID, !collapseID.isEmpty {
            request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        }

        var payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": notification.title,
                    "body": notification.body
                ],
                "sound": "default",
                "interruption-level": "active"
            ]
        ]
        if let filename = notification.filename {
            payload["filename"] = filename
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            return .failed(statusCode: 0, reason: "Failed to encode APNs JSON payload")
        }

        do {
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            if status == 200 {
                apnsLog.notice("APNs delivered (\(environment.rawValue, privacy: .public))")
                return .delivered(environment: environment)
            }

            let reason = Self.extractReason(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: status)
            if status == 410 || reason == "Unregistered" {
                apnsLog.notice("APNs token unregistered (HTTP \(status))")
                return .unregistered
            }
            if status == 403 && reason == "ExpiredProviderToken" {
                invalidateCachedJWT(ifMatching: jwt)
            }
            apnsLog.error("APNs push failed (HTTP \(status)): \(reason, privacy: .public)")
            return .failed(statusCode: status, reason: reason)
        } catch {
            apnsLog.error("APNs network error: \(error.localizedDescription, privacy: .public)")
            return .failed(statusCode: 0, reason: error.localizedDescription)
        }
    }

    private static func extractReason(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = obj["reason"] as? String,
              !reason.isEmpty else {
            return nil
        }
        return reason
    }

    private func postLiveActivityToAPNs(
        payload: APNsLiveActivityPayload,
        activityPushToken: String,
        environment: PushEnvironment,
        configuration: APNsConfiguration,
        jwt: String
    ) async -> APNsDeliveryResult {
        let host = (environment == .sandbox)
            ? "api.sandbox.push.apple.com"
            : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(activityPushToken)") else {
            return .failed(statusCode: 0, reason: "Invalid APNs live activity token URL")
        }

        let baseBundleID = configuration.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = baseBundleID.hasSuffix(".push-type.liveactivity")
            ? baseBundleID
            : "\(baseBundleID).push-type.liveactivity"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            let stateData = try JSONEncoder().encode(payload.contentState)
            guard let stateJSON = try JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
                return .failed(statusCode: 0, reason: "Failed to encode Live Activity content-state")
            }
            var aps: [String: Any] = [
                "timestamp": payload.timestamp,
                "event": payload.event.rawValue,
                "content-state": stateJSON
            ]
            if let dismissalDate = payload.dismissalDate {
                aps["dismissal-date"] = dismissalDate
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
        } catch {
            return .failed(statusCode: 0, reason: "Failed to encode APNs Live Activity JSON payload")
        }

        do {
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            if status == 200 {
                apnsLog.notice("APNs Live Activity \(payload.event.rawValue, privacy: .public) delivered (\(environment.rawValue, privacy: .public))")
                return .delivered(environment: environment)
            }

            let reason = Self.extractReason(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: status)
            if status == 410 || reason == "Unregistered" {
                apnsLog.notice("APNs Live Activity token unregistered (HTTP \(status))")
                return .unregistered
            }
            if status == 403 && reason == "ExpiredProviderToken" {
                invalidateCachedJWT(ifMatching: jwt)
            }
            apnsLog.error("APNs Live Activity push failed (HTTP \(status)): \(reason, privacy: .public)")
            return .failed(statusCode: status, reason: reason)
        } catch {
            apnsLog.error("APNs Live Activity network error: \(error.localizedDescription, privacy: .public)")
            return .failed(statusCode: 0, reason: error.localizedDescription)
        }
    }
}
