import Foundation
import Network
import OSLog
import CoreGraphics

struct ConnectedCompanionClient: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let connectedAt: Date
    let isAuthenticated: Bool
}

private let connectionLog = Logger(subsystem: "com.chromascan.connection", category: "host")

/// WebSocket + Bonjour (`_chromascan._tcp`) server running on the Mac Studio host.
/// Bridges authenticated iPhone Companion clients to `ScanSessionEngine`.
@MainActor
final class CompanionServer {
    private let engine: ScanSessionEngine
    private let preferences: AppPreferences
    private let apnsClient: any APNsPushing
    private let advertiseBonjour: Bool
    private let requestedPort: UInt16
    private let listenerQueue = DispatchQueue(label: "com.chromascan.companion.server")

    private var listener: NWListener?
    private var sessions: [UUID: ClientSession] = [:]
    private var engineObserverID: UUID?
    private var lastAdvertisedScannerName: String = ""
    private var lastProgressBroadcastTime: CFAbsoluteTime = 0
    private var proxyBroadcastTask: Task<Void, Never>?

    private struct LiveActivityTarget: Equatable, Sendable {
        let activityPushToken: String
        var environment: PushEnvironment
        let bundleID: String?
    }

    private var activeLiveActivityTargets: [String: LiveActivityTarget] = [:] // authToken -> target
    private var lastLiveActivityPushTime: CFAbsoluteTime = 0
    private var lastLiveActivityPhase: ScanLiveActivityPhase?
    private var isTrackingScanForLiveActivity: Bool = false
    private let liveActivityUpdateInterval: TimeInterval = 8.0

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    var onStateChanged: (() -> Void)?

    private(set) var isRunning: Bool = false
    private(set) var port: UInt16?
    private(set) var lastError: String?
    private(set) var lastPushStatus: String?
    private(set) var lastPushSucceeded: Bool?

    var hostID: String { preferences.companionHostID }

    var hostDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var connectedClients: [ConnectedCompanionClient] {
        sessions.values
            .filter { $0.isAuthenticated }
            .map {
                ConnectedCompanionClient(
                    id: $0.id,
                    name: $0.clientName,
                    connectedAt: $0.connectedAt,
                    isAuthenticated: $0.isAuthenticated
                )
            }
            .sorted { $0.connectedAt < $1.connectedAt }
    }

