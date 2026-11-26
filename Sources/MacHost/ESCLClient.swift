import Foundation
import os

/// Scan transfer diagnostics. View with:
/// `log stream --predicate 'subsystem == "com.chromascan.transfer"'` (or `log show --last 1h ...`).
let transferLog = Logger(subsystem: "com.chromascan.transfer", category: "escl")

enum ESCLClientError: Error, LocalizedError {
    case httpError(Int, String)
    case missingJobLocation
    case cancelled
    case emptyDocument
    case invalidImageData(String)
    case scannerNotResponding(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg): return "Scanner returned HTTP \(code): \(msg)"
        case .missingJobLocation: return "Scanner did not return a ScanJob Location header."
        case .cancelled: return "Scan cancelled."
        case .emptyDocument: return "Scanner returned an empty document."
        case .invalidImageData(let detail): return "Could not decode scanned image: \(detail)"
        case .scannerNotResponding(let seconds):
            return "The scanner didn't accept the scan request within \(seconds) s. If it's connected over USB, macOS may be restarting its USB printer service — try again in a moment."
        }
    }
}

protocol ESCLClientProtocol: Sendable {
    func fetchCapabilities(from scanner: DiscoveredScanner) async throws -> ScannerCapabilities
    func fetchStatus(from scanner: DiscoveredScanner) async throws -> ScannerStatus
    func performScan(
        scanner: DiscoveredScanner,
        request: ScanJobRequest,
        onProgress: @escaping @Sendable (_ bytesReceived: Int64, _ expectedBytes: Int64) -> Void
    ) async throws -> ScanDownloadResult
}

/// Async eSCL client with streaming progress and local self-signed TLS tolerance.
final class ESCLClient: ESCLClientProtocol, Sendable {
    private let session: URLSession
    private let delegate: SessionDelegate
    /// UserDefaults suite where IDs of jobs this app created are remembered (persisted across launches
    /// so leftover jobs from a previous run are still recognized). `nil` = `.standard`; tests pass an
    /// isolated suite. Stored as a name because `UserDefaults` is not `Sendable`.
    private let ownedJobsSuiteName: String?

    private var ownedJobsStore: UserDefaults {
        ownedJobsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    init(ownedJobsSuiteName: String? = nil) {
        self.ownedJobsSuiteName = ownedJobsSuiteName
        let config = URLSessionConfiguration.ephemeral
        // Idle timeout: fails only if NO bytes arrive for this long, so a stalled link is still caught.
        config.timeoutIntervalForRequest = 120
        // Total-duration cap. Deliberately generous: 1200 DPI RAW over Wi-Fi takes ~20–25 min on an
        // OfficeJet 3830, and a slow-but-progressing transfer must never be killed at the finish line
        // (the old 30-min cap discarded ~300 MB scans). Real stalls are caught by the idle timeout above.
        config.timeoutIntervalForResource = 4 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let del = SessionDelegate()
        self.delegate = del
        self.session = URLSession(configuration: config, delegate: del, delegateQueue: nil)
    }

    func fetchCapabilities(from scanner: DiscoveredScanner) async throws -> ScannerCapabilities {
        let url = scanner.baseURL.appendingPathComponent("ScannerCapabilities")
        let (data, resp) = try await session.data(from: url)
        try validateHTTP(resp, expected: 200...299)
        return try CapabilitiesXMLParser.parse(data)
    }

    func fetchStatus(from scanner: DiscoveredScanner) async throws -> ScannerStatus {
        let url = scanner.baseURL.appendingPathComponent("ScannerStatus")
        let (data, resp) = try await session.data(from: url)
        try validateHTTP(resp, expected: 200...299)
        return try StatusXMLParser.parse(data)
    }

    func performScan(
        scanner: DiscoveredScanner,
        request: ScanJobRequest,
        onProgress: @escaping @Sendable (_ bytesReceived: Int64, _ expectedBytes: Int64) -> Void
    ) async throws -> ScanDownloadResult {
        do {
            return try await performScanSteps(scanner: scanner, request: request, onProgress: onProgress)
        } catch {
            // A cancel can land at any step (e.g. while POST /ScanJobs is still waiting on the
            // printer), where URLSession reports it as URLError.cancelled rather than our own error.
            // Normalize so callers treat it as a user cancel, not a failure.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw ESCLClientError.cancelled
            }
            throw error
        }
    }

