import Foundation
import Network
import Observation

struct DiscoveredHost: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let hostID: String?
    let scannerName: String?
    let protocolVersion: Int

    static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.hostID == rhs.hostID
            && lhs.scannerName == rhs.scannerName
            && lhs.protocolVersion == rhs.protocolVersion
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Discovers Mac Studio ChromaScan hosts over Bonjour (`_chromascan._tcp`).
@Observable
@MainActor
final class HostBrowser {
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var isSearching: Bool = false
    private(set) var browseError: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.chromascan.remote.browser")

    func start() {
        stop()
        browseError = nil
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: CompanionConstants.bonjourServiceType,
                domain: CompanionConstants.bonjourDomain
            ),
            using: params
        )

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                    self.browseError = nil
                case .failed(let err):
                    self.isSearching = false
                    self.browseError = err.localizedDescription
                case .waiting(let err):
                    self.browseError = err.localizedDescription
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }

        self.browser = newBrowser
        newBrowser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredHost] = []

        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for key in record.dictionary.keys {
                    if let val = record.dictionary[key] {
                        txt[key.lowercased()] = val
                    }
                }
            }
            let hostID = txt["id"]
            let scanner = txt["scanner"]
            let version = Int(txt["v"] ?? "1") ?? 1
            let stableID = hostID ?? "\(type)|\(name)|\(domain)"
            found.append(DiscoveredHost(
                id: stableID,
                name: name,
                endpoint: result.endpoint,
                hostID: hostID,
                scannerName: scanner,
                protocolVersion: version
            ))
        }

        hosts = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
