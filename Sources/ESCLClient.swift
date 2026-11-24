import Foundation

enum ESCLClientError: Error, LocalizedError {
    case httpError(Int, String)
    case missingJobLocation
    case cancelled
    case emptyDocument
    case invalidImageData(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg): return "Scanner returned HTTP \(code): \(msg)"
        case .missingJobLocation: return "Scanner did not return a ScanJob Location header."
        case .cancelled: return "Scan cancelled."
        case .emptyDocument: return "Scanner returned an empty document."
        case .invalidImageData(let detail): return "Could not decode scanned image: \(detail)"
        }
    }
}

struct ScanDownloadResult: Sendable {
    let data: Data
    let contentType: String
    let imageInfo: ScanImageInfo?
    let jobLocation: URL
}

/// Async eSCL client with streaming progress and local self-signed TLS tolerance.
final class ESCLClient: Sendable {
    private let session: URLSession
    private let delegate: SessionDelegate

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 1800 // 1200 DPI uncompressed over Wi-Fi can take several minutes
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
        // 1. POST /eSCL/ScanJobs
        let jobsURL = scanner.baseURL.appendingPathComponent("ScanJobs")
        var postReq = URLRequest(url: jobsURL)
        postReq.httpMethod = "POST"
        postReq.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let xml = ESCLXMLBuilder.buildScanSettingsXML(for: request)
        postReq.httpBody = xml.data(using: .utf8)

        let (_, postResp) = try await session.data(for: postReq)
        try validateHTTP(postResp, expected: 200...299)

        guard let httpResp = postResp as? HTTPURLResponse,
              let locationStr = httpResp.value(forHTTPHeaderField: "Location") else {
            throw ESCLClientError.missingJobLocation
        }

        let jobURL: URL
        if let absolute = URL(string: locationStr), absolute.scheme != nil {
            jobURL = absolute
        } else {
            var comps = URLComponents(url: scanner.baseURL, resolvingAgainstBaseURL: false)!
            comps.path = locationStr.hasPrefix("/") ? locationStr : "/\(locationStr)"
            jobURL = comps.url!
        }

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
        _ = try? await session.data(for: req)
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
        let tracker = DownloadTracker(expectedBytes: expectedBytes, onProgress: onProgress)
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

    private func validateHTTP(_ response: URLResponse, expected: ClosedRange<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ESCLClientError.httpError(-1, "Non-HTTP response")
        }
        guard expected.contains(http.statusCode) else {
            let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
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

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
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

        lock.lock()
        buffer.append(data)
        receivedBytes += Int64(data.count)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProgressTime >= 0.08 {
            lastProgressTime = now
            shouldReport = true
            recv = receivedBytes
            exp = expectedBytes
        }
        lock.unlock()

        if shouldReport {
            onProgress(recv, exp)
        }
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
            if host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
