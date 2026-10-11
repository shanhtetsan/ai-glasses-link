import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ConversationSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Picker("Assistant voice", selection: $settings.voiceIdentifier) {
                        ForEach(settings.availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Assistant voice")
                    .accessibilityValue(selectedVoiceDescription)
                }

                Section("Speaking rate") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Slower")
                            Spacer()
                            Text(settings.speakingRate.formatted(.number.precision(.fractionLength(2))))
                                .monospacedDigit()
                            Spacer()
                            Text("Faster")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Slider(value: $settings.speakingRate, in: 0.3...0.6, step: 0.01)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Speaking rate")
                            .accessibilityValue(
                                settings.speakingRate.formatted(.number.precision(.fractionLength(2)))
                            )
                    }
                }

                Section {
                    Text("The preference is stored on this iPhone and is already available to the conversation model. The current backend does not consume it yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var selectedVoiceDescription: String {
        guard let voice = settings.availableVoices.first(where: {
            $0.identifier == settings.voiceIdentifier
        }) else {
            return "No supported voice selected"
        }
        return "\(voice.name), \(voice.language)"
    }
}
