import AVFoundation
import Foundation

@MainActor
final class ConversationSettings: ObservableObject {
    static let supportedLanguages = Set(["en-GB", "en-US"])
    static let voiceKey = "conversation.voiceIdentifier"
    static let speakingRateKey = "conversation.speakingRate"

    @Published var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: Self.voiceKey) }
    }

    @Published var speakingRate: Double {
        didSet {
            let bounded = min(max(speakingRate, 0.3), 0.6)
            if speakingRate != bounded {
                speakingRate = bounded
            } else {
                defaults.set(speakingRate, forKey: Self.speakingRateKey)
            }
        }
    }

    let availableVoices: [AVSpeechSynthesisVoice]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { Self.supportedLanguages.contains($0.language) }
            .sorted {
                if $0.language == $1.language { return $0.name < $1.name }
                return $0.language < $1.language
            }
        availableVoices = voices

        let storedIdentifier = defaults.string(forKey: Self.voiceKey)
        if let storedIdentifier, voices.contains(where: { $0.identifier == storedIdentifier }) {
            voiceIdentifier = storedIdentifier
        } else {
            voiceIdentifier = voices.first?.identifier ?? ""
        }

        if defaults.object(forKey: Self.speakingRateKey) != nil {
            speakingRate = min(max(defaults.double(forKey: Self.speakingRateKey), 0.3), 0.6)
        } else {
            speakingRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        }
    }
}
