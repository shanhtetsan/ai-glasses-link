import SwiftUI

struct ContentView: View {
    @ObservedObject var deviceModel: DeviceLinkModel
    @ObservedObject var conversationModel: ConversationModel
    @ObservedObject var researcherModel: ResearcherModel
    @ObservedObject var settings: ConversationSettings

    var body: some View {
        TabView {
            SessionView(model: conversationModel)
                .tabItem {
                    Label("Session", systemImage: "waveform.circle.fill")
                }

            ResearcherView(researcher: researcherModel, device: deviceModel)
                .tabItem {
                    Label("Researcher", systemImage: "chart.xyaxis.line")
                }

            SettingsView(settings: settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}
