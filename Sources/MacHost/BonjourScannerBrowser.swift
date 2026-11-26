import Foundation
import Network
import dnssd

@MainActor
protocol ScannerBrowserProtocol: AnyObject {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
    func addManualScanner(host: String, port: Int, useTLS: Bool, rootPath: String)
    /// The network (Wi-Fi/LAN) endpoint of the same physical scanner as a USB `scanner`, if one is
    /// currently advertised. Used to fall back from a slow USB transfer.
    func networkCounterpart(for scanner: DiscoveredScanner) -> DiscoveredScanner?
}

extension ScannerBrowserProtocol {
    func networkCounterpart(for scanner: DiscoveredScanner) -> DiscoveredScanner? { nil }

    func refresh() {
        start()
    }

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
    /// 1. Within Bonjour Wi-Fi and Bonjour USB, plain HTTP (`_uscan._tcp`) beats HTTPS (`_uscans._tcp`)
    ///    deterministically for the same device.
    /// 2. For the same physical USB scanner (matched by `serialNumber`, `usbLocationID`, or `uuid`),
    ///    prefer macOS's `ippusbd` loopback endpoint when present so ChromaScan coexists cleanly with
    ///    macOS CUPS printing without exclusive-access contention; otherwise use direct `IPPUSBBridge`.
    /// 3. Deduplicate Wi-Fi vs USB by `uuid` or `serialNumber`, or by normalized model name ONLY when
    ///    unambiguous (exactly one USB and one Wi-Fi scanner share that model with no conflicting IDs),
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

        // 2. Deduplicate Wi-Fi scanners by UUID (or name), deterministically preferring plain HTTP over HTTPS
        var wifiByIdentity: [String: DiscoveredScanner] = [:]
        for scanner in bonjourWiFi {
            let identity = normalizedKey(scanner.uuid) ?? normalizedKey(scanner.name) ?? scanner.id
            if let existing = wifiByIdentity[identity] {
                if shouldPrefer(scanner, over: existing) {
                    wifiByIdentity[identity] = scanner
                }
            } else {
                wifiByIdentity[identity] = scanner
            }
        }
        let dedupedWiFi = Array(wifiByIdentity.values)

        // 3. Merge USB sources: deterministically prefer plain HTTP within Bonjour USB, then add
        //    direct IOUSBHost scanners not already represented by an ippusbd entry.
        var mergedUSB: [DiscoveredScanner] = []
        for s in bonjourUSB {
            if let idx = mergedUSB.firstIndex(where: { isSameUSBDevice($0, s) }) {
                if shouldPrefer(s, over: mergedUSB[idx]) {
                    mergedUSB[idx] = s
                }
            } else {
                mergedUSB.append(s)
            }
        }
        for direct in usbScanners {
            if !mergedUSB.contains(where: { isSameUSBDevice($0, direct) }) {
                mergedUSB.append(direct)
            }
        }

        // Pre-compute normalized model counts for unambiguous fallback matching when direct USB lacks UUID
        var usbModelCounts: [String: Int] = [:]
        for usb in mergedUSB {
            if let m = normalizedModelName(usb.modelName ?? usb.name) {
                usbModelCounts[m, default: 0] += 1
            }
        }
        var wifiModelCounts: [String: Int] = [:]
        for wifi in dedupedWiFi {
            if let m = normalizedModelName(wifi.modelName ?? wifi.name) {
                wifiModelCounts[m, default: 0] += 1
            }
        }

