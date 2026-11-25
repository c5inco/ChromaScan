import Foundation
import Network
import IOKit
import IOKit.usb
import IOUSBHost
import OSLog

private let usbBridgeLog = Logger(subsystem: "com.chromascan.usb", category: "bridge")

// MARK: - IPP-USB Interface Descriptor

/// Describes a single IPP-over-USB (`0x07/0x01/0x04`) interface setting and its Bulk IN/OUT endpoints.
struct IPPUSBInterfaceDescriptor: Equatable, Hashable, Sendable {
    let interfaceNumber: UInt8
    let alternateSetting: UInt8
    let bulkInAddress: UInt8
    let bulkOutAddress: UInt8
    let maxPacketSize: UInt16
}

// MARK: - Abstract USB Bulk Channel (Testable)

protocol IPPUSBChannelTransport: Sendable {
    func writeAll(_ data: Data, timeout: TimeInterval) throws
    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data
    func abortAndReset()
    func close()
}

enum IPPUSBBridgeError: Error, LocalizedError {
    case interfaceNotFound(UInt8)
    case exclusiveAccessDenied(UInt8)
    case transferFailed(String)
    case bridgeStopped
    case invalidHTTPRequest
    case noChannelsConfigured

    var errorDescription: String? {
        switch self {
        case .interfaceNotFound(let num):
            return "USB IPP-USB interface #\(num) is no longer attached."
        case .exclusiveAccessDenied(let num):
            return "USB interface #\(num) is currently in use by another process."
        case .transferFailed(let detail):
            return "USB bulk transfer failed: \(detail)"
        case .bridgeStopped:
            return "USB bridge stopped."
        case .invalidHTTPRequest:
            return "Malformed HTTP/1.1 request received on local USB bridge."
        case .noChannelsConfigured:
            return "USB device has no available IPP-USB interfaces."
        }
    }
}

// MARK: - Real IOUSBHost Bulk Channel Implementation

