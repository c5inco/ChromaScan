import Foundation
import OSLog
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

private let liveActivityLog = Logger(subsystem: "com.chromascan.remote", category: "liveActivity")

// MARK: - Protocol for Testability

@MainActor
protocol ScanLiveActivityManaging: AnyObject {
    var hasActiveActivity: Bool { get }
    var areActivitiesSupportedAndEnabled: Bool { get }
    var onPushTokenUpdated: ((String?) -> Void)? { get set }

    func start(
        scannerName: String,
        resolutionDPI: Int,
        colorProfileName: String,
        outputFormatName: String,
        startedAt: Date,
        initialState: ScanLiveActivityContentState
    )
    func update(_ state: ScanLiveActivityContentState)
    func end(finalState: ScanLiveActivityContentState?, dismissImmediately: Bool)
    func cleanupOrphanedActivities()
}

// MARK: - Live ActivityKit Implementation

@MainActor
final class ActivityKitScanLiveActivityManager: ScanLiveActivityManaging {
    private var currentActivityID: String?
    private var tokenObserverTask: Task<Void, Never>?
    private var lastUpdateTime: CFAbsoluteTime = 0
    private var lastPushedPhase: ScanLiveActivityPhase?
    private var lastReportedToken: String?

    var onPushTokenUpdated: ((String?) -> Void)?

    var hasActiveActivity: Bool {
        currentActivityID != nil
    }

    var areActivitiesSupportedAndEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(
        scannerName: String,
        resolutionDPI: Int,
        colorProfileName: String,
        outputFormatName: String,
        startedAt: Date,
        initialState: ScanLiveActivityContentState
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityLog.notice("Live Activities are disabled in iOS Settings")
            return
        }

        // End any stale or prior activities before starting a fresh one
        endCurrentAndOrphaned(finalState: nil, dismissImmediately: true, notifyTokenClear: false)

        let attributes = ScanLiveActivityAttributes(
            scannerName: scannerName,
            resolutionDPI: resolutionDPI,
            colorProfileName: colorProfileName,
            outputFormatName: outputFormatName,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: initialState,
            staleDate: Date().addingTimeInterval(30 * 60)
        )

        do {
            let activity: Activity<ScanLiveActivityAttributes>
            let usesPushToken: Bool
            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: .token
                )
                usesPushToken = true
            } catch {
                // Builds signed without Push Notifications (e.g. free Apple IDs) cannot request
                // a Live Activity push token; fall back to local-only ActivityKit updates.
                liveActivityLog.notice("Live Activity pushType .token unavailable (\(error.localizedDescription, privacy: .public)); starting local-only Live Activity")
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                usesPushToken = false
            }

            let activityID = activity.id
            let initialTokenData = usesPushToken ? activity.pushToken : nil
            currentActivityID = activityID
            lastUpdateTime = CFAbsoluteTimeGetCurrent()
            lastPushedPhase = initialState.phase
            liveActivityLog.notice("Started Live Activity \(activityID, privacy: .public) for \(resolutionDPI) DPI scan (pushToken=\(usesPushToken, privacy: .public))")

            if let initialTokenData {
                emitPushToken(initialTokenData)
            }
            if usesPushToken {
                observePushTokens(activityID: activityID)
            }
        } catch {
            liveActivityLog.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ state: ScanLiveActivityContentState) {
        guard let activityID = currentActivityID else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let phaseChanged = (lastPushedPhase != state.phase)
        if !phaseChanged && (now - lastUpdateTime) < 1.0 {
            return
        }
        lastUpdateTime = now
        lastPushedPhase = state.phase

        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(30 * 60)
        )
        Task.detached {
            await Self.performUpdate(activityID: activityID, content: content)
        }
    }

    func end(finalState: ScanLiveActivityContentState?, dismissImmediately: Bool) {
        endCurrentAndOrphaned(finalState: finalState, dismissImmediately: dismissImmediately, notifyTokenClear: true)
    }

    func cleanupOrphanedActivities() {
        guard currentActivityID == nil else { return }
        Task.detached {
            await Self.performCleanupAll()
        }
    }

    private func endCurrentAndOrphaned(
        finalState: ScanLiveActivityContentState?,
        dismissImmediately: Bool,
        notifyTokenClear: Bool
    ) {
        tokenObserverTask?.cancel()
        tokenObserverTask = nil

        let activityID = currentActivityID
        currentActivityID = nil
        lastPushedPhase = nil
        lastUpdateTime = 0

        if notifyTokenClear && lastReportedToken != nil {
            lastReportedToken = nil
            onPushTokenUpdated?(nil)
        }

        let finalContent: ActivityContent<ScanLiveActivityContentState>? = finalState.map {
            ActivityContent(state: $0, staleDate: nil)
        }

        Task.detached {
            await Self.performEnd(
                primaryID: activityID,
                finalContent: finalContent,
                dismissImmediately: dismissImmediately
            )
        }
    }

    private func observePushTokens(activityID: String) {
        tokenObserverTask?.cancel()
        tokenObserverTask = Task.detached { [weak self] in
            guard let activity = Activity<ScanLiveActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
                return
            }
            for await tokenData in activity.pushTokenUpdates {
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, self.currentActivityID == activityID else { return }
                    self.emitPushToken(tokenData)
                }
            }
        }
    }

    private func emitPushToken(_ tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty, hex != lastReportedToken else { return }
        lastReportedToken = hex
        liveActivityLog.notice("Registered Live Activity push token (\(hex.prefix(8), privacy: .public)…)")
        onPushTokenUpdated?(hex)
    }

    // MARK: - Nonisolated ActivityKit Operations (Swift 6 Safe)

    private nonisolated static func performUpdate(
        activityID: String,
        content: ActivityContent<ScanLiveActivityContentState>
    ) async {
        guard let activity = Activity<ScanLiveActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            return
        }
        await activity.update(content)
    }

    private nonisolated static func performEnd(
        primaryID: String?,
        finalContent: ActivityContent<ScanLiveActivityContentState>?,
        dismissImmediately: Bool
    ) async {
        let policy: ActivityUIDismissalPolicy = dismissImmediately
            ? .immediate
            : .after(Date().addingTimeInterval(15))

        for activity in Activity<ScanLiveActivityAttributes>.activities {
            if let primaryID, activity.id == primaryID {
                await activity.end(finalContent, dismissalPolicy: policy)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private nonisolated static func performCleanupAll() async {
        let existing = Activity<ScanLiveActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        liveActivityLog.notice("Cleaning up \(existing.count) orphaned Live Activity(ies)")
        for activity in existing {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

// MARK: - No-Op Implementation for Tests

@MainActor
final class NoOpScanLiveActivityManager: ScanLiveActivityManaging {
    var hasActiveActivity: Bool = false
    var areActivitiesSupportedAndEnabled: Bool = true
    var onPushTokenUpdated: ((String?) -> Void)?

    func start(
        scannerName: String,
        resolutionDPI: Int,
        colorProfileName: String,
        outputFormatName: String,
        startedAt: Date,
        initialState: ScanLiveActivityContentState
    ) {}

    func update(_ state: ScanLiveActivityContentState) {}

    func end(finalState: ScanLiveActivityContentState?, dismissImmediately: Bool) {}

    func cleanupOrphanedActivities() {}
}