    init(
        engine: ScanSessionEngine,
        preferences: AppPreferences,
        advertiseBonjour: Bool = true,
        port: UInt16 = 0,
        apnsClient: any APNsPushing = APNsClient()
    ) {
        self.engine = engine
        self.preferences = preferences
        self.advertiseBonjour = advertiseBonjour
        self.requestedPort = port
        self.apnsClient = apnsClient

        self.engineObserverID = engine.addObserver { [weak self] event in
            self?.handleEngineEvent(event)
        }
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        lastError = nil

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = CompanionConstants.maximumMessageSize

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let newListener: NWListener
            if requestedPort > 0, let nwPort = NWEndpoint.Port(rawValue: requestedPort) {
                newListener = try NWListener(using: params, on: nwPort)
            } else {
                newListener = try NWListener(using: params)
            }

            if advertiseBonjour {
                let scannerName = engine.selectedScanner?.displayTitle ?? ""
                lastAdvertisedScannerName = scannerName
                newListener.service = makeBonjourService(scannerName: scannerName)
            }

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.acceptConnection(connection)
                }
            }

            self.listener = newListener
            newListener.start(queue: listenerQueue)
            onStateChanged?()
        } catch {
            lastError = "Failed to start Companion Server: \(error.localizedDescription)"
            isRunning = false
            port = nil
            onStateChanged?()
        }
    }

    func stop() {
        proxyBroadcastTask?.cancel()
        proxyBroadcastTask = nil

        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        activeLiveActivityTargets.removeAll()
        isTrackingScanForLiveActivity = false

        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
        onStateChanged?()
    }

    func revokeAllPairedDevices() {
        preferences.revokeAllPairedDevices()
        for session in sessions.values where session.isAuthenticated {
            sendHostMessage(
                .authRequired(hostID: hostID, hostName: hostDisplayName, reason: "Pairing revoked on host"),
                to: session
            )
            session.isAuthenticated = false
            session.close()
        }
        sessions.removeAll()
        activeLiveActivityTargets.removeAll()
        onStateChanged?()
    }

    private func makeBonjourService(scannerName: String) -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["v"] = "\(CompanionConstants.protocolVersion)"
        txt["id"] = hostID
        if !scannerName.isEmpty {
            txt["scanner"] = String(scannerName.prefix(64))
        }
        return NWListener.Service(
            name: hostDisplayName,
            type: CompanionConstants.bonjourServiceType,
            domain: CompanionConstants.bonjourDomain,
            txtRecord: txt
        )
    }

    private func updateBonjourTXTRecordIfNeeded() {
        guard advertiseBonjour, let listener else { return }
        let scannerName = engine.selectedScanner?.displayTitle ?? ""
        guard scannerName != lastAdvertisedScannerName else { return }
        lastAdvertisedScannerName = scannerName
        listener.service = makeBonjourService(scannerName: scannerName)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.isRunning = true
            self.port = listener?.port?.rawValue
            self.lastError = nil
            self.onStateChanged?()
        case .failed(let error):
            self.lastError = error.localizedDescription
            self.isRunning = false
            self.port = nil
            self.listener?.cancel()
            self.listener = nil
            self.onStateChanged?()
        case .cancelled:
            self.isRunning = false
            self.port = nil
            self.onStateChanged?()
        default:
            break
        }
    }

    // MARK: - Client Connection Handling

    private func acceptConnection(_ connection: NWConnection) {
        let session = ClientSession(connection: connection, queue: listenerQueue)
        sessions[session.id] = session
        connectionLog.notice("Accepted session \(session.id, privacy: .public)")

        session.onTextMessage = { [weak self, weak session] data in
            guard let self, let session else { return }
            self.handleIncomingText(data, from: session)
        }
        session.onDisconnected = { [weak self, weak session] in
            guard let self, let session else { return }
            connectionLog.notice("Closed session \(session.id, privacy: .public)")
            self.sessions.removeValue(forKey: session.id)
            self.onStateChanged?()
        }

        session.start()
    }

    private func handleIncomingText(_ data: Data, from session: ClientSession) {
        guard let message = try? jsonDecoder.decode(ClientMessage.self, from: data) else {
            sendHostMessage(.error(title: "Protocol Error", message: "Invalid JSON message from client."), to: session)
            return
        }

        switch message {
        case .hello(let protocolVersion, let clientName, let pin, let authToken):
            guard protocolVersion == CompanionConstants.protocolVersion else {
                sendHostMessage(
                    .error(title: "Version Mismatch", message: "Unsupported companion protocol version \(protocolVersion)."),
                    to: session
                )
                return
            }

            connectionLog.notice("Received hello for session \(session.id, privacy: .public)")
            let trimmedName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            session.clientName = trimmedName.isEmpty ? "iPhone Companion" : trimmedName

            // 1. Check saved token first
            if let authToken, !authToken.isEmpty,
               preferences.validateToken(authToken, clientName: session.clientName) {
                completeAuthentication(for: session, token: authToken)
                return
            }

            // 2. Check 6-digit pairing PIN
            if let pin, !pin.isEmpty {
                let normalizedPIN = pin.filter(\.isNumber)
                if normalizedPIN == preferences.pairingPIN {
                    let minted = preferences.mintPairedDevice(clientName: session.clientName)
                    completeAuthentication(for: session, token: minted.token)
                    return
                } else {
                    sendHostMessage(
                        .authRequired(hostID: hostID, hostName: hostDisplayName, reason: "Incorrect pairing PIN."),
                        to: session
                    )
                    return
                }
            }

            // 3. Otherwise prompt for PIN
            sendHostMessage(
                .authRequired(hostID: hostID, hostName: hostDisplayName, reason: nil),
                to: session
            )

        case .ping:
            sendHostMessage(.pong, to: session)

        default:
            guard session.isAuthenticated else {
                sendHostMessage(
                    .authRequired(hostID: hostID, hostName: hostDisplayName, reason: "Authentication required."),
                    to: session
                )
                return
            }
            handleAuthenticatedMessage(message, from: session)
        }
    }

    private func completeAuthentication(for session: ClientSession, token: String) {
        connectionLog.notice("Authenticated session \(session.id, privacy: .public)")
        session.isAuthenticated = true
        session.authToken = token
        let snapshot = engine.makeSnapshot()
        sendHostMessage(
            .welcome(
                protocolVersion: CompanionConstants.protocolVersion,
                hostID: hostID,
                hostName: hostDisplayName,
                authToken: token,
                snapshot: snapshot
            ),
            to: session
        )
        sendHostMessage(.pushStatus(apnsConfigured: preferences.isAPNsConfigured), to: session)
        onStateChanged?()

        // Push currently rendered proxy image immediately if available
        Task { [weak self, weak session] in
            guard let self, let session, session.isAuthenticated else { return }
            if let encoded = await self.engine.encodeActiveProxy() {
                self.sendEncodedImage(encoded, to: session)
            }
        }
    }

    private func handleAuthenticatedMessage(_ message: ClientMessage, from session: ClientSession) {
        switch message {
        case .hello, .ping:
            break

        case .selectScanner(let scannerID):
            engine.selectScanner(id: scannerID)

        case .refreshScanners:
            engine.refreshScanners()

        case .addManualScanner(let host, let port, let useTLS):
            engine.addManualScanner(host: host, port: port, useTLS: useTLS)

        case .updateSettings(let patch):
            engine.updateSettings(patch)

        case .setCropRect(let cropRect):
            engine.setCropRect(cropRect)

        case .trimEmptySpace:
            engine.trimEmptySpace()

        case .setViewMode(let mode):
            engine.setViewMode(mode)

        case .triggerPreview:
            engine.startPreview()

        case .triggerScan:
            engine.startScan()

        case .triggerExport:
            engine.exportCurrentScan()

        case .cancel:
            engine.cancelActiveOperation()

        case .requestTile(let requestID, let normalizedRect, let maxPixelWidth):
            Task { [weak self, weak session] in
                guard let self, let session, session.isAuthenticated else { return }
                if let encoded = await self.engine.encodeHighResTile(
                    requestID: requestID,
                    normalizedRect: normalizedRect,
                    maxPixelWidth: maxPixelWidth
                ) {
                    self.sendEncodedImage(encoded, to: session)
                }
            }

        case .requestPhotosCopy(let requestID, let format, let quality):
            Task { [weak self, weak session] in
                guard let self, let session, session.isAuthenticated else { return }
                if let encoded = await self.engine.encodePhotosCopy(
                    requestID: requestID,
                    format: format,
                    quality: quality
                ) {
                    self.sendEncodedImage(encoded, to: session)
                } else {
                    self.sendHostMessage(
                        .error(title: "Photos Copy Failed", message: "No full-resolution scan is currently loaded."),
                        to: session
                    )
                }
            }

        case .registerPushToken(let deviceToken, let environment, let enabled, let bundleID):
            guard let authToken = session.authToken else { return }
            preferences.updatePushRegistration(
                forAuthToken: authToken,
                deviceToken: deviceToken,
                environment: environment,
                enabled: enabled,
                bundleID: bundleID
            )
            onStateChanged?()

        case .registerLiveActivityToken(let activityPushToken, let environment, let bundleID):
            guard let authToken = session.authToken else { return }
            let clean = activityPushToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clean.isEmpty {
                activeLiveActivityTargets.removeValue(forKey: authToken)
            } else {
                let cleanBundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
                activeLiveActivityTargets[authToken] = LiveActivityTarget(
                    activityPushToken: clean,
                    environment: environment,
                    bundleID: (cleanBundle?.isEmpty == false) ? cleanBundle : nil
                )
                if engine.isBusy && engine.activeOperation == .scan {
                    isTrackingScanForLiveActivity = true
                }
            }
        }
    }

    func notifyAPNsConfigurationChanged() {
        lastPushStatus = nil
        lastPushSucceeded = nil
        broadcastHostMessage(.pushStatus(apnsConfigured: preferences.isAPNsConfigured))
        onStateChanged?()
    }

    @discardableResult
    func sendTestPush() async -> Bool {
        let content = APNsNotificationContent.testNotification(hostName: hostDisplayName)
        return await deliverAPNsPush(content)
    }

    // MARK: - Engine Events -> Broadcast

    private func handleEngineEvent(_ event: SessionEngineEvent) {
        switch event {
        case .snapshotChanged(let snapshot):
            updateBonjourTXTRecordIfNeeded()
            broadcastHostMessage(.snapshot(snapshot: snapshot))
            if snapshot.isBusy && snapshot.activeOperation == .scan {
                if !isTrackingScanForLiveActivity {
                    isTrackingScanForLiveActivity = true
                    lastLiveActivityPushTime = 0
                    lastLiveActivityPhase = nil
                }
            } else if isTrackingScanForLiveActivity && !snapshot.isBusy {
                // Cancellation emits snapshotChanged(isBusy: false, statusText: "Scan cancelled")
                // without a follow-up scanCompleted or error event.
                if snapshot.statusText == "Scan cancelled" {
                    isTrackingScanForLiveActivity = false
                    lastLiveActivityPhase = nil
                    lastLiveActivityPushTime = 0
                    let nowEpoch = Int(Date().timeIntervalSince1970)
                    let cancelState = ScanLiveActivityContentState(
                        phase: .failed,
                        statusText: "Scan cancelled"
                    )
                    let payload = APNsLiveActivityPayload(
                        event: .end,
                        contentState: cancelState,
                        timestamp: nowEpoch,
                        dismissalDate: nowEpoch
                    )
                    let targets = drainLiveActivityTargets()
                    if !targets.isEmpty {
                        Task { [weak self] in
                            await self?.deliverLiveActivityPush(payload, to: targets)
                        }
                    }
                }
            }

        case .displayImageUpdated(let cgImage, let truePixelSize, let summary, let generation, let kind, let dpi):
            let authed = authenticatedSessions()
            guard !authed.isEmpty else { return }
            let trueW = Int(truePixelSize.width) > 0 ? Int(truePixelSize.width) : cgImage.width
            let trueH = Int(truePixelSize.height) > 0 ? Int(truePixelSize.height) : cgImage.height

            proxyBroadcastTask?.cancel()
            proxyBroadcastTask = Task.detached(priority: .userInitiated) { [weak self] in
                if Task.isCancelled { return }
                guard let data = ImagePipeline.encodeCompanionImage(
                    cgImage: cgImage,
                    preferHEIC: true,
                    quality: 0.88,
                    dpi: dpi
                ) else { return }
                if Task.isCancelled { return }

                let info = CompanionImageReadyInfo(
                    kind: kind,
                    generation: generation,
                    requestID: 0,
                    width: cgImage.width,
                    height: cgImage.height,
                    trueWidth: trueW,
                    trueHeight: trueH,
                    dpi: dpi,
                    normalizedRect: nil,
                    summaryText: summary
                )
                let encoded = EncodedCompanionImage(info: info, data: data)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for session in self.authenticatedSessions() {
                        self.sendEncodedImage(encoded, to: session)
                    }
                }
            }

        case .fullScanImageReady:
            break

        case .progress(let op, let bytesReceived, let expectedBytes, let elapsedSeconds, let statusText):
            let now = CFAbsoluteTimeGetCurrent()
            if op == .scan {
                isTrackingScanForLiveActivity = true
                maybePushLiveActivityProgress(
                    bytesReceived: bytesReceived,
                    expectedBytes: expectedBytes,
                    statusText: statusText,
                    now: now
                )
            }
            if bytesReceived > 0 && bytesReceived < expectedBytes && (now - lastProgressBroadcastTime) < 0.12 {
                return
            }
            lastProgressBroadcastTime = now
            broadcastHostMessage(
                .progress(
                    operation: op,
                    bytesReceived: bytesReceived,
                    expectedBytes: expectedBytes,
                    elapsedSeconds: elapsedSeconds,
                    statusText: statusText
                )
            )

        case .scanCompleted(let url, let pixelWidth, let pixelHeight, let fileSizeBytes, let elapsedSeconds):
            let filename = url.lastPathComponent
            broadcastHostMessage(
                .scanCompleted(
                    filename: filename,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    fileSizeBytes: fileSizeBytes,
                    elapsedSeconds: elapsedSeconds
                )
            )
            let pushContent = APNsNotificationContent.scanCompleted(
                filename: filename,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                fileSizeBytes: fileSizeBytes,
                elapsedSeconds: elapsedSeconds
            )
            isTrackingScanForLiveActivity = false
            lastLiveActivityPhase = nil
            lastLiveActivityPushTime = 0
            let completedLiveTargets = drainLiveActivityTargets()
            let nowEpoch = Int(Date().timeIntervalSince1970)
            let completedLivePayload = APNsLiveActivityPayload(
                event: .end,
                contentState: ScanLiveActivityContentState.completed(
                    filename: filename,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    fileSizeBytes: fileSizeBytes
                ),
                timestamp: nowEpoch,
                dismissalDate: nowEpoch + 15
            )
            Task { [weak self] in
                guard let self else { return }
                if !completedLiveTargets.isEmpty {
                    await self.deliverLiveActivityPush(completedLivePayload, to: completedLiveTargets)
                }
                await self.deliverAPNsPush(pushContent)
            }

        case .exportCompleted(let url, let fileSizeBytes, let elapsedSeconds):
            broadcastHostMessage(
                .exportCompleted(
                    filename: url.lastPathComponent,
                    fileSizeBytes: fileSizeBytes,
                    elapsedSeconds: elapsedSeconds
                )
            )

        case .error(let title, let message):
            broadcastHostMessage(.error(title: title, message: message))
            if isTrackingScanForLiveActivity {
                isTrackingScanForLiveActivity = false
                lastLiveActivityPhase = nil
                lastLiveActivityPushTime = 0
                let targets = drainLiveActivityTargets()
                if !targets.isEmpty {
                    let nowEpoch = Int(Date().timeIntervalSince1970)
                    let payload = APNsLiveActivityPayload(
                        event: .end,
                        contentState: ScanLiveActivityContentState.failed(title: title, message: message),
                        timestamp: nowEpoch,
                        dismissalDate: nowEpoch + 10
                    )
                    Task { [weak self] in
                        await self?.deliverLiveActivityPush(payload, to: targets)
                    }
                }
            }
        }
    }

    // MARK: - Direct Mac -> APNs Push Delivery

    @discardableResult
    private func deliverAPNsPush(_ content: APNsNotificationContent) async -> Bool {
        guard let config = preferences.apnsConfiguration else { return false }
        let eligible = preferences.pushEligibleDevices
        guard !eligible.isEmpty else { return false }

        // Deduplicate by APNs device token so a re-paired phone doesn't receive duplicates
        var seenTokens = Set<String>()
        var targets: [(token: String, env: PushEnvironment, bundleID: String)] = []
        for device in eligible {
            guard let token = device.apnsDeviceToken, !token.isEmpty else { continue }
            if seenTokens.insert(token).inserted {
                let topic = (device.apnsBundleID?.isEmpty == false) ? device.apnsBundleID! : config.bundleID
                targets.append((token: token, env: device.apnsEnvironment ?? .sandbox, bundleID: topic))
            }
        }
        guard !targets.isEmpty else { return false }

        var deliveredCount = 0
        var firstError: String?

        for target in targets {
            let deviceConfig = APNsConfiguration(
                keyID: config.keyID,
                teamID: config.teamID,
                bundleID: target.bundleID,
                privateKeyPEM: config.privateKeyPEM
            )
            let result = await apnsClient.send(
                notification: content,
                toDeviceToken: target.token,
                preferredEnvironment: target.env,
                configuration: deviceConfig
            )
            switch result {
            case .delivered(let actualEnv):
                deliveredCount += 1
                if actualEnv != target.env {
                    preferences.updateAPNsEnvironment(actualEnv, forDeviceToken: target.token)
                }
            case .unregistered:
                preferences.clearAPNsToken(target.token)
                if firstError == nil {
                    firstError = "Device push token expired (reopen iPhone app to refresh)"
                }
            case .failed(let statusCode, let reason):
                if firstError == nil {
                    firstError = statusCode > 0 ? "HTTP \(statusCode): \(reason)" : reason
                }
            }
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let timestamp = formatter.string(from: Date())
        if deliveredCount > 0 {
            lastPushSucceeded = true
            let suffix = deliveredCount == 1 ? "1 device" : "\(deliveredCount) devices"
            lastPushStatus = "Last push sent to \(suffix) at \(timestamp)"
        } else {
            lastPushSucceeded = false
            lastPushStatus = "Push failed: \(firstError ?? "Unknown error")"
        }
        onStateChanged?()
        return deliveredCount > 0
    }

    // MARK: - Direct Mac -> APNs Live Activity Push Delivery

    private func maybePushLiveActivityProgress(
        bytesReceived: Int64,
        expectedBytes: Int64,
        statusText: String,
        now: CFAbsoluteTime
    ) {
        guard !activeLiveActivityTargets.isEmpty, preferences.isAPNsConfigured else { return }

        let state = ScanLiveActivityContentState.fromProgress(
            bytesReceived: bytesReceived,
            expectedBytes: expectedBytes,
            statusText: statusText
        )
        let phaseChanged = (lastLiveActivityPhase != state.phase)
        if !phaseChanged && (now - lastLiveActivityPushTime) < liveActivityUpdateInterval {
            return
        }
        lastLiveActivityPhase = state.phase
        lastLiveActivityPushTime = now

        let targets = deduplicatedLiveActivityTargets()
        let payload = APNsLiveActivityPayload(
            event: .update,
            contentState: state,
            timestamp: Int(Date().timeIntervalSince1970),
            dismissalDate: nil
        )
        Task { [weak self] in
            await self?.deliverLiveActivityPush(payload, to: targets)
        }
    }

    private func deduplicatedLiveActivityTargets() -> [(authToken: String, target: LiveActivityTarget)] {
        var seenTokens = Set<String>()
        var result: [(authToken: String, target: LiveActivityTarget)] = []
        for (authToken, target) in activeLiveActivityTargets {
            if seenTokens.insert(target.activityPushToken).inserted {
                result.append((authToken: authToken, target: target))
            }
        }
        return result
    }

    private func drainLiveActivityTargets() -> [(authToken: String, target: LiveActivityTarget)] {
        let targets = deduplicatedLiveActivityTargets()
        activeLiveActivityTargets.removeAll()
        return targets
    }

    private func deliverLiveActivityPush(
        _ payload: APNsLiveActivityPayload,
        to targets: [(authToken: String, target: LiveActivityTarget)]
    ) async {
        guard let config = preferences.apnsConfiguration, !targets.isEmpty else { return }

        for entry in targets {
            let bundleID = entry.target.bundleID ?? config.bundleID
            let deviceConfig = APNsConfiguration(
                keyID: config.keyID,
                teamID: config.teamID,
                bundleID: bundleID,
                privateKeyPEM: config.privateKeyPEM
            )
            let result = await apnsClient.sendLiveActivity(
                payload: payload,
                toActivityPushToken: entry.target.activityPushToken,
                preferredEnvironment: entry.target.environment,
                configuration: deviceConfig
            )
            switch result {
            case .delivered(let actualEnv):
                if var existing = activeLiveActivityTargets[entry.authToken],
                   existing.activityPushToken == entry.target.activityPushToken,
                   existing.environment != actualEnv {
                    existing.environment = actualEnv
                    activeLiveActivityTargets[entry.authToken] = existing
                }
            case .unregistered:
                if activeLiveActivityTargets[entry.authToken]?.activityPushToken == entry.target.activityPushToken {
                    activeLiveActivityTargets.removeValue(forKey: entry.authToken)
                }
            case .failed:
                break
            }
        }
    }

    // MARK: - Wire Sending Helpers

    private func authenticatedSessions() -> [ClientSession] {
        sessions.values.filter { $0.isAuthenticated }
    }

    private func broadcastHostMessage(_ message: HostMessage) {
        let targets = authenticatedSessions()
        guard !targets.isEmpty, let data = try? jsonEncoder.encode(message) else { return }
        for session in targets {
            session.sendText(data)
        }
    }

    private func sendHostMessage(_ message: HostMessage, to session: ClientSession) {
        guard let data = try? jsonEncoder.encode(message) else { return }
        session.sendText(data)
    }

    private func sendEncodedImage(_ encoded: EncodedCompanionImage, to session: ClientSession) {
        sendHostMessage(.imageReady(encoded.info), to: session)
        let frame = CompanionBinaryFrame(
            kind: encoded.info.kind.frameKind,
            generation: encoded.info.generation,
            requestID: encoded.info.requestID,
            payload: encoded.data
        )
        session.sendBinary(frame.pack())
    }
}

