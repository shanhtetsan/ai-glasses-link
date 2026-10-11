import SwiftUI

@main
struct AIGlassesLinkApp: App {
    @StateObject private var model = DeviceLinkModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    model.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        model.start()
                    case .background:
                        model.stop()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
