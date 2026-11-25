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
    case writeFailed(bytesWritten: Int, detail: String)
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
        case .writeFailed(let bytesWritten, let detail):
            return "USB bulk write failed after \(bytesWritten) bytes: \(detail)"
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
///
/// Uses an in-flight I/O barrier (`ioCondition`) so `close()` always aborts pending transfers
/// and waits for active pipe calls to exit before changing alternate settings or destroying the interface.
final class IOUSBHostChannelTransport: IPPUSBChannelTransport, @unchecked Sendable {
    private let ioCondition = NSCondition()
    private let descriptor: IPPUSBInterfaceDescriptor
    private let resolvedBulkInAddress: UInt8
    private let resolvedBulkOutAddress: UInt8
    private var interface: IOUSBHostInterface?
    private var outPipe: IOUSBHostPipe?
    private var inPipe: IOUSBHostPipe?
    private let originalAlternateSetting: UInt8
    private var inFlightIO = 0
    private var isClosing = false
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
            self.resolvedBulkInAddress = inAddr
            self.resolvedBulkOutAddress = outAddr
            let out = try iface.copyPipe(withAddress: Int(outAddr))
            let inp = try iface.copyPipe(withAddress: Int(inAddr))
            self.interface = iface
            self.outPipe = out
            self.inPipe = inp
            // Drain any stale unread bytes left in the printer's Bulk IN FIFO before issuing a new request.
            drainStaleInput(pipe: inp, maxDuration: 0.25)
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

        ioCondition.lock()
        guard !isClosing, !isClosed, let pipe = outPipe else {
            ioCondition.unlock()
            throw IPPUSBBridgeError.bridgeStopped
        }
        inFlightIO += 1
        ioCondition.unlock()

        defer {
            ioCondition.lock()
            inFlightIO -= 1
            if inFlightIO == 0 {
                ioCondition.broadcast()
            }
            ioCondition.unlock()
        }

        let maxChunk = 65_536
        var offset = 0
        while offset < data.count {
            ioCondition.lock()
            let stopping = isClosing || isClosed
            ioCondition.unlock()
            if stopping {
                throw IPPUSBBridgeError.writeFailed(bytesWritten: offset, detail: "USB bridge stopped")
            }

            let end = min(data.count, offset + maxChunk)
            let slice = data[data.index(data.startIndex, offsetBy: offset)..<data.index(data.startIndex, offsetBy: end)]
            let mutable = NSMutableData(data: slice)
            var transferred: Int = 0
            do {
                try pipe.__sendIORequest(with: mutable, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                let totalWritten = offset + max(0, transferred)
                ioCondition.lock()
                let stillActive = !isClosing && !isClosed
                ioCondition.unlock()
                if stillActive {
                    try? pipe.clearStall()
                }
                throw IPPUSBBridgeError.writeFailed(bytesWritten: totalWritten, detail: error.localizedDescription)
            }
            if transferred <= 0 {
                throw IPPUSBBridgeError.writeFailed(bytesWritten: offset, detail: "Zero bytes written to USB Bulk OUT")
            }
            offset += transferred
        }
    }

