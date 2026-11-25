import Foundation
import Network
import dnssd

@MainActor
protocol ScannerBrowserProtocol: AnyObject {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)? { get set }
    func start()
    func stop()
    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String)
}

extension ScannerBrowserProtocol {
    func addManualScanner(host: String, port: Int, useTLS: Bool) {
        addManualScanner(host: host, port: port, useTLS: useTLS, rootPath: "eSCL")
    }
}

// MARK: - Scanner Deduplication (USB + Wi-Fi + Manual)

enum ScannerDeduplicator {
    /// Merges Bonjour scanners (Wi-Fi + macOS `ippusbd` loopback USB), direct `USBScannerBrowser`
    /// scanners (`IOUSBHost` + `IPPUSBBridge`), and manually added scanners.
    ///
    /// Rules:
    /// 1. Within Bonjour Wi-Fi, plain HTTP (`_uscan._tcp`) beats HTTPS (`_uscans._tcp`) for the same device.
    /// 2. For the same physical USB scanner (matched by `serialNumber` or `usbLocationID`),
    ///    prefer macOS's `ippusbd` loopback endpoint when present so ChromaScan coexists cleanly with
    ///    macOS CUPS printing without exclusive-access contention; otherwise use direct `IPPUSBBridge`.
    /// 3. Deduplicate Wi-Fi vs USB by `uuid`, `serialNumber`, or unambiguous normalized model name,
    ///    preferring USB whenever plugged in.
    /// 4. Keep all manual scanners untouched.
    /// 5. Sort USB scanners first, then Wi-Fi scanners (alphabetically), then manual scanners.
    static func merge(
        bonjourScanners: [DiscoveredScanner],
        usbScanners: [DiscoveredScanner],
        manualScanners: [DiscoveredScanner]
    ) -> [DiscoveredScanner] {
        // 1. Separate Bonjour USB (macOS ippusbd loopback) from Bonjour Wi-Fi
        let bonjourUSB = bonjourScanners.filter { $0.transport == .usb }
        let bonjourWiFi = bonjourScanners.filter { $0.transport == .wifi }

        // 2. Deduplicate Wi-Fi scanners by UUID (or name), preferring plain HTTP over HTTPS
        var wifiByIdentity: [String: DiscoveredScanner] = [:]
        for scanner in bonjourWiFi {
            let identity = normalizedKey(scanner.uuid) ?? normalizedKey(scanner.name) ?? scanner.id
            if let existing = wifiByIdentity[identity] {
                if existing.useTLS && !scanner.useTLS {
                    wifiByIdentity[identity] = scanner
                }
            } else {
                wifiByIdentity[identity] = scanner
            }
        }
        let dedupedWiFi = Array(wifiByIdentity.values)

        // 3. Merge USB sources: start with macOS ippusbd loopback USB scanners, then add direct
        //    IOUSBHost scanners that aren't already represented by an ippusbd entry.
        var mergedUSB: [DiscoveredScanner] = []
        for s in bonjourUSB {
            if !mergedUSB.contains(where: { isSameUSBDevice($0, s) }) {
                mergedUSB.append(s)
            }
        }
        for direct in usbScanners {
            if !mergedUSB.contains(where: { isSameUSBDevice($0, direct) }) {
                mergedUSB.append(direct)
            }
        }

        // 4. Filter out Wi-Fi scanners that duplicate an already-attached USB scanner
        let filteredWiFi = dedupedWiFi.filter { wifi in
            !mergedUSB.contains(where: { usb in isSamePhysicalScanner(usb: usb, wifi: wifi) })
        }

        // 5. Sort: USB first, then Wi-Fi, then manual
        let sortedUSB = mergedUSB.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        let sortedWiFi = filteredWiFi.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        return sortedUSB + sortedWiFi + manualScanners
    }

