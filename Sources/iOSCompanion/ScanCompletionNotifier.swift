import Foundation
import UIKit
@preconcurrency import UserNotifications
import OSLog

private let notificationLog = Logger(subsystem: "com.chromascan.remote", category: "notifications")

// MARK: - Scan Completion Notification Payload

struct ScanCompletionNotificationPayload: Equatable, Sendable {
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSizeBytes: Int64
    let elapsedSeconds: Double

    var title: String {
        "Scan Complete"
    }

    var body: String {
        let sizeStr = RemoteSessionStore.formatMegabytes(fileSizeBytes)
        var parts = [filename, "\(pixelWidth)×\(pixelHeight)", sizeStr]
        if elapsedSeconds >= 1.0 {
            parts.append(RemoteSessionStore.formatElapsedSeconds(elapsedSeconds))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - APNs Device Token Relay (UIApplicationDelegate -> Store)

@MainActor
final class PushTokenRelay {
    static let shared = PushTokenRelay()

    private(set) var latestDeviceToken: String?
    var onTokenUpdated: ((String) -> Void)?

    func didRegister(deviceTokenData: Data) {
        let hex = deviceTokenData.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        latestDeviceToken = hex
        notificationLog.notice("Registered APNs device token (\(hex.prefix(8), privacy: .public)…)")
        onTokenUpdated?(hex)
    }

    func didFailToRegister(error: Error) {
        notificationLog.notice("Remote notifications registration unavailable: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Protocols for Testability

protocol ScanCompletionNotifying: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus
    func registerForRemoteNotifications() async
    func postScanCompleted(_ payload: ScanCompletionNotificationPayload) async
}

@MainActor
protocol BackgroundTaskManaging: AnyObject {
    var hasActiveTask: Bool { get }
    func beginTask(name: String, onExpiration: @escaping @MainActor () -> Void)
    func endTask()
}

// MARK: - Live UserNotifications Implementation

final class UserNotificationScanNotifier: NSObject, ScanCompletionNotifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationScanNotifier()

    private let center: UNUserNotificationCenter
    private let dedupeLock = NSLock()
    private var recentLocalFilenames: [String: Date] = [:]

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let current = await authorizationStatus()
        if current == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                notificationLog.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let updated = await authorizationStatus()
        if Self.isAuthorizedStatus(updated) {
            await registerForRemoteNotifications()
        }
        return updated
    }

    func registerForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func postScanCompleted(_ payload: ScanCompletionNotificationPayload) async {
        let status = await authorizationStatus()
        guard Self.isAuthorizedStatus(status) else { return }

        recordLocalNotification(filename: payload.filename)

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = ["filename": payload.filename]

        let request = UNNotificationRequest(
            identifier: "com.chromascan.remote.scanCompleted.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            notificationLog.error("Failed to schedule scan completion notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Present banner + sound in foreground, while suppressing duplicate APNs pushes
    // for a scan whose local notification was just posted over the active WebSocket.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger,
           let filename = notification.request.content.userInfo["filename"] as? String,
           wasRecentlyPostedLocally(filename: filename) {
            return []
        }
        return [.banner, .list, .sound]
    }

    private static func isAuthorizedStatus(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    private func recordLocalNotification(filename: String) {
        let now = Date()
        dedupeLock.lock()
        recentLocalFilenames = recentLocalFilenames.filter { now.timeIntervalSince($0.value) < 30 }
        recentLocalFilenames[filename] = now
        dedupeLock.unlock()
    }

    private func wasRecentlyPostedLocally(filename: String) -> Bool {
        let now = Date()
        dedupeLock.lock()
        defer { dedupeLock.unlock() }
        guard let timestamp = recentLocalFilenames[filename] else { return false }
        return now.timeIntervalSince(timestamp) < 15.0
    }
}

struct NoOpScanCompletionNotifier: ScanCompletionNotifying {
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus { .notDetermined }
    func registerForRemoteNotifications() async {}
    func postScanCompleted(_ payload: ScanCompletionNotificationPayload) async {}
}

// MARK: - Live UIApplication Background Task Manager

@MainActor
final class UIApplicationBackgroundTaskManager: BackgroundTaskManaging {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var activeToken: UUID?

    var hasActiveTask: Bool {
        taskID != .invalid
    }

    func beginTask(name: String, onExpiration: @escaping @MainActor () -> Void) {
        guard taskID == .invalid else { return }
        let token = UUID()
        activeToken = token
        let newTaskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeToken == token else { return }
                self.endTask()
                onExpiration()
            }
        }
        if newTaskID == .invalid {
            activeToken = nil
        } else {
            taskID = newTaskID
        }
    }

    func endTask() {
        activeToken = nil
        guard taskID != .invalid else { return }
        let idToEnd = taskID
        taskID = .invalid
        UIApplication.shared.endBackgroundTask(idToEnd)
    }
}
