import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ConversationSettings
    @ObservedObject var backendSettings: BackendSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Research backend") {
                    TextField("https://example.com", text: $backendSettings.backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if backendSettings.normalizedBaseURL == nil {
                        Text("Enter a valid HTTP or HTTPS URL.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Trial access") {
                    SecureField("Trial token", text: $backendSettings.trialToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("The token is stored in this iPhone's Keychain and sent as X-Trial-Token.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = backendSettings.tokenError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

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
                        Text(rateMultiplierText)
                            .font(.title3.bold().monospacedDigit())
                            .frame(maxWidth: .infinity)
                        HStack {
                            Text("Slower")
                            Spacer()
                            Text("Normal")
                            Spacer()
                            Text("Faster")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Slider(value: rateSliderPosition, in: 0...1)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Speaking rate")
                            .accessibilityValue(rateAccessibilityValue)
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

    private var rateSliderPosition: Binding<Double> {
        Binding(
            get: { sliderPosition(for: settings.speakingRate) },
            set: { settings.speakingRate = nativeRate(for: $0) }
        )
    }

    private var rateMultiplierText: String {
        (settings.speakingRate / normalRate)
            .formatted(.number.precision(.fractionLength(1))) + "x"
    }

    private var rateAccessibilityValue: String {
        abs(settings.speakingRate - normalRate) < 0.005
            ? "\(rateMultiplierText), Normal"
            : rateMultiplierText
    }

    private var minimumRate: Double { 0.3 }
    private var normalRate: Double { Double(AVSpeechUtteranceDefaultSpeechRate) }
    private var maximumRate: Double { 0.6 }

    private func sliderPosition(for nativeRate: Double) -> Double {
        if nativeRate <= normalRate {
            return 0.5 * (nativeRate - minimumRate) / (normalRate - minimumRate)
        }
        return 0.5 + 0.5 * (nativeRate - normalRate) / (maximumRate - normalRate)
    }

    private func nativeRate(for sliderPosition: Double) -> Double {
        let position = min(max(sliderPosition, 0), 1)
        if position <= 0.5 {
            return minimumRate + (normalRate - minimumRate) * (position / 0.5)
        }
        return normalRate + (maximumRate - normalRate) * ((position - 0.5) / 0.5)
    }
}