    private static func isSameUSBDevice(_ a: DiscoveredScanner, _ b: DiscoveredScanner) -> Bool {
        if let snA = normalizedKey(a.serialNumber), let snB = normalizedKey(b.serialNumber), snA == snB {
            return true
        }
        if let locA = a.usbLocationID, let locB = b.usbLocationID, locA != 0, locA == locB {
            return true
        }
        if let uA = normalizedKey(a.uuid), let uB = normalizedKey(b.uuid), uA == uB {
            return true
        }
        return a.id == b.id
    }

    private static func isSamePhysicalScanner(usb: DiscoveredScanner, wifi: DiscoveredScanner) -> Bool {
        // Strong match 1: identical UUID
        if let uUSB = normalizedKey(usb.uuid), let uWiFi = normalizedKey(wifi.uuid) {
            return uUSB == uWiFi
        }
        // Strong match 2: identical serial number
        if let snUSB = normalizedKey(usb.serialNumber), let snWiFi = normalizedKey(wifi.serialNumber) {
            return snUSB == snWiFi
        }
        // Fallback match 3: direct IOUSBHost scanner (no UUID) vs Wi-Fi scanner (no serialNumber)
        // sharing the same normalized model/product name (e.g. "HP OfficeJet 3830 series" vs
        // "HP OfficeJet 3830 series [1CE486]"). Only applies when neither pair has conflicting IDs.
        if let mUSB = normalizedModelName(usb.modelName ?? usb.name),
           let mWiFi = normalizedModelName(wifi.modelName ?? wifi.name),
           !mUSB.isEmpty,
           mUSB == mWiFi {
            return true
        }
        return false
    }

