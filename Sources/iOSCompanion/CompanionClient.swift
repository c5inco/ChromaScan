import Foundation
import Network
import OSLog
import Security

private let connectionLog = Logger(subsystem: "com.chromascan.connection", category: "client")

// MARK: - Keychain Token Storage

final class KeychainTokenStore: Sendable {
    private let service = "com.chromascan.remote.auth"

    func token(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return UserDefaults.standard.string(forKey: "companion.token.\(key)")
        }
        return token
    }

    func saveToken(_ token: String, for key: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            // Fallback for sandboxed simulator/unit test environments without keychain entitlement
            UserDefaults.standard.set(token, forKey: "companion.token.\(key)")
        } else {
            UserDefaults.standard.removeObject(forKey: "companion.token.\(key)")
        }
    }

    func deleteToken(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "companion.token.\(key)")
    }
}

// MARK: - Persistent WebSocket Companion Client

enum CompanionTarget: Equatable, Sendable {
    case bonjour(name: String, endpoint: NWEndpoint, hostID: String?)
    case manual(host: String, port: UInt16)

    var displayName: String {
        switch self {
        case .bonjour(let name, _, _): return name
        case .manual(let host, let port): return "\(host):\(port)"
        }
    }

    var tokenKey: String {
        switch self {
        case .bonjour(let name, _, let hostID): return hostID ?? "bonjour:\(name)"
        case .manual(let host, let port): return "manual:\(host):\(port)"
        }
    }

    var nwEndpoint: NWEndpoint {
        switch self {
        case .bonjour(_, let endpoint, _):
            return endpoint
        case .manual(let host, let port):
            let cleanHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            if let wsURL = URL(string: "ws://\(cleanHost):\(port)/") {
                return .url(wsURL)
            }
            return .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 8080
            )
        }
    }

    static func == (lhs: CompanionTarget, rhs: CompanionTarget) -> Bool {
        lhs.tokenKey == rhs.tokenKey && lhs.displayName == rhs.displayName
    }
}

@MainActor
final class CompanionClient {
    enum ConnectionStatus: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    var onStatusChanged: ((ConnectionStatus) -> Void)?
    var onHostMessage: ((HostMessage) -> Void)?
    var onBinaryFrame: ((CompanionBinaryFrame) -> Void)?

    private let queue = DispatchQueue(label: "com.chromascan.remote.client")
    private let tokenStore: KeychainTokenStore
    private let clientName: String
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    private var connection: NWConnection?
    private var currentTarget: CompanionTarget?
    private var pendingPIN: String?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var intentionallyDisconnected = true

    private(set) var status: ConnectionStatus = .disconnected {
        didSet {
            if status != oldValue {
                onStatusChanged?(status)
            }
        }
    }

    init(clientName: String, tokenStore: KeychainTokenStore = KeychainTokenStore()) {
        self.clientName = clientName
        self.tokenStore = tokenStore
    }

    // MARK: - Connection Management

    func connect(to target: CompanionTarget, pin: String? = nil) {
        disconnect(clearTarget: false)
        self.currentTarget = target
        self.pendingPIN = pin
        self.intentionallyDisconnected = false
        self.reconnectAttempt = 0
        openConnection(to: target)
    }

    func submitPIN(_ pin: String) {
        self.pendingPIN = pin
        if status == .connected, connection != nil {
            send(.hello(
                protocolVersion: CompanionConstants.protocolVersion,
                clientName: clientName,
                pin: pin,
                authToken: nil
            ))
        } else if let target = currentTarget {
            openConnection(to: target)
        }
    }

    func saveAuthToken(_ token: String, hostID: String) {
        tokenStore.saveToken(token, for: hostID)
        if let key = currentTarget?.tokenKey, key != hostID {
            tokenStore.saveToken(token, for: key)
        }
    }

