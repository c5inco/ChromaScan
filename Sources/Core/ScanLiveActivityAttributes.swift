import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - Shared Live Activity State (Compiled on macOS Host, iOS App, and iOS Widget Extension)

enum ScanLiveActivityPhase: String, Codable, Hashable, Sendable {
    case starting
    case scanning
    case processing
    case completed
    case failed
}

struct ScanLiveActivityContentState: Codable, Hashable, Sendable {
    let phase: ScanLiveActivityPhase
    let statusText: String
    let progress: Double?
    let bytesReceived: Int64
    let expectedBytes: Int64
    let filename: String?
    let detailText: String?

    init(
        phase: ScanLiveActivityPhase,
        statusText: String,
        progress: Double? = nil,
        bytesReceived: Int64 = 0,
        expectedBytes: Int64 = 0,
        filename: String? = nil,
        detailText: String? = nil
    ) {
        self.phase = phase
        self.statusText = statusText
        self.progress = progress.map { max(0.0, min(1.0, $0)) }
        self.bytesReceived = bytesReceived
        self.expectedBytes = expectedBytes
        self.filename = filename
        self.detailText = detailText
    }

    var progressPercent: Int? {
        guard let progress else { return nil }
        return Int((progress * 100.0).rounded())
    }

    var isTerminal: Bool {
        phase == .completed || phase == .failed
    }

    static func fromProgress(
        bytesReceived: Int64,
        expectedBytes: Int64,
        statusText: String
    ) -> ScanLiveActivityContentState {
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isProcessing = trimmed.hasPrefix("Processing") || trimmed.hasPrefix("Rendering")

        if isProcessing {
            return ScanLiveActivityContentState(
                phase: .processing,
                statusText: trimmed.isEmpty ? "Processing & saving…" : trimmed,
                progress: nil,
                bytesReceived: bytesReceived,
                expectedBytes: expectedBytes
            )
        }

        if bytesReceived > 0 && expectedBytes > 0 {
            let fraction = min(1.0, Double(bytesReceived) / Double(expectedBytes))
            let recvMB = Double(bytesReceived) / (1024.0 * 1024.0)
            let expMB = Double(expectedBytes) / (1024.0 * 1024.0)
            return ScanLiveActivityContentState(
                phase: .scanning,
                statusText: String(format: "%.1f / %.1f MB", recvMB, expMB),
                progress: fraction,
                bytesReceived: bytesReceived,
                expectedBytes: expectedBytes
            )
        }

        if bytesReceived > 0 {
            let recvMB = Double(bytesReceived) / (1024.0 * 1024.0)
            return ScanLiveActivityContentState(
                phase: .scanning,
                statusText: String(format: "%.1f MB received", recvMB),
                progress: nil,
                bytesReceived: bytesReceived,
                expectedBytes: expectedBytes
            )
        }

        let startingText: String
        if expectedBytes > 0 {
            let expMB = Double(expectedBytes) / (1024.0 * 1024.0)
            startingText = String(format: "Warming up · %.1f MB", expMB)
        } else {
            startingText = "Starting scanner…"
        }
        return ScanLiveActivityContentState(
            phase: .starting,
            statusText: startingText,
            progress: nil,
            bytesReceived: 0,
            expectedBytes: expectedBytes
        )
    }

    static func completed(
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileSizeBytes: Int64
    ) -> ScanLiveActivityContentState {
        let mb = Double(max(0, fileSizeBytes)) / (1024.0 * 1024.0)
        let sizeStr = String(format: "%.1f MB", mb)
        return ScanLiveActivityContentState(
            phase: .completed,
            statusText: "Saved \(filename)",
            progress: 1.0,
            bytesReceived: fileSizeBytes,
            expectedBytes: fileSizeBytes,
            filename: filename,
            detailText: "\(pixelWidth)×\(pixelHeight) · \(sizeStr)"
        )
    }

    static func failed(title: String, message: String) -> ScanLiveActivityContentState {
        ScanLiveActivityContentState(
            phase: .failed,
            statusText: title.isEmpty ? "Scan Failed" : title,
            progress: nil,
            detailText: message
        )
    }
}

#if os(iOS) && canImport(ActivityKit)
@available(iOS 16.1, *)
struct ScanLiveActivityAttributes: ActivityAttributes {
    typealias ContentState = ScanLiveActivityContentState

    let scannerName: String
    let resolutionDPI: Int
    let colorProfileName: String
    let outputFormatName: String
    let startedAt: Date
}
#endif
