import SwiftUI

@main
struct AIGlassesLinkApp: App {
    @StateObject private var deviceModel: DeviceLinkModel
    @StateObject private var conversationModel: ConversationModel
    @StateObject private var researcherModel: ResearcherModel
    @StateObject private var recordModel: RecordModel
    @StateObject private var trialsModel: TrialsModel
    @StateObject private var uploadManager: PhoneCaptureUploadManager
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
            wrappedValue: ConversationModel(
                client: ConversationClient(
                    endpoint: BackendEndpoint.webSocketURL(
                        base: backendSettings.normalizedBaseURL ?? ResearcherClient.defaultBaseURL,
                        path: "/ws_audio"
                    ) ?? ConversationClient.defaultURL
                ),
                settings: settings
            )
        )
        _researcherModel = StateObject(
            wrappedValue: ResearcherModel(
                client: ResearcherClient(
                    baseURL: backendSettings.normalizedBaseURL ?? ResearcherClient.defaultBaseURL
                )
            )
        )
        let uploadManager = PhoneCaptureUploadManager(backendSettings: backendSettings)
        _uploadManager = StateObject(wrappedValue: uploadManager)
        _recordModel = StateObject(
            wrappedValue: RecordModel(
                backendSettings: backendSettings,
                uploadManager: uploadManager
            )
        )
        _trialsModel = StateObject(
            wrappedValue: TrialsModel(
                backendSettings: backendSettings,
                uploadManager: uploadManager
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                deviceModel: deviceModel,
                conversationModel: conversationModel,
                researcherModel: researcherModel,
                recordModel: recordModel,
                trialsModel: trialsModel,
                settings: settings,
                backendSettings: backendSettings
            )
                .task {
                    guard !isRunningUnitTests else { return }
                    deviceModel.start()
                    conversationModel.start()
                    researcherModel.start()
                    uploadManager.start()
                }
                .onChange(of: backendSettings.backendURL) { _, _ in
                    if let url = backendSettings.normalizedBaseURL {
                        researcherModel.updateBackend(url)
                        conversationModel.updateBackend(url)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard !isRunningUnitTests else { return }
                    switch newPhase {
                    case .active:
                        deviceModel.start()
                        conversationModel.start()
                        researcherModel.start()
                        uploadManager.start()
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

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