    private func performScanSteps(
        scanner: DiscoveredScanner,
        request: ScanJobRequest,
        onProgress: @escaping @Sendable (_ bytesReceived: Int64, _ expectedBytes: Int64) -> Void
    ) async throws -> ScanDownloadResult {
        // 0. Clear any leftover ChromaScan job still occupying the scanner. While a job is left in
        //    Processing (e.g. after a cancel whose DELETE never reached the printer), the printer
        //    rejects new jobs with 503 Service Unavailable until it times the orphan out.
        let jobsURL = scanner.baseURL.appendingPathComponent("ScanJobs")
        await clearLeftoverJobs(scanner: scanner, jobsURL: jobsURL)

        // 1. POST /eSCL/ScanJobs (retry once with minimal XML if firmware returns 409 Conflict)
        let initialXML = ESCLXMLBuilder.buildScanSettingsXML(for: request, minimal: false)
        var (postData, postResp) = try await postScanJob(to: jobsURL, xml: initialXML)

        if let http = postResp as? HTTPURLResponse, http.statusCode == 409 {
            let fallbackXML = ESCLXMLBuilder.buildScanSettingsXML(for: request, minimal: true)
            (postData, postResp) = try await postScanJob(to: jobsURL, xml: fallbackXML)
        }
        try validateHTTP(postResp, expected: 200...299, body: postData, request: request)

        guard let httpResp = postResp as? HTTPURLResponse,
              let locationStr = httpResp.value(forHTTPHeaderField: "Location"),
              let jobURL = Self.resolveJobURL(location: locationStr, relativeTo: scanner, postURL: jobsURL) else {
            throw ESCLClientError.missingJobLocation
        }
        rememberOwnedJob(jobURL)

        let expectedBytes = request.transferFormat == .rawOctetStream ? request.expectedRawByteCount : 0
        let nextDocURL = jobURL.appendingPathComponent("NextDocument")

        // 2. Stream NextDocument with cancellation cleanup (DELETE job on printer)
        do {
            let (docData, contentType) = try await streamDownload(
                url: nextDocURL,
                expectedBytes: expectedBytes,
                onProgress: onProgress
            )
            if docData.isEmpty {
                throw ESCLClientError.emptyDocument
            }

            // 3. Best-effort fetch of ScanImageInfo for exact pixel dimensions / bytesPerLine
            let info = try? await fetchScanImageInfo(jobURL: jobURL)
            return ScanDownloadResult(
                data: docData,
                contentType: contentType,
                imageInfo: info,
                jobLocation: jobURL
            )
        } catch {
            // Always try to cancel on the printer if cancelled or failed mid-stream
            await cancelJob(jobURL: jobURL)
            if Task.isCancelled {
                throw ESCLClientError.cancelled
            }
            throw error
        }
    }

    func cancelJob(jobURL: URL) async {
        var req = URLRequest(url: jobURL)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 5
        // Run detached: this is usually called from a scan Task that was just cancelled, and
        // `URLSession.data(for:)` honors the caller's cancellation — the DELETE would be cancelled
        // (-999) before it is sent, leaving the printer scanning an orphaned job.
        let session = self.session
        await Task.detached {
            _ = try? await session.data(for: req)
        }.value
    }

    // MARK: Leftover job cleanup

    private static let ownedJobsDefaultsKey = "ESCLClient.recentOwnedScanJobIDs"
    private static let ownedJobsLimit = 50

    /// Records a job this app created (persisted, so leftovers from a previous app run are still recognized).
    func rememberOwnedJob(_ jobURL: URL) {
        let id = jobURL.lastPathComponent
        guard !id.isEmpty else { return }
        let defaults = ownedJobsStore
        var ids = defaults.stringArray(forKey: Self.ownedJobsDefaultsKey) ?? []
        ids.removeAll { $0 == id }
        ids.append(id)
        defaults.set(Array(ids.suffix(Self.ownedJobsLimit)), forKey: Self.ownedJobsDefaultsKey)
    }