// MARK: - Per-Client WebSocket Session

@MainActor
private final class ClientSession {
    let id = UUID()
    let connectedAt = Date()
    var clientName: String = "Connecting…"
    var isAuthenticated: Bool = false
    var authToken: String?

    var onTextMessage: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isClosed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveNext()
                case .failed, .cancelled:
                    self.notifyDisconnected()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func sendText(_ data: Data) {
        guard !isClosed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { connectionLog.error("Send failed: \(error.localizedDescription, privacy: .public)") }
        })
    }

    func sendBinary(_ data: Data) {
        guard !isClosed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { connectionLog.error("Send failed: \(error.localizedDescription, privacy: .public)") }
        })
    }

    private func receiveNext() {
        guard !isClosed else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                if let error {
                    connectionLog.error("Session \(self.id, privacy: .public) receive failed: \(error.localizedDescription, privacy: .public)")
                    self.notifyDisconnected()
                    return
                }
                if let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch wsMeta.opcode {
                    case .text:
                        if let data {
                            self.onTextMessage?(data)
                        }
                    case .close:
                        self.notifyDisconnected()
                        return
                    default:
                        break
                    }
                } else if let data, !data.isEmpty {
                    self.onTextMessage?(data)
                }
                self.receiveNext()
            }
        }
    }

    private func notifyDisconnected() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onDisconnected?()
    }
}