    func readChunk(maxLength: Int, timeout: TimeInterval) throws -> Data {
        ioCondition.lock()
        guard !isClosing, !isClosed, let pipe = inPipe else {
            ioCondition.unlock()
            throw IPPUSBBridgeError.bridgeStopped
        }
        inFlightIO += 1
        ioCondition.unlock()

        defer {
            ioCondition.lock()
            inFlightIO -= 1
            if inFlightIO == 0 {
                ioCondition.broadcast()
            }
            ioCondition.unlock()
        }

        let size = max(512, min(262_144, maxLength))
        let mutable = NSMutableData(length: size)!
        var transferred: Int = 0
        do {
            try pipe.__sendIORequest(with: mutable, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            let nsErr = error as NSError
            // kIOUSBTransactionTimeout (0xe0004051) / kIOReturnTimeout (0xe00002d6)
            // IMPORTANT: preserve any partial bytes already received before the timeout!
            let code = UInt32(bitPattern: Int32(truncatingIfNeeded: nsErr.code))
            if code == 0xe0004051 || code == 0xe00002d6 {
                if transferred > 0 {
                    return Data(bytes: mutable.bytes, count: transferred)
                }
                return Data()
            }
            throw IPPUSBBridgeError.transferFailed(error.localizedDescription)
        }
        guard transferred > 0 else { return Data() }
        return Data(bytes: mutable.bytes, count: transferred)
    }

    func abortAndReset() {
        ioCondition.lock()
        guard !isClosing, !isClosed else {
            ioCondition.unlock()
            return
        }
        let inP = inPipe
        let outP = outPipe
        let iface = interface
        inFlightIO += 1
        ioCondition.unlock()

        defer {
            ioCondition.lock()
            inFlightIO -= 1
            if inFlightIO == 0 {
                ioCondition.broadcast()
            }
            ioCondition.unlock()
        }

        try? inP?.__abort(with: .synchronous)
        try? outP?.__abort(with: .synchronous)
        try? inP?.clearStall()
        try? outP?.clearStall()

        // Toggle alternate setting to flush printer USB endpoint state, then drain any
        // leftover bytes still buffered in firmware FIFO (up to 1.5s budget).
        if let iface {
            if descriptor.alternateSetting != 0 {
                try? iface.selectAlternateSetting(0)
            }
            try? iface.selectAlternateSetting(Int(descriptor.alternateSetting))
            if let newOut = try? iface.copyPipe(withAddress: Int(resolvedBulkOutAddress)),
               let newIn = try? iface.copyPipe(withAddress: Int(resolvedBulkInAddress)) {
                drainStaleInput(pipe: newIn, maxDuration: 1.5)
                ioCondition.lock()
                if !isClosing && !isClosed {
                    self.outPipe = newOut
                    self.inPipe = newIn
                }
                ioCondition.unlock()
            }
        }
    }

    func close() {
        ioCondition.lock()
        if isClosed {
            ioCondition.unlock()
            return
        }
        let alreadyClosing = isClosing
        isClosing = true
        let inP = inPipe
        let outP = outPipe
        ioCondition.unlock()

        if alreadyClosing {
            // Wait for the primary closer to finish teardown.
            ioCondition.lock()
            let waitDeadline = Date().addingTimeInterval(5.0)
            while !isClosed && Date() < waitDeadline {
                ioCondition.wait(until: waitDeadline)
            }
            ioCondition.unlock()
            return
        }

        // Abort pending transfers first so in-flight I/O calls exit promptly.
        try? inP?.__abort(with: .synchronous)
        try? outP?.__abort(with: .synchronous)

        // Wait for all in-flight pipe calls to exit before altering alt setting or destroying interface.
        ioCondition.lock()
        let drainDeadline = Date().addingTimeInterval(5.0)
        while inFlightIO > 0 && Date() < drainDeadline {
            ioCondition.wait(until: drainDeadline)
        }
        let iface = interface
        inPipe = nil
        outPipe = nil
        interface = nil
        ioCondition.unlock()

        if let iface {
            if originalAlternateSetting != descriptor.alternateSetting {
                try? iface.selectAlternateSetting(Int(originalAlternateSetting))
            }
            iface.destroy()
        }

        ioCondition.lock()
        isClosed = true
        ioCondition.broadcast()
        ioCondition.unlock()
    }

    private func drainStaleInput(pipe: IOUSBHostPipe, maxDuration: TimeInterval) {
        let drainBuf = NSMutableData(length: 65_536)!
        let deadline = Date().addingTimeInterval(maxDuration)
        while Date() < deadline {
            var transferred: Int = 0
            do {
                try pipe.__sendIORequest(with: drainBuf, bytesTransferred: &transferred, completionTimeout: 0.04)
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
        let expectsContinue: Bool
    }

    struct ResponseHead: Equatable, Sendable {
        let statusCode: Int
        let headerEndOffset: Int
        let contentLength: Int64?
        let isChunked: Bool
        let hasNoBody: Bool
        let isInterim: Bool
    }

    enum RequestParseResult: Equatable, Sendable {
        case incomplete
        case valid(RequestHead)
        case invalid
    }

    enum ResponseParseResult: Equatable, Sendable {
        case incomplete
        case valid(ResponseHead)
        case invalid
    }

    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

    static func findHeaderEnd(in data: Data) -> Int? {
        guard let range = data.range(of: headerDelimiter) else { return nil }
        return data.distance(from: data.startIndex, to: range.upperBound)
    }

    static func parseRequestHeadStrict(_ data: Data) -> RequestParseResult {
        guard let endOffset = findHeaderEnd(in: data) else { return .incomplete }
        let headerBytes = data.prefix(endOffset)
        guard let headerStr = String(data: headerBytes, encoding: .isoLatin1) else { return .invalid }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .invalid }
        let reqParts = requestLine.split(separator: " ")
        guard reqParts.count >= 3, reqParts[2].hasPrefix("HTTP/1.") else { return .invalid }
        let method = String(reqParts[0]).uppercased()

        var contentLength: Int?
        var isChunked = false
        var expectsContinue = false
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let n = Int(val), n >= 0 else { return .invalid }
                if let existing = contentLength, existing != n {
                    return .invalid // Conflicting Content-Length headers (RFC 9112 §6.3)
                }
                contentLength = n
            } else if name == "transfer-encoding" {
                if val.lowercased().contains("chunked") {
                    isChunked = true
                }
            } else if name == "expect" {
                if val.lowercased().contains("100-continue") {
                    expectsContinue = true
                }
            }
        }
        // Reject ambiguous requests combining both Transfer-Encoding: chunked and Content-Length
        if isChunked && contentLength != nil {
            return .invalid
        }
        return .valid(RequestHead(
            method: method,
            headerEndOffset: endOffset,
            contentLength: contentLength,
            isChunked: isChunked,
            expectsContinue: expectsContinue
        ))
    }