    func isOwnedJob(_ job: ESCLJobInfo) -> Bool {
        let ids = ownedJobsStore.stringArray(forKey: Self.ownedJobsDefaultsKey) ?? []
        let last = job.uri.split(separator: "/").last.map(String.init)
        return ids.contains(job.jobID) || (last.map { ids.contains($0) } ?? false)
    }

    private func fetchJobs(scanner: DiscoveredScanner) async -> [ESCLJobInfo]? {
        var req = URLRequest(url: scanner.baseURL.appendingPathComponent("ScannerStatus"))
        req.timeoutInterval = 5
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return ScannerJobsXMLParser.parse(data)
    }

    /// Before starting a scan, cancels any still-active job that ChromaScan itself created and waits
    /// (briefly) for the scanner to release it. Jobs started by other apps/devices are logged, never cancelled.
    private func clearLeftoverJobs(scanner: DiscoveredScanner, jobsURL: URL) async {
        let endpoint = Self.endpointLabel(jobsURL)
        guard let jobs = await fetchJobs(scanner: scanner) else {
            transferLog.notice("[\(endpoint, privacy: .public)] PRE-SCAN could not read scanner jobs; continuing")
            return
        }
        let active = jobs.filter(\.isActive)
        guard !active.isEmpty else {
            transferLog.notice("[\(endpoint, privacy: .public)] PRE-SCAN no active jobs on scanner")
            return
        }

        var cancelled: Set<String> = []
        for job in active {
            let reasons = job.stateReasons.joined(separator: ",")
            if isOwnedJob(job) {
                transferLog.notice("""
                [\(endpoint, privacy: .public)] PRE-SCAN leftover ChromaScan job \(job.jobID, privacy: .public) \
                is \(job.state, privacy: .public) (\(reasons, privacy: .public)) — cancelling
                """)
                if let url = Self.resolveJobURL(location: job.uri, relativeTo: scanner, postURL: jobsURL) {
                    await cancelJob(jobURL: url)
                    cancelled.insert(job.jobID)
                }
            } else {
                transferLog.notice("""
                [\(endpoint, privacy: .public)] PRE-SCAN scanner has another app's active job \(job.jobID, privacy: .public) \
                (\(job.state, privacy: .public), \(reasons, privacy: .public)) — not cancelling; printer may reject the new job (503)
                """)
            }
        }
        guard !cancelled.isEmpty else { return }

        // Wait up to ~10 s for the cancelled jobs to leave Processing.
        let deadline = CFAbsoluteTimeGetCurrent() + 10
        while CFAbsoluteTimeGetCurrent() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let now = await fetchJobs(scanner: scanner) else { continue }
            let stillActive = now.filter { $0.isActive && cancelled.contains($0.jobID) }
            if stillActive.isEmpty {
                transferLog.notice("[\(endpoint, privacy: .public)] PRE-SCAN leftover job(s) cleared")
                return
            }
        }
        transferLog.notice("[\(endpoint, privacy: .public)] PRE-SCAN leftover job(s) still active after 10s; continuing anyway")
    }

    /// Resolves an eSCL `Location` header relative to the `POST /eSCL/ScanJobs` URL and `scanner.baseURL`.
    /// Preserves percent-encoded path segments and query strings, and for USB loopback scanners
    /// rewrites ONLY the scheme, host, and port onto `scanner.baseURL`'s authority so `NextDocument`,
    /// `ScanImageInfo`, and `DELETE` stay on the active USB loopback link.
    static func resolveJobURL(
        location: String,
        relativeTo scanner: DiscoveredScanner,
        postURL: URL? = nil
    ) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let referenceURL = postURL ?? scanner.baseURL.appendingPathComponent("ScanJobs")
        guard let resolved = URL(string: trimmed, relativeTo: referenceURL)?.absoluteURL else {
            return nil
        }

        let cleanHost = scanner.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let isLoopbackScanner = scanner.transport == .usb
            || cleanHost == "127.0.0.1"
            || cleanHost == "localhost"
            || cleanHost == "::1"

        guard isLoopbackScanner,
              let baseComps = URLComponents(url: scanner.baseURL, resolvingAgainstBaseURL: false),
              var resolvedComps = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return resolved
        }

        resolvedComps.scheme = baseComps.scheme
        resolvedComps.host = baseComps.host
        resolvedComps.port = baseComps.port
        return resolvedComps.url
    }

    private func fetchScanImageInfo(jobURL: URL) async throws -> ScanImageInfo {
        let infoURL = jobURL.appendingPathComponent("ScanImageInfo")
        var req = URLRequest(url: infoURL)
        req.timeoutInterval = 5
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, expected: 200...299)
        return try ScanImageInfoXMLParser.parse(data)
    }

    private func streamDownload(
        url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (_ bytesReceived: Int64, _ expectedBytes: Int64) -> Void
    ) async throws -> (Data, String) {
        let tracker = DownloadTracker(expectedBytes: expectedBytes, endpoint: Self.endpointLabel(url), onProgress: onProgress)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                tracker.continuation = continuation
                let task = session.dataTask(with: req)
                tracker.task = task
                delegate.register(tracker, for: task.taskIdentifier)
                task.resume()
            }
        } onCancel: {
            tracker.cancel()
        }
    }

    /// `host:port` label, plus "USB" for loopback (macOS ippusbd / IPPUSBBridge) endpoints.
    static func endpointLabel(_ url: URL?) -> String {
        guard let url, let host = url.host else { return "?" }
        let port = url.port.map { ":\($0)" } ?? ""
        let lower = host.lowercased()
        let isLoopback = lower == "localhost" || lower == "127.0.0.1" || lower == "::1"
        return "\(isLoopback ? "USB " : "network ")\(host)\(port)"
    }

    private func postScanJob(to jobsURL: URL, xml: String) async throws -> (Data, URLResponse) {
        var postReq = URLRequest(url: jobsURL)
        postReq.httpMethod = "POST"
        postReq.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        postReq.httpBody = xml.data(using: .utf8)
        // Normally answered in ~0.2 s (a printer waking from sleep can take several seconds). Without
        // its own timeout a POST that the printer / macOS ippusbd never answers would hang for the
        // session's 120 s idle timeout with no feedback.
        postReq.timeoutInterval = Self.postScanJobTimeout
        transferLog.notice("[\(Self.endpointLabel(jobsURL), privacy: .public)] ScanSettings:\n\(xml, privacy: .public)")
        do {
            return try await session.data(for: postReq)
        } catch let error as URLError where error.code == .timedOut {
            transferLog.notice("[\(Self.endpointLabel(jobsURL), privacy: .public)] POST /ScanJobs got no answer in \(Int(Self.postScanJobTimeout))s")
            throw ESCLClientError.scannerNotResponding(seconds: Int(Self.postScanJobTimeout))
        }
    }

    static let postScanJobTimeout: TimeInterval = 45

    private func validateHTTP(
        _ response: URLResponse,
        expected: ClosedRange<Int>,
        body: Data? = nil,
        request: ScanJobRequest? = nil
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ESCLClientError.httpError(-1, "Non-HTTP response")
        }
        guard expected.contains(http.statusCode) else {
            let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if http.statusCode == 409 {
                let hint: String
                if let req = request, req.transferFormat == .jpeg && req.resolution >= 1200 {
                    hint = "\(reason) — this scanner may not support Fast Wi-Fi (JPEG) at \(req.resolution) DPI. Try RAW (Lossless) or a lower DPI."
                } else if let req = request, req.inputSource == .feeder {
                    hint = "\(reason) — check that paper is loaded in the Document Feeder (ADF) or switch Source to Flatbed."
                } else {
                    hint = "\(reason) — scanner rejected this combination of settings (format/resolution/source)."
                }
                throw ESCLClientError.httpError(http.statusCode, hint)
            }
            if let body, let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                throw ESCLClientError.httpError(http.statusCode, "\(reason) (\(text.prefix(120)))")
            }
            throw ESCLClientError.httpError(http.statusCode, reason)
        }
    }
}

