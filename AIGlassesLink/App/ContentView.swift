import SwiftUI

struct ContentView: View {
    @ObservedObject var deviceModel: DeviceLinkModel
    @ObservedObject var conversationModel: ConversationModel
    @ObservedObject var researcherModel: ResearcherModel
    @ObservedObject var recordModel: RecordModel
    @ObservedObject var trialsModel: TrialsModel
    @ObservedObject var settings: ConversationSettings
    @ObservedObject var backendSettings: BackendSettings

    var body: some View {
        TabView {
            SessionView(model: conversationModel)
                .tabItem {
                    Label("Session", systemImage: "waveform.circle.fill")
                }

            RecordView(model: recordModel, researcher: researcherModel, device: deviceModel)
                .tabItem {
                    Label("Record", systemImage: "record.circle")
                }

            TrialsView(model: trialsModel)
                .tabItem {
                    Label("Trials", systemImage: "list.bullet.clipboard")
                }

            SettingsView(settings: settings, backendSettings: backendSettings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}