    private static func normalizedKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedModelName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing "(USB)" or "(Manual)"
        for suffix in ["(usb)", "(manual)"] {
            if s.lowercased().hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Strip Bonjour MAC/instance bracket suffix like " [1CE486]"
        if let open = s.lastIndex(of: "["), let close = s.lastIndex(of: "]"), open < close, close == s.index(before: s.endIndex) {
            s = String(s[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let collapsed = s
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

// MARK: - Composite Scanner Browser (USB + Bonjour Wi-Fi + Manual)

/// Unified scanner browser combining direct USB (`USBScannerBrowser` / `IOUSBHost`),
/// Bonjour Wi-Fi & macOS `ippusbd` loopback discovery (`BonjourScannerBrowser`),
/// and user-added manual scanners.
@MainActor
final class CompositeScannerBrowser: ScannerBrowserProtocol {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?

    private let bonjourBrowser: BonjourScannerBrowser
    private let usbBrowser: USBScannerBrowser

    private var bonjourScanners: [DiscoveredScanner] = []
    private var usbScanners: [DiscoveredScanner] = []
    private var manualScanners: [DiscoveredScanner] = []
    private var lastPublishedScanners: [DiscoveredScanner]?

    init(
        bonjourBrowser: BonjourScannerBrowser? = nil,
        usbBrowser: USBScannerBrowser? = nil
    ) {
        let bonjour = bonjourBrowser ?? BonjourScannerBrowser()
        let usb = usbBrowser ?? USBScannerBrowser()
        self.bonjourBrowser = bonjour
        self.usbBrowser = usb

        bonjour.onScannersChanged = { [weak self] found in
            guard let self else { return }
            self.bonjourScanners = found.filter { $0.transport != .manual }
            self.publishMerged()
        }
        usb.onScannersChanged = { [weak self] found in
            guard let self else { return }
            self.usbScanners = found
            self.publishMerged()
        }
    }

    func start() {
        bonjourScanners.removeAll()
        usbScanners.removeAll()
        lastPublishedScanners = nil
        usbBrowser.start()
        bonjourBrowser.start()
        publishMerged()
    }

    func stop() {
        bonjourBrowser.stop()
        usbBrowser.stop()
    }

    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String = "eSCL") {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return }
        let scanner = DiscoveredScanner(
            id: "manual:\(cleanHost):\(port):\(useTLS)",
            name: "\(cleanHost) (Manual)",
            host: cleanHost,
            port: port,
            useTLS: useTLS,
            rootPath: rootPath,
            modelName: nil,
            uuid: nil,
            transport: .manual
        )
        manualScanners.removeAll { $0.id == scanner.id }
        manualScanners.append(scanner)
        publishMerged()
    }

    private func publishMerged() {
        let merged = ScannerDeduplicator.merge(
            bonjourScanners: bonjourScanners,
            usbScanners: usbScanners,
            manualScanners: manualScanners
        )
        guard merged != lastPublishedScanners else { return }
        lastPublishedScanners = merged
        onScannersChanged?(merged)
    }
}

// MARK: - Interface-Aware Bonjour Scanner Browser (`_uscan._tcp` & `_uscans._tcp`)

/// Discovers eSCL (AirScan) scanners over Bonjour (`_uscan._tcp` and `_uscans._tcp`)
/// on a per-interface basis so both Wi-Fi scanners and macOS's built-in `ippusbd` USB loopback
/// endpoints (`interfaceIndex == kDNSServiceInterfaceIndexLocalOnly`) are discovered cleanly.
@MainActor
final class BonjourScannerBrowser: ScannerBrowserProtocol {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?

    private var httpBrowseSession: DNSSDBrowseSession?
    private var httpsBrowseSession: DNSSDBrowseSession?

    // Keyed by "\(type)|\(interfaceIndex)|\(name)|\(domain)"
    private var resolvedByKey: [String: DiscoveredScanner] = [:]
    private var pendingResolveKeys: Set<String> = []
    private var manualScanners: [DiscoveredScanner] = []
    private var generation: UInt64 = 0

    func start() {
        stop()
        generation &+= 1
        let currentGen = generation
        resolvedByKey.removeAll()
        pendingResolveKeys.removeAll()

        httpBrowseSession = makeBrowseSession(type: "_uscan._tcp", useTLS: false, generation: currentGen)
        httpsBrowseSession = makeBrowseSession(type: "_uscans._tcp", useTLS: true, generation: currentGen)
        httpBrowseSession?.start()
        httpsBrowseSession?.start()
    }

    func stop() {
        generation &+= 1
        httpBrowseSession?.stop()
        httpBrowseSession = nil
        httpsBrowseSession?.stop()
        httpsBrowseSession = nil
        pendingResolveKeys.removeAll()
    }

    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String = "eSCL") {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return }
        let scanner = DiscoveredScanner(
            id: "manual:\(cleanHost):\(port):\(useTLS)",
            name: "\(cleanHost) (Manual)",
            host: cleanHost,
            port: port,
            useTLS: useTLS,
            rootPath: rootPath,
            modelName: nil,
            uuid: nil,
            transport: .manual
        )
        manualScanners.removeAll { $0.id == scanner.id }
        manualScanners.append(scanner)
        publishMerged()
    }

    private func makeBrowseSession(type: String, useTLS: Bool, generation: UInt64) -> DNSSDBrowseSession {
        DNSSDBrowseSession(serviceType: type) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.handleBrowseEvent(event, serviceType: type, useTLS: useTLS, generation: generation)
            }
        }
    }

    private func handleBrowseEvent(
        _ event: DNSSDBrowseSession.Event,
        serviceType: String,
        useTLS: Bool,
        generation: UInt64
    ) {
        let key = "\(serviceType)|\(event.interfaceIndex)|\(event.name)|\(event.domain)"
        if event.isAdd {
            guard resolvedByKey[key] == nil, !pendingResolveKeys.contains(key) else { return }
            pendingResolveKeys.insert(key)
            resolveService(
                name: event.name,
                type: event.regtype,
                domain: event.domain,
                interfaceIndex: event.interfaceIndex,
                useTLS: useTLS,
                key: key,
                generation: generation
            )
        } else {
            pendingResolveKeys.remove(key)
            if resolvedByKey.removeValue(forKey: key) != nil {
                publishMerged()
            }
        }
    }

    private func resolveService(
        name: String,
        type: String,
        domain: String,
        interfaceIndex: UInt32,
        useTLS: Bool,
        key: String,
        generation: UInt64
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = DNSSDResolver.resolve(
                name: name,
                type: type,
                domain: domain,
                interfaceIndex: interfaceIndex,
                timeout: 4.0
            )
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.pendingResolveKeys.remove(key)
                guard let resolved else { return }

                let txt = resolved.txtRecord
                let rawHost = resolved.host
                let cleanHostLower = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                let isLoopbackUSB = (interfaceIndex == kDNSServiceInterfaceIndexLocalOnly)
                    || cleanHostLower == "localhost"
                    || cleanHostLower == "127.0.0.1"
                    || txt["usb_sn"] != nil
                    || txt["usb_loc"] != nil

                let rootPath = txt["rs"]?.isEmpty == false ? txt["rs"]! : "eSCL"
                let model = txt["ty"]
                let uuid = txt["uuid"]
                let serial = txt["usb_sn"]
                let locID = txt["usb_loc"].flatMap { UInt32($0) }

                let scanner: DiscoveredScanner
                if isLoopbackUSB {
                    // Use 127.0.0.1 directly for macOS ippusbd loopback to avoid IPv6 localhost lookup latency
                    let usbHost = (cleanHostLower == "localhost") ? "127.0.0.1" : rawHost
                    let baseLabel = (model?.isEmpty == false ? model! : name)
                    let displayName = DiscoveredScanner.usbDisplayName(vendor: nil, product: baseLabel)
                    let idSuffix = serial ?? uuid ?? "\(usbHost):\(resolved.port)"
                    scanner = DiscoveredScanner(
                        id: "usb:\(idSuffix)",
                        name: displayName,
                        host: usbHost,
                        port: resolved.port,
                        useTLS: false,
                        rootPath: rootPath,
                        modelName: model ?? name,
                        uuid: uuid,
                        transport: .usb,
                        serialNumber: serial,
                        usbLocationID: locID
                    )
                } else {
                    scanner = DiscoveredScanner(
                        id: uuid ?? "\(name):\(rawHost):\(resolved.port):\(useTLS)",
                        name: name,
                        host: rawHost,
                        port: resolved.port,
                        useTLS: useTLS,
                        rootPath: rootPath,
                        modelName: model,
                        uuid: uuid,
                        transport: .wifi,
                        serialNumber: nil,
                        usbLocationID: nil
                    )
                }

                self.resolvedByKey[key] = scanner
                self.publishMerged()
            }
        }
    }

    private func publishMerged() {
        let merged = ScannerDeduplicator.merge(
            bonjourScanners: Array(resolvedByKey.values),
            usbScanners: [],
            manualScanners: manualScanners
        )
        onScannersChanged?(merged)
    }
}