// MARK: - Streaming Download Tracker & URLSessionDelegate

private final class DownloadTracker: @unchecked Sendable {
    private let lock = NSLock()
    var buffer = Data()
    var contentType = "application/octet-stream"
    var statusCode = 200
    var expectedBytes: Int64
    var receivedBytes: Int64 = 0
    var lastProgressTime: CFAbsoluteTime = 0
    var continuation: CheckedContinuation<(Data, String), Error>?
    weak var task: URLSessionDataTask?
    let onProgress: @Sendable (Int64, Int64) -> Void

    // Throughput diagnostics (guarded by `lock`).
    static let sampleInterval: CFAbsoluteTime = 5
    let endpoint: String
    let startTime = CFAbsoluteTimeGetCurrent()
    var firstByteTime: CFAbsoluteTime?
    var lastChunkTime: CFAbsoluteTime = 0
    var longestGap: CFAbsoluteTime = 0
    var windowStart: CFAbsoluteTime = 0
    var windowStartBytes: Int64 = 0
    var windowLongestGap: CFAbsoluteTime = 0
    var windowChunks = 0

    init(expectedBytes: Int64, endpoint: String, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expectedBytes = expectedBytes
        self.endpoint = endpoint
        self.onProgress = onProgress
        self.windowStart = startTime
        self.lastChunkTime = startTime
        if expectedBytes > 0 && expectedBytes <= 600_000_000 {
            self.buffer.reserveCapacity(Int(expectedBytes) + 65536)
        }
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }

