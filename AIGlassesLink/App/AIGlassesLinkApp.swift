import SwiftUI

@main
struct AIGlassesLinkApp: App {
    @StateObject private var deviceModel: DeviceLinkModel
    @StateObject private var conversationModel: ConversationModel
    @StateObject private var researcherModel: ResearcherModel
    @StateObject private var recordModel: RecordModel
    @StateObject private var settings: ConversationSettings
    @StateObject private var backendSettings: BackendSettings
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = ConversationSettings()
        let backendSettings = BackendSettings()
        _settings = StateObject(wrappedValue: settings)
        _backendSettings = StateObject(wrappedValue: backendSettings)
        _deviceModel = StateObject(wrappedValue: DeviceLinkModel())
        _conversationModel = StateObject(
            wrappedValue: ConversationModel(settings: settings)
        )
        _researcherModel = StateObject(
            wrappedValue: ResearcherModel(
                client: ResearcherClient(
                    baseURL: backendSettings.normalizedBaseURL ?? ResearcherClient.defaultBaseURL
                )
            )
        )
        _recordModel = StateObject(wrappedValue: RecordModel(backendSettings: backendSettings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                deviceModel: deviceModel,
                conversationModel: conversationModel,
                researcherModel: researcherModel,
                recordModel: recordModel,
                settings: settings,
                backendSettings: backendSettings
            )
                .task {
                    deviceModel.start()
                    conversationModel.start()
                    researcherModel.start()
                }
                .onChange(of: backendSettings.backendURL) { _, _ in
                    if let url = backendSettings.normalizedBaseURL {
                        researcherModel.updateBackend(url)
                    }
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
