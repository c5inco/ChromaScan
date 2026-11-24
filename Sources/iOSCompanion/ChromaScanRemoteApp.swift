import SwiftUI

@main
struct ChromaScanRemoteApp: App {
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
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    store.handleScenePhaseActive()
                }
            }
        }
    }
}