    func didReceiveResponse(_ response: URLResponse) {
        lock.lock()
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
            if let ct = http.value(forHTTPHeaderField: "Content-Type") {
                contentType = ct
            }
            if http.expectedContentLength > 0 {
                expectedBytes = http.expectedContentLength
            }
        }
        lock.unlock()
    }

    func didReceiveData(_ data: Data) {
        var shouldReport = false
        var recv: Int64 = 0
        var exp: Int64 = 0

        var sample: (elapsed: Double, mb: Double, expMB: Double, windowRate: Double, avgRate: Double, gap: Double, chunks: Int)?

        lock.lock()
        buffer.append(data)
        receivedBytes += Int64(data.count)
        let now = CFAbsoluteTimeGetCurrent()
        if firstByteTime == nil {
            firstByteTime = now
        }
        let gap = now - lastChunkTime
        lastChunkTime = now
        longestGap = max(longestGap, gap)
        windowLongestGap = max(windowLongestGap, gap)
        windowChunks += 1
        if now - windowStart >= Self.sampleInterval {
            let span = now - windowStart
            let streamSpan = max(now - (firstByteTime ?? startTime), 0.001)
            sample = (
                elapsed: now - startTime,
                mb: Double(receivedBytes) / 1e6,
                expMB: Double(expectedBytes) / 1e6,
                windowRate: Double(receivedBytes - windowStartBytes) / 1e6 / span,
                avgRate: Double(receivedBytes) / 1e6 / streamSpan,
                gap: windowLongestGap,
                chunks: windowChunks
            )
            windowStart = now
            windowStartBytes = receivedBytes
            windowLongestGap = 0
            windowChunks = 0
        }
        if now - lastProgressTime >= 0.08 {
            lastProgressTime = now
            shouldReport = true
            recv = receivedBytes
            exp = expectedBytes
        }
        lock.unlock()

        if let s = sample {
            transferLog.notice("""
            [\(self.endpoint, privacy: .public)] t=\(s.elapsed, format: .fixed(precision: 0))s \
            \(s.mb, format: .fixed(precision: 1))/\(s.expMB, format: .fixed(precision: 1)) MB \
            window=\(s.windowRate, format: .fixed(precision: 2)) MB/s avg=\(s.avgRate, format: .fixed(precision: 2)) MB/s \
            maxGap=\(s.gap, format: .fixed(precision: 2))s chunks=\(s.chunks)
            """)
        }
        if shouldReport {
            onProgress(recv, exp)
        }
    }

    /// One-line summary of the whole transfer; called once from `didComplete`.
    private func logSummary(outcome: String, received: Int64, expected: Int64) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let total = now - startTime
        let ttfb = firstByteTime.map { $0 - startTime } ?? -1
        let streamSpan = max(now - (firstByteTime ?? startTime), 0.001)
        let gap = max(longestGap, now - lastChunkTime)
        lock.unlock()
        let mb = Double(received) / 1e6
        transferLog.notice("""
        [\(self.endpoint, privacy: .public)] DOWNLOAD \(outcome, privacy: .public): \
        \(mb, format: .fixed(precision: 1))/\(Double(expected) / 1e6, format: .fixed(precision: 1)) MB in \(total, format: .fixed(precision: 1))s \
        avg=\(mb / max(total, 0.001), format: .fixed(precision: 2)) MB/s streaming=\(mb / streamSpan, format: .fixed(precision: 2)) MB/s \
        firstByte=\(ttfb, format: .fixed(precision: 1))s longestGap=\(gap, format: .fixed(precision: 1))s
        """)
    }

    func didComplete(error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let code = statusCode
        let data = buffer
        let ct = contentType
        let recv = receivedBytes
        let exp = expectedBytes
        buffer = Data()
        lock.unlock()

        guard let cont else { return }
        let outcome: String
        if let error {
            let nsErr = error as NSError
            outcome = "FAILED (\(nsErr.domain) \(nsErr.code): \(nsErr.localizedDescription))"
        } else if !(200...299).contains(code) {
            outcome = "FAILED (HTTP \(code))"
        } else {
            outcome = "OK"
        }
        logSummary(outcome: outcome, received: recv, expected: exp)

        if let error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                cont.resume(throwing: ESCLClientError.cancelled)
            } else {
                cont.resume(throwing: error)
            }
            return
        }
        if !(200...299).contains(code) {
            let reason = HTTPURLResponse.localizedString(forStatusCode: code)
            cont.resume(throwing: ESCLClientError.httpError(code, reason))
            return
        }
        onProgress(recv, max(exp, recv))
        cont.resume(returning: (data, ct))
    }
}