        // 4. Filter out Wi-Fi scanners that duplicate an already-attached USB scanner
        let filteredWiFi = dedupedWiFi.filter { wifi in
            !mergedUSB.contains(where: { usb in
                isSamePhysicalScanner(
                    usb: usb,
                    wifi: wifi,
                    usbModelCounts: usbModelCounts,
                    wifiModelCounts: wifiModelCounts
                )
            })
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

    /// The best network (Wi-Fi) endpoint among `bonjourScanners` for the same physical scanner as `usb`
    /// (same matching rules used to hide Wi-Fi duplicates of attached USB scanners), preferring plain HTTP.
    static func networkCounterpart(for usb: DiscoveredScanner, among bonjourScanners: [DiscoveredScanner]) -> DiscoveredScanner? {
        guard usb.transport == .usb else { return nil }
        let wifi = bonjourScanners.filter { $0.transport == .wifi }
        guard !wifi.isEmpty else { return nil }
        var wifiModelCounts: [String: Int] = [:]
        for w in wifi {
            if let m = normalizedModelName(w.modelName ?? w.name) { wifiModelCounts[m, default: 0] += 1 }
        }
        // Count each physical Wi-Fi device once (HTTP and HTTPS adverts of one printer are one device).
        var deviceKeys: [String: Set<String>] = [:]
        for w in wifi {
            if let m = normalizedModelName(w.modelName ?? w.name) {
                deviceKeys[m, default: []].insert(normalizedKey(w.uuid) ?? normalizedKey(w.name) ?? w.id)
            }
        }
        for (m, keys) in deviceKeys { wifiModelCounts[m] = keys.count }
        var usbModelCounts: [String: Int] = [:]
        if let m = normalizedModelName(usb.modelName ?? usb.name) { usbModelCounts[m] = 1 }

        let matches = wifi.filter {
            isSamePhysicalScanner(usb: usb, wifi: $0, usbModelCounts: usbModelCounts, wifiModelCounts: wifiModelCounts)
        }
        return matches.reduce(nil as DiscoveredScanner?) { best, candidate in
            guard let best else { return candidate }
            return shouldPrefer(candidate, over: best) ? candidate : best
        }
    }

    private static func shouldPrefer(_ candidate: DiscoveredScanner, over existing: DiscoveredScanner) -> Bool {
        // Always prefer plain HTTP over HTTPS on local LAN / loopback to avoid TLS overhead & cert friction
        if existing.useTLS && !candidate.useTLS { return true }
        if !existing.useTLS && candidate.useTLS { return false }
        // Deterministic tie-breaker by host + port
        if candidate.host != existing.host { return candidate.host < existing.host }
        return candidate.port < existing.port
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

    private static func isSamePhysicalScanner(
        usb: DiscoveredScanner,
        wifi: DiscoveredScanner,
        usbModelCounts: [String: Int],
        wifiModelCounts: [String: Int]
    ) -> Bool {
        // Strong match 1: both have UUIDs -> authoritative comparison
        if let uUSB = normalizedKey(usb.uuid), let uWiFi = normalizedKey(wifi.uuid) {
            return uUSB == uWiFi
        }
        // Strong match 2: both have serial numbers -> authoritative comparison
        if let snUSB = normalizedKey(usb.serialNumber), let snWiFi = normalizedKey(wifi.serialNumber) {
            return snUSB == snWiFi
        }
        // Fallback match 3: direct IOUSBHost scanner (no UUID) vs Wi-Fi scanner (no serialNumber)
        // sharing the same normalized model name ONLY when unambiguous (1 USB and 1 Wi-Fi of that model).
        if let mUSB = normalizedModelName(usb.modelName ?? usb.name),
           let mWiFi = normalizedModelName(wifi.modelName ?? wifi.name),
           !mUSB.isEmpty,
           mUSB == mWiFi,
           usbModelCounts[mUSB] == 1,
           wifiModelCounts[mWiFi] == 1 {
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
        for suffix in ["(usb)", "(manual)"] {
            if s.lowercased().hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
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
        // Do not emit an artificial empty list before initial discovery results arrive.
    }

    /// Non-destructive refresh: re-scans USB additively (preserving live IPPUSBBridge instances
    /// and ports) and refreshes Bonjour discovery without flashing an empty scanner list.
    func refresh() {
        usbBrowser.refresh()
        bonjourBrowser.refresh()
    }

    func stop() {
        bonjourBrowser.stop()
        usbBrowser.stop()
    }

    func networkCounterpart(for scanner: DiscoveredScanner) -> DiscoveredScanner? {
        // Use the raw resolved adverts: the Bonjour browser's published list has already had Wi-Fi
        // duplicates of the attached USB printer removed, which is exactly the entry we need here.
        ScannerDeduplicator.networkCounterpart(for: scanner, among: bonjourBrowser.allResolvedScanners)
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
    private var activeTokenByKey: [String: UInt64] = [:]
    private var nextResolveToken: UInt64 = 0
    private var manualScanners: [DiscoveredScanner] = []
    private var generation: UInt64 = 0

    func start() {
        stop()
        generation &+= 1
        let currentGen = generation
        resolvedByKey.removeAll()
        activeTokenByKey.removeAll()

        httpBrowseSession = makeBrowseSession(type: "_uscan._tcp", useTLS: false, generation: currentGen)
        httpsBrowseSession = makeBrowseSession(type: "_uscans._tcp", useTLS: true, generation: currentGen)
        httpBrowseSession?.start()
        httpsBrowseSession?.start()
    }

    func refresh() {
        // Restart browse sessions cleanly; keep existing resolvedByKey until new events settle
        // or let fresh add events update entries without flashing an empty list.
        start()
    }

    func stop() {
        generation &+= 1
        httpBrowseSession?.stop()
        httpBrowseSession = nil
        httpsBrowseSession?.stop()
        httpsBrowseSession = nil
        activeTokenByKey.removeAll()
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

    /// Pure classification helper turning a resolved Bonjour service into a `DiscoveredScanner`.
    /// Establishes loopback USB strictly from the endpoint (`kDNSServiceInterfaceIndexLocalOnly`
    /// or loopback host) rather than TXT metadata alone, and preserves `useTLS` from the service type.
    nonisolated static func makeDiscoveredScanner(
        serviceName: String,
        host: String,
        port: Int,
        interfaceIndex: UInt32,
        useTLS: Bool,
        txt: [String: String]
    ) -> DiscoveredScanner {
        let cleanHostLower = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let isLocalOnlyInterface = (interfaceIndex == kDNSServiceInterfaceIndexLocalOnly)
        let isLoopbackHost = (cleanHostLower == "localhost" || cleanHostLower == "127.0.0.1" || cleanHostLower == "::1")
        let isLoopbackUSB = isLocalOnlyInterface || isLoopbackHost

        let rootPath = txt["rs"]?.isEmpty == false ? txt["rs"]! : "eSCL"
        let model = txt["ty"]
        let uuid = txt["uuid"]
        let serial = txt["usb_sn"]
        let locID = txt["usb_loc"].flatMap { UInt32($0) }

        if isLoopbackUSB {
            // Force 127.0.0.1 for LocalOnly / localhost services to guarantee loopback routing
            // and avoid IPv6 Happy Eyeballs latency on macOS ippusbd.
            let usbHost = (isLocalOnlyInterface || cleanHostLower == "localhost") ? "127.0.0.1" : host
            let baseLabel = (model?.isEmpty == false ? model! : serviceName)
            let displayName = DiscoveredScanner.usbDisplayName(vendor: nil, product: baseLabel)
            let idSuffix = serial ?? uuid ?? "\(usbHost):\(port)"
            return DiscoveredScanner(
                id: "usb:\(idSuffix)",
                name: displayName,
                host: usbHost,
                port: port,
                useTLS: useTLS,
                rootPath: rootPath,
                modelName: model ?? serviceName,
                uuid: uuid,
                transport: .usb,
                serialNumber: serial,
                usbLocationID: locID
            )
        }

        return DiscoveredScanner(
            id: uuid ?? "\(serviceName):\(host):\(port):\(useTLS)",
            name: serviceName,
            host: host,
            port: port,
            useTLS: useTLS,
            rootPath: rootPath,
            modelName: model,
            uuid: uuid,
            transport: .wifi,
            serialNumber: serial,
            usbLocationID: nil
        )
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
            // Assign a fresh per-add token so any stale in-flight resolve from before a remove
            // or port change cannot resurrect an old entry or overwrite a newer one.
            nextResolveToken &+= 1
            let token = nextResolveToken
            activeTokenByKey[key] = token
            resolveService(
                name: event.name,
                type: event.regtype,
                domain: event.domain,
                interfaceIndex: event.interfaceIndex,
                useTLS: useTLS,
                key: key,
                generation: generation,
                token: token
            )
        } else {
            activeTokenByKey.removeValue(forKey: key)
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
        generation: UInt64,
        token: UInt64
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
                guard let self,
                      self.generation == generation,
                      self.activeTokenByKey[key] == token else { return }
                guard let resolved else { return }

                let scanner = Self.makeDiscoveredScanner(
                    serviceName: name,
                    host: resolved.host,
                    port: resolved.port,
                    interfaceIndex: interfaceIndex,
                    useTLS: useTLS,
                    txt: resolved.txtRecord
                )
                self.resolvedByKey[key] = scanner
                self.publishMerged()
            }
        }
    }

    /// Every resolved advert (Wi-Fi and ippusbd loopback), before deduplication.
    var allResolvedScanners: [DiscoveredScanner] { Array(resolvedByKey.values) }

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

/// Wraps a `DNSServiceBrowse` handle with libdispatch-safe fd lifecycle:
/// `DNSServiceRefDeallocate` and the `Unmanaged` callback context release happen strictly inside
/// the `DispatchSourceRead` cancel handler so the socket fd is never closed while registered with kqueue.
/// Automatically retries with backoff if `mDNSResponder` disconnects.
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
    private var retryWorkItem: DispatchWorkItem?
    private var isActive = false

    init(serviceType: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.serviceType = serviceType
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "com.chromascan.bonjour.\(serviceType)")
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isActive = true
            self.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isActive = false
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.tearDownSourceOnQueue()
        }
    }

    private func startOnQueue() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        tearDownSourceOnQueue()
        guard isActive else { return }

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
            scheduleRetryOnQueue()
            return
        }

        self.sdRef = activeRef
        let fd = DNSServiceRefSockFD(activeRef)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.sdRef == activeRef else { return }
            let procErr = DNSServiceProcessResult(activeRef)
            if procErr != kDNSServiceErr_NoError {
                self.tearDownSourceOnQueue()
                self.scheduleRetryOnQueue()
            }
        }
        // Strictly own fd teardown & context release in the cancel handler per libdispatch contract.
        source.setCancelHandler {
            DNSServiceRefDeallocate(activeRef)
            retained.release()
        }
        self.readSource = source
        source.resume()
    }

    private func tearDownSourceOnQueue() {
        sdRef = nil
        if let source = readSource {
            readSource = nil
            source.cancel()
        }
    }

    private func scheduleRetryOnQueue() {
        guard isActive else { return }
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.startOnQueue()
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + 2.0, execute: item)
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