    static func parseRequestHead(_ data: Data) -> RequestHead? {
        if case .valid(let head) = parseRequestHeadStrict(data) {
            return head
        }
        return nil
    }

    /// Rewrites an HTTP/1.1 request head for IPP-over-USB compliance:
    /// - Sets `Host: localhost` (required by the USB IPP-over-USB 1.0 spec; many printer firmwares
    ///   reject `Host: 127.0.0.1:<port>` due to DNS-rebinding guards).
    /// - Strips `Expect` (the bridge buffers the request body before USB submission).
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
                if name == "expect" {
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

    static func parseResponseHeadStrict(_ data: Data, requestMethod: String) -> ResponseParseResult {
        guard let endOffset = findHeaderEnd(in: data) else { return .incomplete }
        let headerBytes = data.prefix(endOffset)
        guard let headerStr = String(data: headerBytes, encoding: .isoLatin1) else { return .invalid }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .invalid }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2,
              parts[0].hasPrefix("HTTP/1."),
              parts[1].count == 3,
              let statusCode = Int(parts[1]),
              (100...599).contains(statusCode) else {
            return .invalid
        }

        var contentLength: Int64?
        var isChunked = false
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let n = Int64(val), n >= 0 else { return .invalid }
                if let existing = contentLength, existing != n {
                    return .invalid
                }
                contentLength = n
            } else if name == "transfer-encoding", val.lowercased().contains("chunked") {
                isChunked = true
            }
        }

        // RFC 9112 §6.3: Transfer-Encoding overrides Content-Length if both appear in a response
        if isChunked {
            contentLength = nil
        }

        let isInterim = (100...199).contains(statusCode) && statusCode != 101
        let noBody = requestMethod == "HEAD"
            || isInterim
            || statusCode == 204
            || statusCode == 304
            || contentLength == 0

        return .valid(ResponseHead(
            statusCode: statusCode,
            headerEndOffset: endOffset,
            contentLength: contentLength,
            isChunked: isChunked,
            hasNoBody: noBody,
            isInterim: isInterim
        ))
    }

    static func parseResponseHead(_ data: Data, requestMethod: String) -> ResponseHead? {
        if case .valid(let head) = parseResponseHeadStrict(data, requestMethod: requestMethod) {
            return head
        }
        return nil
    }
}

/// Incremental HTTP/1.1 `Transfer-Encoding: chunked` parser that tracks completion and
/// exact consumed byte boundaries across arbitrary USB Bulk IN packet boundaries with O(1) memory.
struct ChunkedTransferTracker: Sendable {
    private enum State {
        case readingSizeLine
        case readingData(remaining: Int)
        case readingDataCR
        case readingDataLF
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

