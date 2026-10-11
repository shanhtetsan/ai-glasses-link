import SwiftUI

@main
struct AIGlassesLinkApp: App {
    @StateObject private var deviceModel: DeviceLinkModel
    @StateObject private var conversationModel: ConversationModel
    @StateObject private var researcherModel: ResearcherModel
    @StateObject private var settings: ConversationSettings
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = ConversationSettings()
        _settings = StateObject(wrappedValue: settings)
        _deviceModel = StateObject(wrappedValue: DeviceLinkModel())
        _conversationModel = StateObject(
            wrappedValue: ConversationModel(settings: settings)
        )
        _researcherModel = StateObject(wrappedValue: ResearcherModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                deviceModel: deviceModel,
                conversationModel: conversationModel,
                researcherModel: researcherModel,
                settings: settings
            )
                .task {
                    deviceModel.start()
                    conversationModel.start()
                    researcherModel.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        deviceModel.start()
                        conversationModel.start()
                        researcherModel.start()
                    case .background:
                        deviceModel.stop()
                        researcherModel.stop()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