private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var trackers: [Int: DownloadTracker] = [:]
    /// Task IDs that were created while a scan download was already streaming.
    private var startedDuringDownload: [Int: String] = [:]

    func register(_ tracker: DownloadTracker, for taskID: Int) {
        lock.lock()
        trackers[taskID] = tracker
        lock.unlock()
    }

    private func tracker(for taskID: Int) -> DownloadTracker? {
        lock.lock()
        defer { lock.unlock() }
        return trackers[taskID]
    }

    private func removeTracker(for taskID: Int) -> DownloadTracker? {
        lock.lock()
        defer { lock.unlock() }
        return trackers.removeValue(forKey: taskID)
    }

    // MARK: Request diagnostics — every request to the scanner, flagged when it overlaps a scan download.

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock()
        let active = trackers.values.map(\.endpoint)
        if !active.isEmpty {
            startedDuringDownload[task.taskIdentifier] = active.joined(separator: ", ")
        }
        lock.unlock()
        if !active.isEmpty {
            let method = task.originalRequest?.httpMethod ?? "GET"
            let path = task.originalRequest?.url?.path ?? "?"
            transferLog.notice("""
            [\(ESCLClient.endpointLabel(task.originalRequest?.url), privacy: .public)] \
            REQUEST START \(method, privacy: .public) \(path, privacy: .public) while download active
            """)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        let overlapped = startedDuringDownload.removeValue(forKey: task.taskIdentifier)
        let isDownload = trackers[task.taskIdentifier] != nil
        let downloadActive = trackers.count > (isDownload ? 1 : 0)
        lock.unlock()
        guard !isDownload else { return } // the download logs its own summary

        let method = task.originalRequest?.httpMethod ?? "GET"
        let path = task.originalRequest?.url?.path ?? "?"
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let duration = metrics.taskInterval.duration
        let rx = task.countOfBytesReceived
        let overlap = (overlapped != nil || downloadActive) ? "yes" : "no"
        let err = (task.error as NSError?).map { " error=\($0.domain) \($0.code)" } ?? ""
        transferLog.notice("""
        [\(ESCLClient.endpointLabel(task.originalRequest?.url), privacy: .public)] \
        REQUEST \(method, privacy: .public) \(path, privacy: .public) -> \(status) \
        in \(duration, format: .fixed(precision: 2))s rx=\(rx)B duringDownload=\(overlap, privacy: .public)\(err, privacy: .public)
        """)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        tracker(for: dataTask.taskIdentifier)?.didReceiveResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        tracker(for: dataTask.taskIdentifier)?.didReceiveData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        removeTracker(for: task.taskIdentifier)?.didComplete(error: error)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Local printers using _uscans._tcp (port 443) almost always present self-signed certificates.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host.lowercased()
            if host.hasSuffix(".local") || host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
