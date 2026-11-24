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

/// Discovers eSCL (AirScan) scanners over Bonjour (`_uscan._tcp` and `_uscans._tcp`)
/// and resolves each service's exact hostname, port, and TXT metadata.
@MainActor
final class BonjourScannerBrowser: ScannerBrowserProtocol {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?

    private var httpBrowser: NWBrowser?
    private var httpsBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "com.chromascan.bonjour")

    // Keyed by "\(type)|\(name)|\(domain)"
    private var resolvedByKey: [String: DiscoveredScanner] = [:]
    private var manualScanners: [DiscoveredScanner] = []

    func start() {
        stop()
        resolvedByKey.removeAll()

        httpBrowser = makeBrowser(type: "_uscan._tcp", useTLS: false)
        httpsBrowser = makeBrowser(type: "_uscans._tcp", useTLS: true)
        httpBrowser?.start(queue: queue)
        httpsBrowser?.start(queue: queue)
    }

    func stop() {
        httpBrowser?.cancel()
        httpBrowser = nil
        httpsBrowser?.cancel()
        httpsBrowser = nil
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
            uuid: nil
        )
        manualScanners.removeAll { $0.id == scanner.id }
        manualScanners.append(scanner)
        publishMerged()
    }

    private func makeBrowser(type: String, useTLS: Bool) -> NWBrowser {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results, serviceType: type, useTLS: useTLS)
            }
        }
        return browser
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, serviceType: String, useTLS: Bool) {
        var activeKeys = Set<String>()

        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let key = "\(type)|\(name)|\(domain)"
            activeKeys.insert(key)

            var txtDict: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for entryKey in record.dictionary.keys {
                    if let val = record.dictionary[entryKey] {
                        txtDict[entryKey.lowercased()] = val
                    }
                }
            }

            if resolvedByKey[key] == nil {
                resolveService(name: name, type: type, domain: domain, useTLS: useTLS, txt: txtDict, key: key)
            }
        }

        // Remove keys for this serviceType that disappeared
        let prefix = "\(serviceType)|"
        for existingKey in Array(resolvedByKey.keys) where existingKey.hasPrefix(prefix) {
            if !activeKeys.contains(existingKey) {
                resolvedByKey.removeValue(forKey: existingKey)
            }
        }
        publishMerged()
    }

    private func resolveService(name: String, type: String, domain: String, useTLS: Bool, txt: [String: String], key: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = DNSSDResolver.resolve(name: name, type: type, domain: domain, timeout: 4.0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let host: String
                let port: Int
                if let resolved {
                    host = resolved.host
                    port = resolved.port
                } else if let adminURLString = txt["adminurl"], let adminURL = URL(string: adminURLString), let h = adminURL.host {
                    host = h
                    port = useTLS ? 443 : 8080
                } else {
                    return
                }

                let rootPath = txt["rs"]?.isEmpty == false ? txt["rs"]! : "eSCL"
                let model = txt["ty"]
                let uuid = txt["uuid"]
                let scanner = DiscoveredScanner(
                    id: uuid ?? "\(name):\(host):\(port):\(useTLS)",
                    name: name,
                    host: host,
                    port: port,
                    useTLS: useTLS,
                    rootPath: rootPath,
                    modelName: model,
                    uuid: uuid
                )
                self.resolvedByKey[key] = scanner
                self.publishMerged()
            }
        }
    }

    private func publishMerged() {
        // Deduplicate by UUID (or name), preferring plain HTTP (_uscan._tcp) over HTTPS (_uscans._tcp)
        // because local Wi-Fi HTTP streaming avoids TLS CPU overhead and self-signed cert friction.
        var bestByIdentity: [String: DiscoveredScanner] = [:]
        for scanner in resolvedByKey.values {
            let identity = scanner.uuid ?? scanner.name
            if let existing = bestByIdentity[identity] {
                if existing.useTLS && !scanner.useTLS {
                    bestByIdentity[identity] = scanner
                }
            } else {
                bestByIdentity[identity] = scanner
            }
        }
        var combined = Array(bestByIdentity.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        combined.append(contentsOf: manualScanners)
        onScannersChanged?(combined)
    }
}

// MARK: - Synchronous one-shot dnssd service resolver

private enum DNSSDResolver {
    struct Result: Sendable {
        let host: String
        let port: Int
    }

    private final class Context {
        var result: Result?
        var done = false
    }

    static func resolve(name: String, type: String, domain: String, timeout: TimeInterval) -> Result? {
        let ctx = Context()
        let unmanaged = Unmanaged.passRetained(ctx)
        defer { unmanaged.release() }

        var sdRef: DNSServiceRef?
        let callback: DNSServiceResolveReply = { _, _, _, errorCode, _, hosttarget, port, _, _, context in
            guard let context else { return }
            let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            if errorCode == kDNSServiceErr_NoError, let hosttarget {
                let hostStr = String(cString: hosttarget)
                let hostPort = Int(UInt16(bigEndian: port))
                box.result = Result(host: hostStr, port: hostPort)
            }
            box.done = true
        }

        let err = DNSServiceResolve(
            &sdRef,
            0,
            0,
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
}