// MARK: - Interface-Aware DNSServiceBrowse Session

private final class DNSSDBrowseSession: @unchecked Sendable {
    struct Event: Sendable {
        let isAdd: Bool
        let interfaceIndex: UInt32
        let name: String
        let regtype: String
        let domain: String
    }

    private let serviceType: String
    private let onEvent: @Sendable (Event) -> Void
    private let queue: DispatchQueue
    private var sdRef: DNSServiceRef?
    private var readSource: DispatchSourceRead?
    private var callbackContext: Unmanaged<DNSSDBrowseSession>?

    init(serviceType: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.serviceType = serviceType
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "com.chromascan.bonjour.\(serviceType)")
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        stopOnQueue()

        let retained = Unmanaged.passRetained(self)
        var ref: DNSServiceRef?
        let callback: DNSServiceBrowseReply = { _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
            guard errorCode == kDNSServiceErr_NoError,
                  let context,
                  let serviceName,
                  let regtype,
                  let replyDomain else { return }
            let session = Unmanaged<DNSSDBrowseSession>.fromOpaque(context).takeUnretainedValue()
            let isAdd = (flags & kDNSServiceFlagsAdd) != 0
            let event = Event(
                isAdd: isAdd,
                interfaceIndex: interfaceIndex,
                name: String(cString: serviceName),
                regtype: String(cString: regtype),
                domain: String(cString: replyDomain)
            )
            session.onEvent(event)
        }