/// Opens an `IOUSBHostInterface`, switches to its IPP-USB alternate setting (`07/01/04`),
/// transfers HTTP/1.1 bytes over its Bulk OUT / Bulk IN pipes, and restores `alt 0` on close.
final class IOUSBHostChannelTransport: IPPUSBChannelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: IPPUSBInterfaceDescriptor
    private var interface: IOUSBHostInterface?
    private var outPipe: IOUSBHostPipe?
    private var inPipe: IOUSBHostPipe?
    private let originalAlternateSetting: UInt8
    private var isClosed = false

    init(ioService: io_service_t, descriptor: IPPUSBInterfaceDescriptor) throws {
        self.descriptor = descriptor
        let currentAlt = (IORegistryEntryCreateCFProperty(
            ioService,
            "bAlternateSetting" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber)?.uint8Value ?? 0
        self.originalAlternateSetting = currentAlt

        let iface: IOUSBHostInterface
        do {
            iface = try IOUSBHostInterface(__ioService: ioService, options: [], queue: nil, interestHandler: nil)
        } catch {
            let nsErr = error as NSError
            // kIOReturnExclusiveAccess == 0xe00002c5 == -536870203
            if nsErr.code == Int(Int32(bitPattern: 0xe00002c5)) {
                throw IPPUSBBridgeError.exclusiveAccessDenied(descriptor.interfaceNumber)
            }
            throw IPPUSBBridgeError.transferFailed(error.localizedDescription)
        }

        do {
            if currentAlt != descriptor.alternateSetting {
                try iface.selectAlternateSetting(Int(descriptor.alternateSetting))
            }
            // Resolve exact Bulk IN/OUT endpoint addresses from the interface's live configuration descriptor
            // (handles cases where initial discovery fell back to non-exclusive IORegistry inspection).
            var inAddr = descriptor.bulkInAddress
            var outAddr = descriptor.bulkOutAddress
            let cfgPtr = iface.configurationDescriptor
            let totalLen = Int(cfgPtr.pointee.wTotalLength)
            if totalLen > 0 {
                let cfgData = Data(bytes: cfgPtr, count: totalLen)
                if let matched = USBConfigurationDescriptorParser.parseIPPUSBInterfaces(from: cfgData)
                    .first(where: { $0.interfaceNumber == descriptor.interfaceNumber }) {
                    inAddr = matched.bulkInAddress
                    outAddr = matched.bulkOutAddress
                }
            }
            let out = try iface.copyPipe(withAddress: Int(outAddr))
            let inp = try iface.copyPipe(withAddress: Int(inAddr))
            self.interface = iface
            self.outPipe = out
            self.inPipe = inp
            // Quickly drain any stale unread bytes left in the printer's Bulk IN FIFO
            // from an earlier interrupted session before sending a fresh HTTP request.
            drainStaleInput(pipe: inp)
        } catch {
            if currentAlt != descriptor.alternateSetting {
                try? iface.selectAlternateSetting(Int(currentAlt))
            }
            iface.destroy()
            throw IPPUSBBridgeError.transferFailed(error.localizedDescription)
        }
    }

    deinit {
        close()
    }

    func writeAll(_ data: Data, timeout: TimeInterval) throws {
        guard !data.isEmpty else { return }
        lock.lock()
        let pipe = outPipe
        let closed = isClosed
        lock.unlock()

        guard !closed, let pipe else {
            throw IPPUSBBridgeError.bridgeStopped
        }

        let maxChunk = 65_536
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + maxChunk)
            let slice = data[data.index(data.startIndex, offsetBy: offset)..<data.index(data.startIndex, offsetBy: end)]
            let mutable = NSMutableData(data: slice)
            var transferred: Int = 0
            do {
                try pipe.__sendIORequest(with: mutable, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                // Attempt stall clear once before surfacing failure
                try? pipe.clearStall()
                throw IPPUSBBridgeError.transferFailed(error.localizedDescription)
            }
            if transferred <= 0 {
                throw IPPUSBBridgeError.transferFailed("Zero bytes written to USB Bulk OUT")
            }
            offset += transferred
        }
    }

    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data {
        lock.lock()
        let pipe = inPipe
        let closed = isClosed
        lock.unlock()

        guard !closed, let pipe else {
            throw IPPUSBBridgeError.bridgeStopped
        }

        let size = max(512, min(262_144, maxLength))
        let mutable = NSMutableData(length: size)!
        var transferred: Int = 0
        do {
            try pipe.__sendIORequest(with: mutable, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            let nsErr = error as NSError
            // kIOUSBTransactionTimeout (0xe0004051) / kIOReturnTimeout (0xe00002d6) -> return empty chunk cleanly
            let code = UInt32(bitPattern: Int32(truncatingIfNeeded: nsErr.code))
            if code == 0xe0004051 || code == 0xe00002d6 {
                return Data()
            }
            throw IPPUSBBridgeError.transferFailed(error.localizedDescription)
        }
        guard transferred > 0 else { return Data() }
        return Data(bytes: mutable.bytes, count: transferred)
    }

    func abortAndReset() {
        lock.lock()
        let inP = inPipe
        let outP = outPipe
        let iface = interface
        lock.unlock()

        try? inP?.__abort(with: .synchronous)
        try? outP?.__abort(with: .synchronous)
        try? inP?.clearStall()
        try? outP?.clearStall()

        // Re-select alternate setting to flush any unread scan data sitting in the printer's Bulk IN FIFO.
        if let iface {
            if descriptor.alternateSetting != 0 {
                try? iface.selectAlternateSetting(0)
            }
            try? iface.selectAlternateSetting(Int(descriptor.alternateSetting))
            if let newOut = try? iface.copyPipe(withAddress: Int(descriptor.bulkOutAddress)),
               let newIn = try? iface.copyPipe(withAddress: Int(descriptor.bulkInAddress)) {
                lock.lock()
                if !isClosed {
                    self.outPipe = newOut
                    self.inPipe = newIn
                }
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let inP = inPipe
        let outP = outPipe
        let iface = interface
        inPipe = nil
        outPipe = nil
        interface = nil
        lock.unlock()

        try? inP?.__abort(with: .synchronous)
        try? outP?.__abort(with: .synchronous)
        if let iface {
            if originalAlternateSetting != descriptor.alternateSetting {
                try? iface.selectAlternateSetting(Int(originalAlternateSetting))
            }
            iface.destroy()
        }
    }

    private func drainStaleInput(pipe: IOUSBHostPipe) {
        let drainBuf = NSMutableData(length: 16_384)!
        for _ in 0..<8 {
            var transferred: Int = 0
            do {
                try pipe.__sendIORequest(with: drainBuf, bytesTransferred: &transferred, completionTimeout: 0.03)
                if transferred <= 0 { break }
            } catch {
                break
            }
        }
    }
}

// MARK: - HTTP/1.1 Framing Helpers for USB Bulk Streams

enum IPPUSBHTTPFraming {
    struct RequestHead: Equatable, Sendable {
        let method: String
        let headerEndOffset: Int
        let contentLength: Int?
        let isChunked: Bool
    }

    struct ResponseHead: Equatable, Sendable {
        let statusCode: Int
        let headerEndOffset: Int
        let contentLength: Int64?
        let isChunked: Bool
        let hasNoBody: Bool
    }

    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

    static func findHeaderEnd(in data: Data) -> Int? {
        guard let range = data.range(of: headerDelimiter) else { return nil }
        return data.distance(from: data.startIndex, to: range.upperBound)
    }

    static func parseRequestHead(_ data: Data) -> RequestHead? {
        guard let endOffset = findHeaderEnd(in: data) else { return nil }
        let headerBytes = data.prefix(endOffset)
        guard let headerStr = String(data: headerBytes, encoding: .isoLatin1) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let method = requestLine.split(separator: " ").first.map(String.init) ?? "GET"

        var contentLength: Int?
        var isChunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length", let n = Int(val) {
                contentLength = max(0, n)
            } else if name == "transfer-encoding", val.lowercased().contains("chunked") {
                isChunked = true
            }
        }
        return RequestHead(method: method.uppercased(), headerEndOffset: endOffset, contentLength: contentLength, isChunked: isChunked)
    }

    /// Rewrites an HTTP/1.1 request head for IPP-over-USB compliance:
    /// - Sets `Host: localhost` (required by the USB IPP-over-USB 1.0 spec; many printer firmwares
    ///   reject `Host: 127.0.0.1:<port>` due to DNS-rebinding guards).
    /// - Forces `Connection: close` so each USB bulk transaction finishes cleanly without keep-alive desync.
    static func rewriteRequestWithConnectionClose(_ rawRequest: Data) -> Data {
        guard let endOffset = findHeaderEnd(in: rawRequest) else { return rawRequest }
        let headerBytes = rawRequest.prefix(endOffset)
        guard let headerStr = String(data: headerBytes, encoding: .isoLatin1) else { return rawRequest }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return rawRequest }

        var rewritten: [String] = [firstLine]
        var sawConnection = false
        var sawHost = false
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "host" {
                    if !sawHost {
                        rewritten.append("Host: localhost")
                        sawHost = true
                    }
                    continue
                }
                if name == "connection" || name == "proxy-connection" {
                    if !sawConnection {
                        rewritten.append("Connection: close")
                        sawConnection = true
                    }
                    continue
                }
            }
            rewritten.append(line)
        }
        if !sawHost {
            rewritten.append("Host: localhost")
        }
        if !sawConnection {
            rewritten.append("Connection: close")
        }
        var result = Data((rewritten.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if endOffset < rawRequest.count {
            let bodyStart = rawRequest.index(rawRequest.startIndex, offsetBy: endOffset)
            result.append(rawRequest[bodyStart...])
        }
        return result
    }

    /// Rewrites an HTTP/1.1 response head to include `Connection: close` so `URLSession`
    /// never attempts HTTP/1.1 keep-alive reuse on a single-transaction USB loopback socket.
    static func rewriteResponseHeadWithConnectionClose(_ headerAndInitialBody: Data, headerEndOffset: Int) -> Data {
        guard headerEndOffset > 0, headerEndOffset <= headerAndInitialBody.count else {
            return headerAndInitialBody
        }
        let headerBytes = headerAndInitialBody.prefix(headerEndOffset)
        guard let headerStr = String(data: headerBytes, encoding: .isoLatin1) else {
            return headerAndInitialBody
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return headerAndInitialBody }

        var rewritten: [String] = [statusLine]
        var sawConnection = false
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "connection" || name == "keep-alive" {
                    if name == "connection", !sawConnection {
                        rewritten.append("Connection: close")
                        sawConnection = true
                    }
                    continue
                }
            }
            rewritten.append(line)
        }
        if !sawConnection {
            rewritten.append("Connection: close")
        }
        var result = Data((rewritten.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if headerEndOffset < headerAndInitialBody.count {
            let bodyStart = headerAndInitialBody.index(headerAndInitialBody.startIndex, offsetBy: headerEndOffset)
            result.append(headerAndInitialBody[bodyStart...])
        }
        return result
    }

    static func parseResponseHead(_ data: Data, requestMethod: String) -> ResponseHead? {
        guard let endOffset = findHeaderEnd(in: data) else { return nil }
        let headerBytes = data.prefix(endOffset)
        guard let headerStr = String(data: headerBytes, encoding: .isoLatin1) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ")
        let statusCode = parts.count >= 2 ? (Int(parts[1]) ?? 200) : 200

        var contentLength: Int64?
        var isChunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length", let n = Int64(val) {
                contentLength = max(0, n)
            } else if name == "transfer-encoding", val.lowercased().contains("chunked") {
                isChunked = true
            }
        }

        let noBody = requestMethod == "HEAD"
            || (100...199).contains(statusCode)
            || statusCode == 204
            || statusCode == 304
            || contentLength == 0

        return ResponseHead(
            statusCode: statusCode,
            headerEndOffset: endOffset,
            contentLength: contentLength,
            isChunked: isChunked,
            hasNoBody: noBody
        )
    }
}

