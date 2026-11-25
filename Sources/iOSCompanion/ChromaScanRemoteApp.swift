import SwiftUI
import UIKit

final class ChromaScanRemoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushTokenRelay.shared.didRegister(deviceTokenData: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushTokenRelay.shared.didFailToRegister(error: error)
        }
    }
}

@main
struct ChromaScanRemoteApp: App {
    @UIApplicationDelegateAdaptor(ChromaScanRemoteAppDelegate.self) private var appDelegate
    @State private var store = RemoteSessionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if case .connected(_, let hostName) = store.phase {
                    RemoteWorkspaceView(store: store, hostName: hostName)
                } else {
                    PairingView(store: store)
                }
            }
            .preferredColorScheme(.dark)
            .tint(ChromaTheme.cream)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    store.handleScenePhaseActive()
                case .background:
                    store.handleScenePhaseBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}