        let err = DNSServiceBrowse(
            &ref,
            0,
            0,
            serviceType,
            "local.",
            callback,
            retained.toOpaque()
        )
        guard err == kDNSServiceErr_NoError, let activeRef = ref else {
            retained.release()
            return
        }

        self.callbackContext = retained
        self.sdRef = activeRef

        let fd = DNSServiceRefSockFD(activeRef)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let r = self.sdRef else { return }
            let procErr = DNSServiceProcessResult(r)
            if procErr != kDNSServiceErr_NoError {
                self.stopOnQueue()
            }
        }
        source.setCancelHandler {
            // sdRef deallocated in stopOnQueue
        }
        self.readSource = source
        source.resume()
    }

    private func stopOnQueue() {
        if let source = readSource {
            readSource = nil
            source.cancel()
        }
        if let ref = sdRef {
            sdRef = nil
            DNSServiceRefDeallocate(ref)
        }
        if let ctx = callbackContext {
            callbackContext = nil
            ctx.release()
        }
    }
}

// MARK: - Synchronous one-shot dnssd service resolver (with TXT record parsing)

private enum DNSSDResolver {
    struct Result: Sendable {
        let host: String
        let port: Int
        let txtRecord: [String: String]
    }

    private final class Context {
        var result: Result?
        var done = false
    }

    static func resolve(
        name: String,
        type: String,
        domain: String,
        interfaceIndex: UInt32,
        timeout: TimeInterval
    ) -> Result? {
        let ctx = Context()
        let unmanaged = Unmanaged.passRetained(ctx)
        defer { unmanaged.release() }

        var sdRef: DNSServiceRef?
        let callback: DNSServiceResolveReply = { _, _, _, errorCode, _, hosttarget, port, txtLen, txtRecord, context in
            guard let context else { return }
            let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            if errorCode == kDNSServiceErr_NoError, let hosttarget {
                let hostStr = String(cString: hosttarget)
                let hostPort = Int(UInt16(bigEndian: port))
                let txt = DNSSDResolver.parseTXTRecord(txtRecord, length: Int(txtLen))
                box.result = Result(host: hostStr, port: hostPort, txtRecord: txt)
            }
            box.done = true
        }

        let err = DNSServiceResolve(
            &sdRef,
            0,
            interfaceIndex,
            name,
            type,
            domain,
            callback,
            unmanaged.toOpaque()
        )
        guard err == kDNSServiceErr_NoError, let ref = sdRef else { return nil }
        defer { DNSServiceRefDeallocate(ref) }

        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while !ctx.done {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, min(250, remaining * 1000)))
            let ready = poll(&pfd, 1, ms)
            if ready > 0 {
                let procErr = DNSServiceProcessResult(ref)
                if procErr != kDNSServiceErr_NoError { break }
            } else if ready < 0 {
                break
            }
        }
        return ctx.result
    }

    private static func parseTXTRecord(_ bytes: UnsafePointer<UInt8>?, length: Int) -> [String: String] {
        guard let bytes, length > 0 else { return [:] }
        var dict: [String: String] = [:]
        var offset = 0
        while offset < length {
            let entryLen = Int(bytes[offset])
            offset += 1
            guard entryLen > 0, offset + entryLen <= length else { break }
            let entryData = Data(bytes: bytes.advanced(by: offset), count: entryLen)
            offset += entryLen
            guard let entryStr = String(data: entryData, encoding: .utf8) else { continue }
            if let eqIdx = entryStr.firstIndex(of: "=") {
                let key = String(entryStr[..<eqIdx]).lowercased()
                let value = String(entryStr[entryStr.index(after: eqIdx)...])
                dict[key] = value
            }
        }
        return dict
    }
}