    /// Feeds bytes from `chunk` and returns the number of bytes belonging to the chunked message
    /// (allowing callers to avoid forwarding trailing bytes past the terminating `0\r\n\r\n`).
    @discardableResult
    mutating func feed(_ chunk: Data) -> Int {
        var idx = chunk.startIndex
        let end = chunk.endIndex
        var consumed = 0

        while idx < end {
            switch state {
            case .complete, .failed:
                return consumed

            case .readingSizeLine:
                let byte = chunk[idx]
                idx = chunk.index(after: idx)
                consumed += 1
                lineBuffer.append(byte)
                if lineBuffer.count > 1024 {
                    state = .failed
                    return consumed
                }
                if lineBuffer.count >= 2 &&
                   lineBuffer[lineBuffer.endIndex - 2] == 0x0D &&
                   lineBuffer[lineBuffer.endIndex - 1] == 0x0A {
                    let lineData = lineBuffer.dropLast(2)
                    lineBuffer.removeAll(keepingCapacity: true)
                    guard let lineStr = String(data: lineData, encoding: .ascii) else {
                        state = .failed
                        return consumed
                    }
                    let sizePart = lineStr.split(separator: ";", maxSplits: 1).first?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    guard !sizePart.isEmpty, let size = Int(sizePart, radix: 16), size >= 0 else {
                        state = .failed
                        return consumed
                    }
                    if size == 0 {
                        state = .readingTrailers
                    } else {
                        state = .readingData(remaining: size)
                    }
                }

            case .readingData(let remaining):
                let available = chunk.distance(from: idx, to: end)
                let take = min(remaining, available)
                idx = chunk.index(idx, offsetBy: take)
                consumed += take
                let left = remaining - take
                if left == 0 {
                    state = .readingDataCR
                } else {
                    state = .readingData(remaining: left)
                }

            case .readingDataCR:
                let byte = chunk[idx]
                idx = chunk.index(after: idx)
                consumed += 1
                if byte == 0x0D {
                    state = .readingDataLF
                } else {
                    state = .failed
                    return consumed
                }

            case .readingDataLF:
                let byte = chunk[idx]
                idx = chunk.index(after: idx)
                consumed += 1
                if byte == 0x0A {
                    state = .readingSizeLine
                } else {
                    state = .failed
                    return consumed
                }

            case .readingTrailers:
                let byte = chunk[idx]
                idx = chunk.index(after: idx)
                consumed += 1
                lineBuffer.append(byte)
                if lineBuffer.count > 8192 {
                    state = .failed
                    return consumed
                }
                if lineBuffer.count >= 2 &&
                   lineBuffer[lineBuffer.endIndex - 2] == 0x0D &&
                   lineBuffer[lineBuffer.endIndex - 1] == 0x0A {
                    if lineBuffer.count == 2 {
                        lineBuffer.removeAll()
                        state = .complete
                        return consumed
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }
        }
        return consumed
    }
}

// MARK: - Local Loopback IPP-USB HTTP/1.1 Relay Bridge

/// Exposes a local `127.0.0.1:<ephemeralPort>` TCP relay that forwards HTTP/1.1 eSCL traffic
/// directly over a printer's IPP-over-USB (`0x07/0x01/0x04`) bulk pipes.
final class IPPUSBBridge: @unchecked Sendable {
    typealias ChannelOpener = @Sendable (_ slotIndex: Int) throws -> any IPPUSBChannelTransport

    private final class ChannelSlot: @unchecked Sendable {
        let index: Int
        var transport: (any IPPUSBChannelTransport)?
        var inUse = false
        var isClosing = false
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
    private var idleTimerGeneration: UInt64 = 0
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
        idleTimerGeneration &+= 1
        idleTimer?.cancel()
        idleTimer = nil
        var transportsToClose: [(ChannelSlot, any IPPUSBChannelTransport)] = []
        for slot in slots {
            if let t = slot.transport {
                slot.isClosing = true
                transportsToClose.append((slot, t))
            }
            slot.inUse = false
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

        let closeBatch = transportsToClose
        let performClose: @Sendable () -> Void = { [weak self] in
            for (_, transport) in closeBatch {
                transport.close()
            }
            guard let self else { return }
            self.poolLock.lock()
            for (slot, _) in closeBatch {
                slot.transport = nil
                slot.isClosing = false
            }
            self.poolLock.broadcast()
            self.poolLock.unlock()
        }

        // Never block the main thread waiting on synchronous USB pipe teardown.
        if Thread.isMainThread && !transportsToClose.isEmpty {
            workerQueue.async(execute: performClose)
        } else {
            performClose()
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

        // 1. Read complete, strictly validated HTTP/1.1 request from local TCP client
        guard let (rawRequest, reqHead) = readFullHTTPRequest(from: connection) else {
            sendErrorResponse(status: "400 Bad Request", message: "Incomplete or invalid HTTP/1.1 request.", on: connection)
            return
        }
        let usbRequest = IPPUSBHTTPFraming.rewriteRequestWithConnectionClose(rawRequest)
        let isIdempotentMethod = (reqHead.method == "GET" || reqHead.method == "HEAD" || reqHead.method == "OPTIONS" || reqHead.method == "DELETE")

        // 2. Lease an IPP-USB interface slot (lazy-opening on demand).
        //    Fail over across all available slots on open failure (e.g. CUPS holds slot 0)
        //    or on zero-byte / idempotent write failure. Never replay a partially written POST!
        var excludedSlots = Set<Int>()
        var lastError: Error?
        let maxAttempts = channelCount

        for _ in 0..<maxAttempts {
            let lease: (slot: ChannelSlot, transport: any IPPUSBChannelTransport)
            do {
                lease = try acquireChannel(timeout: 30.0, excluding: &excludedSlots)
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

                let bytesAlreadySent: Int
                if case .writeFailed(let written, _) = error as? IPPUSBBridgeError {
                    bytesAlreadySent = written
                } else {
                    bytesAlreadySent = 0
                }
                if bytesAlreadySent == 0 || isIdempotentMethod {
                    continue
                } else {
                    // Non-idempotent request (e.g. POST /ScanJobs) already transmitted bytes — do not duplicate!
                    sendErrorResponse(status: "502 Bad Gateway", message: error.localizedDescription, on: connection)
                    return
                }
            }

            // 4. Stream HTTP response from USB Bulk IN -> local TCP client
            let outcome = streamHTTPResponse(
                from: lease.transport,
                requestMethod: reqHead.method,
                to: connection
            )
            switch outcome {
            case .completedCleanly:
                sendTCPFinalClose(on: connection)
                releaseChannel(lease.slot, resetTransport: false, markFailed: false)
            case .completedResetRequired:
                sendTCPFinalClose(on: connection)
                releaseChannel(lease.slot, resetTransport: true, markFailed: false)
            case .failed(let sentAnyToClient):
                if !sentAnyToClient {
                    sendErrorResponse(status: "502 Bad Gateway", message: "Scanner USB response interrupted.", on: connection)
                }
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
        var sentContinue = false

        while true {
            guard let chunk = receiveTCPChunk(from: connection, timeout: 15.0) else {
                return nil
            }
            if chunk.isEmpty {
                // Premature EOF before full request headers or body arrived -> reject!
                if let head = parsedHead, !head.isChunked, head.contentLength == nil {
                    return (Data(buffer.prefix(head.headerEndOffset)), head)
                }
                return nil
            }
            buffer.append(chunk)

            if parsedHead == nil {
                switch IPPUSBHTTPFraming.parseRequestHeadStrict(buffer) {
                case .invalid:
                    return nil
                case .incomplete:
                    if buffer.count > 131_072 { return nil }
                    continue
                case .valid(let head):
                    parsedHead = head
                    if head.expectsContinue && !sentContinue {
                        sentContinue = true
                        _ = sendTCPChunk(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
                    }
                    let bodyReceived = buffer.count - head.headerEndOffset
                    if head.isChunked {
                        if bodyReceived > 0 {
                            let bodyStart = buffer.index(buffer.startIndex, offsetBy: head.headerEndOffset)
                            let bodySlice = Data(buffer[bodyStart...])
                            let consumed = chunkedTracker.feed(bodySlice)
                            if chunkedTracker.isFailed { return nil }
                            if chunkedTracker.isComplete {
                                return (Data(buffer.prefix(head.headerEndOffset + consumed)), head)
                            }
                        }
                    } else if let cl = head.contentLength {
                        if bodyReceived >= cl {
                            return (Data(buffer.prefix(head.headerEndOffset + cl)), head)
                        }
                    } else {
                        // GET / DELETE / HEAD without body — slice cleanly to headerEndOffset
                        return (Data(buffer.prefix(head.headerEndOffset)), head)
                    }
                }
            } else if let head = parsedHead {
                if head.isChunked {
                    let prevLen = buffer.count - chunk.count
                    let consumed = chunkedTracker.feed(chunk)
                    if chunkedTracker.isFailed { return nil }
                    if chunkedTracker.isComplete {
                        return (Data(buffer.prefix(prevLen + consumed)), head)
                    }
                } else if let cl = head.contentLength {
                    let bodyReceived = buffer.count - head.headerEndOffset
                    if bodyReceived >= cl {
                        return (Data(buffer.prefix(head.headerEndOffset + cl)), head)
                    }
                }
            }
        }
    }

    // MARK: - USB -> TCP Streaming Response Forwarder

    private enum ResponseStreamOutcome {
        case completedCleanly
        case completedResetRequired
        case failed(sentAnyToClient: Bool)
    }

    private func streamHTTPResponse(
        from transport: any IPPUSBChannelTransport,
        requestMethod: String,
        to connection: NWConnection
    ) -> ResponseStreamOutcome {
        var headerAccum = Data()
        var responseHead: IPPUSBHTTPFraming.ResponseHead?
        var bodyBytesForwarded: Int64 = 0
        var chunkedTracker = ChunkedTransferTracker()
        var receivedAnyData = false
        var sentAnyToClient = false

        // Use wall-clock deadlines rather than raw empty-read counts because USB IPP-USB printers
        // often emit rapid 0-byte USB Zero-Length Packets (ZLPs) while preparing an HTTP response.
        let readChunkTimeout: TimeInterval = 2.0
        let firstByteDeadline = Date().addingTimeInterval(90.0) // Allow scanner carriage warm-up
        var lastDataTime = Date()

        while true {
            if isConnectionCancelled(connection) {
                return .failed(sentAnyToClient: sentAnyToClient)
            }

            let readStart = CFAbsoluteTimeGetCurrent()
            let chunk: Data
            do {
                chunk = try transport.readChunk(maxLength: 65_536, timeout: readChunkTimeout)
            } catch {
                usbBridgeLog.error("USB read error: \(error.localizedDescription, privacy: .public)")
                return .failed(sentAnyToClient: sentAnyToClient)
            }
            let readDuration = CFAbsoluteTimeGetCurrent() - readStart

            if chunk.isEmpty {
                let now = Date()
                if !receivedAnyData {
                    if now >= firstByteDeadline { return .failed(sentAnyToClient: sentAnyToClient) }
                } else if let head = responseHead, !head.isChunked && head.contentLength == nil {
                    // Close-delimited HTTP response (no Content-Length or chunked encoding):
                    // wait generously for carriage pauses, then require a transport reset on close
                    // so unread trailing bytes can never poison a subsequent request.
                    if bodyBytesForwarded > 0 && now.timeIntervalSince(lastDataTime) >= 5.0 {
                        return .completedResetRequired
                    }
                    if now.timeIntervalSince(lastDataTime) >= 60.0 {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                } else {
                    if now.timeIntervalSince(lastDataTime) >= 60.0 {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
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
                // Consume any interim 1xx responses (e.g. HTTP/1.1 100 Continue) and keep parsing
                // until a final (>= 200) response head arrives.
                while responseHead == nil {
                    switch IPPUSBHTTPFraming.parseResponseHeadStrict(headerAccum, requestMethod: requestMethod) {
                    case .invalid:
                        return .failed(sentAnyToClient: sentAnyToClient)
                    case .incomplete:
                        if headerAccum.count > 131_072 {
                            return .failed(sentAnyToClient: sentAnyToClient)
                        }
                        break
                    case .valid(let head):
                        if head.isInterim {
                            // Discard interim 1xx header block and continue parsing remaining bytes
                            let remainderStart = headerAccum.index(headerAccum.startIndex, offsetBy: head.headerEndOffset)
                            headerAccum = Data(headerAccum[remainderStart...])
                            continue
                        }
                        responseHead = head
                    }
                    break
                }

                guard let head = responseHead else { continue }

                // Trim initial body to exact message boundary before forwarding
                let initialBodyStart = headerAccum.index(headerAccum.startIndex, offsetBy: head.headerEndOffset)
                let rawInitialBody = Data(headerAccum[initialBodyStart...])
                var initialHeaderOnly = Data(headerAccum.prefix(head.headerEndOffset))

                if head.hasNoBody {
                    let toSend = IPPUSBHTTPFraming.rewriteResponseHeadWithConnectionClose(
                        initialHeaderOnly,
                        headerEndOffset: head.headerEndOffset
                    )
                    guard sendTCPChunk(toSend, on: connection) else {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    sentAnyToClient = true
                    return .completedCleanly
                }

                if head.isChunked {
                    let consumed = chunkedTracker.feed(rawInitialBody)
                    if chunkedTracker.isFailed {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    initialHeaderOnly.append(rawInitialBody.prefix(consumed))
                    let toSend = IPPUSBHTTPFraming.rewriteResponseHeadWithConnectionClose(
                        initialHeaderOnly,
                        headerEndOffset: head.headerEndOffset
                    )
                    guard sendTCPChunk(toSend, on: connection) else {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    sentAnyToClient = true
                    headerAccum.removeAll(keepingCapacity: false)
                    if chunkedTracker.isComplete { return .completedCleanly }
                } else if let cl = head.contentLength {
                    let take = Int(min(Int64(rawInitialBody.count), cl))
                    initialHeaderOnly.append(rawInitialBody.prefix(take))
                    let toSend = IPPUSBHTTPFraming.rewriteResponseHeadWithConnectionClose(
                        initialHeaderOnly,
                        headerEndOffset: head.headerEndOffset
                    )
                    guard sendTCPChunk(toSend, on: connection) else {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    sentAnyToClient = true
                    bodyBytesForwarded = Int64(take)
                    headerAccum.removeAll(keepingCapacity: false)
                    if bodyBytesForwarded >= cl { return .completedCleanly }
                } else {
                    initialHeaderOnly.append(rawInitialBody)
                    let toSend = IPPUSBHTTPFraming.rewriteResponseHeadWithConnectionClose(
                        initialHeaderOnly,
                        headerEndOffset: head.headerEndOffset
                    )
                    guard sendTCPChunk(toSend, on: connection) else {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    sentAnyToClient = true
                    bodyBytesForwarded = Int64(rawInitialBody.count)
                    headerAccum.removeAll(keepingCapacity: false)
                }
            } else if let head = responseHead {
                if head.isChunked {
                    let consumed = chunkedTracker.feed(chunk)
                    if chunkedTracker.isFailed {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    if consumed > 0 {
                        guard sendTCPChunk(Data(chunk.prefix(consumed)), on: connection) else {
                            return .failed(sentAnyToClient: sentAnyToClient)
                        }
                        sentAnyToClient = true
                    }
                    if chunkedTracker.isComplete { return .completedCleanly }
                } else if let cl = head.contentLength {
                    let remaining = max(0, cl - bodyBytesForwarded)
                    let take = Int(min(Int64(chunk.count), remaining))
                    if take > 0 {
                        guard sendTCPChunk(Data(chunk.prefix(take)), on: connection) else {
                            return .failed(sentAnyToClient: sentAnyToClient)
                        }
                        sentAnyToClient = true
                        bodyBytesForwarded += Int64(take)
                    }
                    if bodyBytesForwarded >= cl { return .completedCleanly }
                } else {
                    guard sendTCPChunk(chunk, on: connection) else {
                        return .failed(sentAnyToClient: sentAnyToClient)
                    }
                    sentAnyToClient = true
                    bodyBytesForwarded += Int64(chunk.count)
                }
            }
        }
    }

    // MARK: - USB Interface Pool & Idle Release

    private func acquireChannel(
        timeout: TimeInterval,
        excluding excludedSlots: inout Set<Int>
    ) throws -> (slot: ChannelSlot, transport: any IPPUSBChannelTransport) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastOpenError: Error?

        while true {
            poolLock.lock()
            idleTimerGeneration &+= 1
            idleTimer?.cancel()
            idleTimer = nil

            while !isStopped {
                let eligible = slots.filter { !excludedSlots.contains($0.index) }
                guard !eligible.isEmpty else {
                    poolLock.unlock()
                    throw lastOpenError ?? IPPUSBBridgeError.noChannelsConfigured
                }

                // Prefer healthy slots (no recent failure within 30s) over degraded slots,
                // and already-open idle slots over cold slots. Never lease a slot that is closing.
                let now = Date()
                let healthy = eligible.filter { slot in
                    guard let failedAt = slot.lastFailedAt else { return true }
                    return now.timeIntervalSince(failedAt) >= 30.0
                }
                let ordered = healthy + eligible.filter { slot in
                    guard let failedAt = slot.lastFailedAt else { return false }
                    return now.timeIntervalSince(failedAt) < 30.0
                }

                let candidate = ordered.first(where: { !$0.inUse && !$0.isClosing && $0.transport != nil })
                    ?? ordered.first(where: { !$0.inUse && !$0.isClosing })

                if let slot = candidate {
                    slot.inUse = true
                    let existing = slot.transport
                    poolLock.unlock()

                    if let existing {
                        return (slot, existing)
                    }

                    // Lazily open the USB interface outside poolLock so other slots aren't blocked.
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
                        slot.lastFailedAt = nil
                        poolLock.unlock()
                        return (slot, opened)
                    } catch {
                        // Mark this slot failed and exclude it, then loop to try remaining USB slots
                        // (crucial for macOS CUPS coexistence when another process owns interface 0).
                        lastOpenError = error
                        excludedSlots.insert(slot.index)
                        poolLock.lock()
                        slot.inUse = false
                        slot.lastFailedAt = Date()
                        poolLock.broadcast()
                        poolLock.unlock()
                        break // re-enter outer while to pick next non-excluded slot
                    }
                }

                if !poolLock.wait(until: deadline) {
                    poolLock.unlock()
                    throw lastOpenError ?? IPPUSBBridgeError.transferFailed("All USB IPP-USB channels are busy.")
                }
            }

            if isStopped {
                poolLock.unlock()
                throw IPPUSBBridgeError.bridgeStopped
            }
        }
    }

    private func releaseChannel(_ slot: ChannelSlot, resetTransport: Bool, markFailed: Bool = false) {
        var transportToReset: (any IPPUSBChannelTransport)?
        poolLock.lock()
        if markFailed {
            slot.lastFailedAt = Date()
        } else {
            slot.lastFailedAt = nil
        }
        if resetTransport, let t = slot.transport {
            transportToReset = t
            slot.isClosing = true
        }
        poolLock.unlock()

        if let transportToReset {
            transportToReset.abortAndReset()
            transportToReset.close()
            poolLock.lock()
            slot.transport = nil
            slot.isClosing = false
            poolLock.unlock()
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
        idleTimerGeneration &+= 1
        let timerGen = idleTimerGeneration
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: listenerQueue)
        timer.schedule(deadline: .now() + idleReleaseSeconds)
        timer.setEventHandler { [weak self] in
            self?.releaseIdleChannels(timerGeneration: timerGen)
        }
        idleTimer = timer
        timer.resume()
    }

    private func releaseIdleChannels(timerGeneration: UInt64) {
        poolLock.lock()
        guard timerGeneration == idleTimerGeneration, !isStopped else {
            poolLock.unlock()
            return
        }
        idleTimer?.cancel()
        idleTimer = nil
        guard !slots.contains(where: { $0.inUse }) else {
            poolLock.unlock()
            return
        }
        var closingSlots: [(ChannelSlot, any IPPUSBChannelTransport)] = []
        for slot in slots where !slot.inUse && !slot.isClosing {
            if let t = slot.transport {
                // Keep slot.isClosing = true until close() finishes so new requests never
                // race to reopen the same USB interface while it's still being destroyed!
                slot.isClosing = true
                closingSlots.append((slot, t))
            }
        }
        poolLock.unlock()

        guard !closingSlots.isEmpty else { return }
        let slotsToClose = closingSlots

        workerQueue.async { [weak self] in
            for (_, transport) in slotsToClose {
                transport.close()
            }
            guard let self else { return }
            self.poolLock.lock()
            for (slot, _) in slotsToClose {
                slot.transport = nil
                slot.isClosing = false
            }
            self.poolLock.broadcast()
            self.poolLock.unlock()
            usbBridgeLog.notice("Released \(slotsToClose.count) idle USB interface(s) for \(self.deviceIdentifier, privacy: .public)")
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