/// Incremental HTTP/1.1 `Transfer-Encoding: chunked` parser that tracks completion
/// across arbitrary USB Bulk IN packet boundaries with O(1) memory overhead.
struct ChunkedTransferTracker: Sendable {
    private enum State {
        case readingSizeLine
        case readingData(remaining: Int)
        case readingDataCRLF(remaining: Int)
        case readingTrailers
        case complete
        case failed
    }

    private var state: State = .readingSizeLine
    private var lineBuffer = Data()

    var isComplete: Bool {
        if case .complete = state { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    mutating func feed(_ chunk: Data) {
        var idx = chunk.startIndex
        let end = chunk.endIndex

        while idx < end {
            switch state {
            case .complete, .failed:
                return

            case .readingSizeLine:
                let byte = chunk[idx]
                idx = chunk.index(after: idx)
                lineBuffer.append(byte)
                if lineBuffer.count > 1024 {
                    state = .failed
                    return
                }
                if lineBuffer.count >= 2 &&
                   lineBuffer[lineBuffer.endIndex - 2] == 0x0D &&
                   lineBuffer[lineBuffer.endIndex - 1] == 0x0A {
                    let lineData = lineBuffer.dropLast(2)
                    lineBuffer.removeAll(keepingCapacity: true)
                    guard let lineStr = String(data: lineData, encoding: .ascii) else {
                        state = .failed
                        return
                    }
                    let sizePart = lineStr.split(separator: ";", maxSplits: 1).first?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    guard !sizePart.isEmpty, let size = Int(sizePart, radix: 16), size >= 0 else {
                        state = .failed
                        return
                    }
                    if size == 0 {
                        state = .readingTrailers
                    } else {
                        state = .readingData(remaining: size)
                    }
                }

            case .readingData(let remaining):
                let available = chunk.distance(from: idx, to: end)
                let consume = min(remaining, available)
                idx = chunk.index(idx, offsetBy: consume)
                let left = remaining - consume
                if left == 0 {
                    state = .readingDataCRLF(remaining: 2)
                } else {
                    state = .readingData(remaining: left)
                }

            case .readingDataCRLF(let remaining):
                let available = chunk.distance(from: idx, to: end)
                let consume = min(remaining, available)
                idx = chunk.index(idx, offsetBy: consume)
                let left = remaining - consume
                if left == 0 {
                    state = .readingSizeLine
                } else {
                    state = .readingDataCRLF(remaining: left)
                }

            case .readingTrailers:
                let byte = chunk[idx]
                idx = chunk.index(after: idx)
                lineBuffer.append(byte)
                if lineBuffer.count > 8192 {
                    state = .failed
                    return
                }
                if lineBuffer.count >= 2 &&
                   lineBuffer[lineBuffer.endIndex - 2] == 0x0D &&
                   lineBuffer[lineBuffer.endIndex - 1] == 0x0A {
                    if lineBuffer.count == 2 {
                        // Empty line terminates trailers and chunked stream
                        lineBuffer.removeAll()
                        state = .complete
                        return
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }
        }
    }
}

// MARK: - Local Loopback IPP-USB HTTP/1.1 Relay Bridge

/// Exposes a local `127.0.0.1:<ephemeralPort>` TCP relay that forwards HTTP/1.1 eSCL traffic
/// directly over a printer's IPP-over-USB (`0x07/0x01/0x04`) bulk pipes.
///
/// Key properties:
/// - **Zero changes to `ESCLClient`**: `URLSession` talks normal HTTP/1.1 to `127.0.0.1:<port>/eSCL`.
/// - **Concurrent channels**: Uses all available IPP-USB interfaces on the device so `ScannerStatus`
///   and `DELETE` (cancellation) never block behind an active 1200 DPI `NextDocument` stream.
/// - **Lazy claim & idle release**: Interfaces are only opened when a TCP request arrives and are
///   released back to macOS CUPS after `idleReleaseSeconds` of inactivity.
final class IPPUSBBridge: @unchecked Sendable {
    typealias ChannelOpener = @Sendable (_ slotIndex: Int) throws -> any IPPUSBChannelTransport

    private final class ChannelSlot {
        let index: Int
        var transport: (any IPPUSBChannelTransport)?
        var inUse = false
        var lastFailedAt: Date?

        init(index: Int) {
            self.index = index
        }
    }

    let deviceIdentifier: String
    let channelCount: Int
    let idleReleaseSeconds: TimeInterval

    private let channelOpener: ChannelOpener
    private let listenerQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private let poolLock = NSCondition()
    private var slots: [ChannelSlot]
    private var idleTimer: DispatchSourceTimer?
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionsLock = NSLock()

    private var listener: NWListener?
    private var isStopped = false
    private var boundPort: UInt16 = 0

    var port: UInt16 {
        poolLock.lock()
        defer { poolLock.unlock() }
        return boundPort
    }

    init(
        deviceIdentifier: String,
        channelCount: Int,
        idleReleaseSeconds: TimeInterval = 4.0,
        channelOpener: @escaping ChannelOpener
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.channelCount = max(1, channelCount)
        self.idleReleaseSeconds = max(0.05, idleReleaseSeconds)
        self.channelOpener = channelOpener
        self.listenerQueue = DispatchQueue(label: "com.chromascan.ippusb.listener.\(deviceIdentifier)")
        self.workerQueue = DispatchQueue(label: "com.chromascan.ippusb.worker.\(deviceIdentifier)", attributes: .concurrent)
        self.slots = (0..<max(1, channelCount)).map { ChannelSlot(index: $0) }
    }

    deinit {
        stop()
    }

    /// Starts the local loopback TCP listener (`127.0.0.1:<ephemeralPort>`) and returns the bound port.
    /// Does NOT claim any USB interfaces until a client actually connects.
    @discardableResult
    func start() throws -> UInt16 {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let newListener = try NWListener(using: params)
        let sem = DispatchSemaphore(value: 0)
        final class StartState: @unchecked Sendable {
            var port: UInt16 = 0
            var error: Error?
            var signalled = false
        }
        let stateBox = StartState()

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                let p = newListener?.port?.rawValue ?? 0
                if let self {
                    self.poolLock.lock()
                    self.boundPort = p
                    self.poolLock.unlock()
                }
                if !stateBox.signalled {
                    stateBox.port = p
                    stateBox.signalled = true
                    sem.signal()
                }
            case .failed(let err):
                if !stateBox.signalled {
                    stateBox.error = err
                    stateBox.signalled = true
                    sem.signal()
                }
            case .cancelled:
                if !stateBox.signalled {
                    stateBox.error = IPPUSBBridgeError.bridgeStopped
                    stateBox.signalled = true
                    sem.signal()
                }
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        poolLock.lock()
        isStopped = false
        listener = newListener
        poolLock.unlock()

        newListener.start(queue: listenerQueue)
        if sem.wait(timeout: .now() + 5.0) == .timedOut {
            newListener.cancel()
            throw IPPUSBBridgeError.transferFailed("Timed out binding loopback IPP-USB listener.")
        }
        if let err = stateBox.error {
            newListener.cancel()
            throw err
        }
        return stateBox.port
    }

    func stop() {
        poolLock.lock()
        isStopped = true
        let activeListener = listener
        listener = nil
        boundPort = 0
        idleTimer?.cancel()
        idleTimer = nil
        let transportsToClose = slots.compactMap { slot -> (any IPPUSBChannelTransport)? in
            let t = slot.transport
            slot.transport = nil
            slot.inUse = false
            return t
        }
        poolLock.broadcast()
        poolLock.unlock()

        activeListener?.cancel()

        connectionsLock.lock()
        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        connectionsLock.unlock()
        for c in conns {
            c.cancel()
        }

        for transport in transportsToClose {
            transport.close()
        }
    }

    /// Number of USB interfaces currently held open (used for diagnostics & idle-release tests).
    var openChannelCount: Int {
        poolLock.lock()
        defer { poolLock.unlock() }
        return slots.filter { $0.transport != nil }.count
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let connID = UUID()
        connectionsLock.lock()
        activeConnections[connID] = connection
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.workerQueue.async { [weak self] in
                    self?.serveConnection(connection, id: connID)
                }
            case .failed, .cancelled:
                self?.removeConnection(id: connID)
            default:
                break
            }
        }
        connection.start(queue: listenerQueue)
    }

    private func removeConnection(id: UUID) {
        connectionsLock.lock()
        activeConnections.removeValue(forKey: id)
        connectionsLock.unlock()
    }

    private func serveConnection(_ connection: NWConnection, id: UUID) {
        defer {
            connection.cancel()
            removeConnection(id: id)
        }

        // 1. Read complete HTTP/1.1 request from local URLSession TCP client
        guard let (rawRequest, reqHead) = readFullHTTPRequest(from: connection) else {
            return
        }
        let usbRequest = IPPUSBHTTPFraming.rewriteRequestWithConnectionClose(rawRequest)

        // 2. Lease an IPP-USB interface slot (lazy-opening on demand), failing over to
        //    another interface slot if one USB interface refuses writes (e.g. stalled/busy alt setting).
        var excludedSlots = Set<Int>()
        var lastError: Error?
        let maxAttempts = min(channelCount, 3)

        for _ in 0..<maxAttempts {
            let lease: (slot: ChannelSlot, transport: any IPPUSBChannelTransport)
            do {
                lease = try acquireChannel(timeout: 30.0, excluding: excludedSlots)
            } catch {
                lastError = error
                break
            }

            // 3. Write HTTP request bytes over USB Bulk OUT
            let writeTimeout: TimeInterval = usbRequest.count <= 8192 ? 2.5 : 10.0
            do {
                try lease.transport.writeAll(usbRequest, timeout: writeTimeout)
            } catch {
                lastError = error
                excludedSlots.insert(lease.slot.index)
                usbBridgeLog.error("USB write failed on slot \(lease.slot.index): \(error.localizedDescription, privacy: .public)")
                releaseChannel(lease.slot, resetTransport: true, markFailed: true)
                continue
            }

            // 4. Stream HTTP response from USB Bulk IN -> local TCP client
            let succeeded = streamHTTPResponse(
                from: lease.transport,
                requestMethod: reqHead.method,
                to: connection
            )
            if succeeded {
                sendTCPFinalClose(on: connection)
                releaseChannel(lease.slot, resetTransport: false, markFailed: false)
            } else {
                releaseChannel(lease.slot, resetTransport: true, markFailed: true)
            }
            return
        }

        let msg = lastError?.localizedDescription ?? "No responsive USB IPP-USB channel."
        usbBridgeLog.error("All USB channel attempts failed for \(self.deviceIdentifier, privacy: .public): \(msg, privacy: .public)")
        sendErrorResponse(status: "503 Service Unavailable", message: msg, on: connection)
    }

    // MARK: - TCP Request Reader

    private func readFullHTTPRequest(from connection: NWConnection) -> (Data, IPPUSBHTTPFraming.RequestHead)? {
        var buffer = Data()
        var parsedHead: IPPUSBHTTPFraming.RequestHead?
        var chunkedTracker = ChunkedTransferTracker()

        while true {
            guard let chunk = receiveTCPChunk(from: connection, timeout: 15.0) else {
                return nil
            }
            if chunk.isEmpty {
                if let head = parsedHead {
                    return (buffer, head)
                }
                return nil
            }
            buffer.append(chunk)

            if parsedHead == nil {
                if let head = IPPUSBHTTPFraming.parseRequestHead(buffer) {
                    parsedHead = head
                    let bodyReceived = buffer.count - head.headerEndOffset
                    if head.isChunked {
                        if bodyReceived > 0 {
                            let bodyStart = buffer.index(buffer.startIndex, offsetBy: head.headerEndOffset)
                            chunkedTracker.feed(Data(buffer[bodyStart...]))
                        }
                        if chunkedTracker.isComplete {
                            return (buffer, head)
                        }
                        if chunkedTracker.isFailed { return nil }
                    } else if let cl = head.contentLength {
                        if bodyReceived >= cl {
                            return (buffer, head)
                        }
                    } else {
                        // GET / DELETE / HEAD without Content-Length or chunked encoding
                        return (buffer, head)
                    }
                } else if buffer.count > 131_072 {
                    return nil
                }
            } else if let head = parsedHead {
                if head.isChunked {
                    chunkedTracker.feed(chunk)
                    if chunkedTracker.isComplete {
                        return (buffer, head)
                    }
                    if chunkedTracker.isFailed { return nil }
                } else if let cl = head.contentLength {
                    let bodyReceived = buffer.count - head.headerEndOffset
                    if bodyReceived >= cl {
                        return (buffer, head)
                    }
                }
            }
        }
    }

    // MARK: - USB -> TCP Streaming Response Forwarder

    private func streamHTTPResponse(
        from transport: any IPPUSBChannelTransport,
        requestMethod: String,
        to connection: NWConnection
    ) -> Bool {
        var headerAccum = Data()
        var responseHead: IPPUSBHTTPFraming.ResponseHead?
        var bodyBytesForwarded: Int64 = 0
        var chunkedTracker = ChunkedTransferTracker()
        var receivedAnyData = false

        // Use wall-clock deadlines rather than raw empty-read counts because USB IPP-USB printers
        // often emit rapid 0-byte USB Zero-Length Packets (ZLPs) while preparing an HTTP response.
        let readChunkTimeout: TimeInterval = 2.0
        let firstByteDeadline = Date().addingTimeInterval(90.0) // Allow scanner carriage warm-up
        var lastDataTime = Date()

        while true {
            if isConnectionCancelled(connection) {
                return false
            }

            let readStart = CFAbsoluteTimeGetCurrent()
            let chunk: Data
            do {
                chunk = try transport.readChunk(maxLength: 65_536, timeout: readChunkTimeout)
            } catch {
                usbBridgeLog.error("USB read error: \(error.localizedDescription, privacy: .public)")
                return false
            }
            let readDuration = CFAbsoluteTimeGetCurrent() - readStart

            if chunk.isEmpty {
                let now = Date()
                if !receivedAnyData {
                    if now >= firstByteDeadline { return false }
                } else if let head = responseHead, !head.isChunked && head.contentLength == nil {
                    // Close-delimited HTTP/1.0 response: consider complete after quiet period
                    if now.timeIntervalSince(lastDataTime) >= 1.5 {
                        return true
                    }
                } else {
                    if now.timeIntervalSince(lastDataTime) >= 60.0 { return false }
                }
                // Back off slightly on fast USB ZLPs (<50ms) so we don't busy-spin the USB bus
                if readDuration < 0.05 {
                    usleep(10_000)
                }
                continue
            }

            lastDataTime = Date()
            receivedAnyData = true

            if responseHead == nil {
                headerAccum.append(chunk)
                if let head = IPPUSBHTTPFraming.parseResponseHead(headerAccum, requestMethod: requestMethod) {
                    responseHead = head

                    // Forward headers (with Connection: close) + any initial body slice
                    let toSend = IPPUSBHTTPFraming.rewriteResponseHeadWithConnectionClose(
                        headerAccum,
                        headerEndOffset: head.headerEndOffset
                    )
                    guard sendTCPChunk(toSend, on: connection) else {
                        return false
                    }

                    let initialBodyCount = headerAccum.count - head.headerEndOffset
                    if head.hasNoBody {
                        return true
                    }

                    if head.isChunked {
                        if initialBodyCount > 0 {
                            let bodyStart = headerAccum.index(headerAccum.startIndex, offsetBy: head.headerEndOffset)
                            chunkedTracker.feed(Data(headerAccum[bodyStart...]))
                        }
                        headerAccum.removeAll(keepingCapacity: false)
                        if chunkedTracker.isComplete { return true }
                        if chunkedTracker.isFailed { return false }
                    } else if let cl = head.contentLength {
                        bodyBytesForwarded = Int64(initialBodyCount)
                        headerAccum.removeAll(keepingCapacity: false)
                        if bodyBytesForwarded >= cl { return true }
                    } else {
                        bodyBytesForwarded = Int64(initialBodyCount)
                        headerAccum.removeAll(keepingCapacity: false)
                    }
                } else if headerAccum.count > 131_072 {
                    return false
                }
            } else if let head = responseHead {
                // Stream directly to TCP client with O(1) memory overhead!
                guard sendTCPChunk(chunk, on: connection) else {
                    return false
                }

                if head.isChunked {
                    chunkedTracker.feed(chunk)
                    if chunkedTracker.isComplete { return true }
                    if chunkedTracker.isFailed { return false }
                } else if let cl = head.contentLength {
                    bodyBytesForwarded += Int64(chunk.count)
                    if bodyBytesForwarded >= cl { return true }
                } else {
                    bodyBytesForwarded += Int64(chunk.count)
                }
            }
        }
    }

    // MARK: - USB Interface Pool & Idle Release

    private func acquireChannel(
        timeout: TimeInterval,
        excluding excludedSlots: Set<Int> = []
    ) throws -> (slot: ChannelSlot, transport: any IPPUSBChannelTransport) {
        let deadline = Date().addingTimeInterval(timeout)
        poolLock.lock()

        idleTimer?.cancel()
        idleTimer = nil

        while !isStopped {
            let eligible = slots.filter { !excludedSlots.contains($0.index) }
            guard !eligible.isEmpty else {
                poolLock.unlock()
                throw IPPUSBBridgeError.noChannelsConfigured
            }
            // Prefer healthy slots (no recent failure within 30s) over degraded slots,
            // and already-open idle slots over cold slots.
            let now = Date()
            let healthy = eligible.filter { slot in
                guard let failedAt = slot.lastFailedAt else { return true }
                return now.timeIntervalSince(failedAt) >= 30.0
            }
            let ordered = healthy + eligible.filter { slot in
                guard let failedAt = slot.lastFailedAt else { return false }
                return now.timeIntervalSince(failedAt) < 30.0
            }
            let candidate = ordered.first(where: { !$0.inUse && $0.transport != nil })
                ?? ordered.first(where: { !$0.inUse })
            if let slot = candidate {
                slot.inUse = true
                let existing = slot.transport
                poolLock.unlock()

                if let existing {
                    return (slot, existing)
                }

                // Lazily open the USB interface outside poolLock so other slots aren't blocked
                do {
                    let opened = try channelOpener(slot.index)
                    poolLock.lock()
                    if isStopped {
                        slot.inUse = false
                        poolLock.broadcast()
                        poolLock.unlock()
                        opened.close()
                        throw IPPUSBBridgeError.bridgeStopped
                    }
                    slot.transport = opened
                    poolLock.unlock()
                    return (slot, opened)
                } catch {
                    poolLock.lock()
                    slot.inUse = false
                    poolLock.broadcast()
                    poolLock.unlock()
                    throw error
                }
            }

            if !poolLock.wait(until: deadline) {
                poolLock.unlock()
                throw IPPUSBBridgeError.transferFailed("All USB IPP-USB channels are busy.")
            }
        }

        poolLock.unlock()
        throw IPPUSBBridgeError.bridgeStopped
    }

    private func releaseChannel(_ slot: ChannelSlot, resetTransport: Bool, markFailed: Bool = false) {
        var transportToReset: (any IPPUSBChannelTransport)?
        poolLock.lock()
        if markFailed {
            slot.lastFailedAt = Date()
        } else {
            slot.lastFailedAt = nil
        }
        if resetTransport {
            transportToReset = slot.transport
            slot.transport = nil
        }
        poolLock.unlock()

        if let transportToReset {
            transportToReset.abortAndReset()
            transportToReset.close()
        }

        poolLock.lock()
        slot.inUse = false
        let allIdle = !slots.contains(where: { $0.inUse })
        if allIdle && !isStopped {
            scheduleIdleReleaseLocked()
        }
        poolLock.broadcast()
        poolLock.unlock()
    }

    private func scheduleIdleReleaseLocked() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.schedule(deadline: .now() + idleReleaseSeconds)
        timer.setEventHandler { [weak self] in
            self?.releaseIdleChannels()
        }
        idleTimer = timer
        timer.resume()
    }

    private func releaseIdleChannels() {
        poolLock.lock()
        idleTimer?.cancel()
        idleTimer = nil
        guard !slots.contains(where: { $0.inUse }) else {
            poolLock.unlock()
            return
        }
        let toClose = slots.compactMap { slot -> (any IPPUSBChannelTransport)? in
            let t = slot.transport
            slot.transport = nil
            return t
        }
        poolLock.unlock()

        for t in toClose {
            t.close()
        }
        if !toClose.isEmpty {
            usbBridgeLog.notice("Released \(toClose.count) idle USB interface(s) for \(self.deviceIdentifier, privacy: .public)")
        }
    }

    // MARK: - Synchronous NWConnection Helpers (on Worker Queue)

    private func isConnectionCancelled(_ connection: NWConnection) -> Bool {
        poolLock.lock()
        let stopped = isStopped
        poolLock.unlock()
        if stopped { return true }
        switch connection.state {
        case .cancelled, .failed:
            return true
        default:
            return false
        }
    }

    private func receiveTCPChunk(from connection: NWConnection, timeout: TimeInterval) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        final class RecvBox: @unchecked Sendable {
            var data: Data?
        }
        let box = RecvBox()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if error != nil {
                box.data = nil
            } else if let content, !content.isEmpty {
                box.data = content
            } else if isComplete {
                box.data = Data()
            } else {
                box.data = nil
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        return box.data
    }

    private func sendTCPChunk(_ data: Data, on connection: NWConnection) -> Bool {
        guard !data.isEmpty else { return true }
        let sem = DispatchSemaphore(value: 0)
        final class SendBox: @unchecked Sendable {
            var ok = false
        }
        let box = SendBox()
        connection.send(content: data, completion: .contentProcessed { error in
            box.ok = (error == nil)
            sem.signal()
        })
        if sem.wait(timeout: .now() + 30.0) == .timedOut {
            return false
        }
        return box.ok
    }

    private func sendTCPFinalClose(on connection: NWConnection) {
        let sem = DispatchSemaphore(value: 0)
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            sem.signal()
        })
        _ = sem.wait(timeout: .now() + 2.0)
    }

    private func sendErrorResponse(status: String, message: String, on connection: NWConnection) {
        let body = Data(message.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        _ = sendTCPChunk(payload, on: connection)
        sendTCPFinalClose(on: connection)
    }
}