    func clearSavedToken(hostID: String? = nil) {
        if let hostID {
            tokenStore.deleteToken(for: hostID)
        }
        if let key = currentTarget?.tokenKey {
            tokenStore.deleteToken(for: key)
        }
    }

    func reconnectIfNeeded() {
        guard !intentionallyDisconnected, let target = currentTarget else { return }
        if status == .connected {
            send(.ping)
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnection(to: target)
    }

    func disconnect(clearTarget: Bool = true) {
        intentionallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if clearTarget {
            currentTarget = nil
            pendingPIN = nil
        }
        status = .disconnected
    }

    func send(_ message: ClientMessage) {
        guard let connection, status == .connected,
              let data = try? jsonEncoder.encode(message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { error in
            if let error { connectionLog.error("Send failed: \(error.localizedDescription, privacy: .public)") }
        })
    }

    // MARK: - Internals

    private func openConnection(to target: CompanionTarget) {
        connection?.stateUpdateHandler = nil
        connection?.cancel()

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
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let attemptID = UUID()
        connectionLog.notice("Opening connection \(attemptID, privacy: .public)")
        let conn = NWConnection(to: target.nwEndpoint, using: params)
        self.connection = conn
        status = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self] in
                guard let self, let conn, self.connection === conn else { return }
                connectionLog.notice("Connection \(attemptID, privacy: .public) state: \(String(describing: state), privacy: .public)")
                switch state {
                case .ready:
                    self.reconnectAttempt = 0
                    self.status = .connected
                    self.sendHello(for: target)
                    self.receiveNext(on: conn)
                case .failed:
                    self.handleDrop()
                case .cancelled:
                    if !self.intentionallyDisconnected {
                        self.handleDrop()
                    }
                case .waiting:
                    break
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
    }

    private func sendHello(for target: CompanionTarget) {
        connectionLog.notice("Sending hello")
        let savedToken = tokenStore.token(for: target.tokenKey)
        send(.hello(
            protocolVersion: CompanionConstants.protocolVersion,
            clientName: clientName,
            pin: pendingPIN,
            authToken: pendingPIN == nil ? savedToken : nil
        ))
    }

    private func receiveNext(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            Task { @MainActor [weak self] in
                guard let self, let conn, self.connection === conn else { return }
                if let error {
                    connectionLog.error("Receive failed: \(error.localizedDescription, privacy: .public)")
                    self.handleDrop()
                    return
                }

                if let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch wsMeta.opcode {
                    case .text:
                        if let data, let msg = try? self.jsonDecoder.decode(HostMessage.self, from: data) {
                            switch msg {
                            case .welcome: connectionLog.notice("Received welcome")
                            case .authRequired: connectionLog.notice("Host requested pairing")
                            default: break
                            }
                            self.onHostMessage?(msg)
                        } else {
                            connectionLog.error("Could not decode host text frame")
                        }
                    case .binary:
                        if let data, let frame = try? CompanionBinaryFrame.unpack(data) {
                            self.onBinaryFrame?(frame)
                        }
                    case .close:
                        self.handleDrop()
                        return
                    default:
                        break
                    }
                } else if let data, !data.isEmpty {
                    if let msg = try? self.jsonDecoder.decode(HostMessage.self, from: data) {
                        self.onHostMessage?(msg)
                    } else if let frame = try? CompanionBinaryFrame.unpack(data) {
                        self.onBinaryFrame?(frame)
                    }
                }

                self.receiveNext(on: conn)
            }
        }
    }

    private func handleDrop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        guard !intentionallyDisconnected, let target = currentTarget else {
            status = .disconnected
            return
        }

        reconnectAttempt += 1
        status = .reconnecting(attempt: reconnectAttempt)
        let delaySeconds = min(8.0, pow(2.0, Double(min(reconnectAttempt - 1, 3))))

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self, !Task.isCancelled, !self.intentionallyDisconnected else { return }
            self.openConnection(to: target)
        }
    }
}
