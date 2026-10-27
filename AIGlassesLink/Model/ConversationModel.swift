import Foundation

enum ConversationState: String, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case disconnected

    var label: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .disconnected: "Disconnected"
        }
    }
}

struct TurnIDSequence {
    private(set) var current = 0

    mutating func next() -> Int {
        if current == Int.max {
            current = 0
        }
        current += 1
        return current
    }
}

@MainActor
final class ConversationModel: ObservableObject {
    @Published private(set) var state: ConversationState = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var lastLatencyMilliseconds: Int?

    let settings: ConversationSettings

    private enum MicGate {
        case open
        case tts
    }

    private let audioSession: AudioSessionController
    private let microphone: MicrophoneCapture
    private let player: PacedAudioPlayer
    private let client: ConversationClient
    private let haptics: HapticProviding

    private var turnSequence = TurnIDSequence()
    private var activeTurnID: Int?
    private var playbackTurnID: Int?
    private var speechEndTimes: [Int: TimeInterval] = [:]
    private var didMeasurePlaybackLatency = false
    private var micGate: MicGate = .open
    private var started = false
    private var pressIsHeld = false

    init(
        audioSession: AudioSessionController = AudioSessionController(),
        microphone: MicrophoneCapture = MicrophoneCapture(),
        player: PacedAudioPlayer = PacedAudioPlayer(),
        client: ConversationClient = ConversationClient(),
        haptics: HapticProviding? = nil,
        settings: ConversationSettings? = nil
    ) {
        self.audioSession = audioSession
        self.microphone = microphone
        self.player = player
        self.client = client
        self.haptics = haptics ?? HapticFeedback()
        self.settings = settings ?? ConversationSettings()
        installCallbacks()
    }

    var preferredVoiceIdentifier: String { settings.voiceIdentifier }
    var preferredSpeakingRate: Double { settings.speakingRate }

    func start() {
        guard !started else {
            client.connect()
            return
        }
        started = true

        do {
            try audioSession.activate()
            try player.prepare()
            client.connect()
        } catch {
            lastError = error.localizedDescription
            transition(to: .disconnected)
        }
    }

    func stop() {
        guard started else { return }
        pressIsHeld = false
        microphone.stop()
        player.reset()
        client.send(.stop)
        client.disconnect()
        try? audioSession.deactivate()
        activeTurnID = nil
        playbackTurnID = nil
        started = false
        transition(to: .disconnected)
    }

    func updateBackend(_ baseURL: URL) {
        guard let endpoint = BackendEndpoint.webSocketURL(base: baseURL, path: "/ws_audio") else {
            return
        }
        client.updateEndpoint(endpoint)
    }

    func beginPushToTalk() {
        guard state != .disconnected, state != .listening else { return }
        pressIsHeld = true

        audioSession.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.pressIsHeld else { return }
                guard granted else {
                    self.lastError = "Microphone access is required to talk."
                    return
                }
                self.beginGrantedPushToTalk()
            }
        }
    }

    func endPushToTalk() {
        pressIsHeld = false
        guard state == .listening, let turnID = activeTurnID else { return }
        microphone.stop()
        client.send(.speechEnd(turnID: turnID))
        speechEndTimes[turnID] = ProcessInfo.processInfo.systemUptime
        transition(to: .thinking)
    }

    private func beginGrantedPushToTalk() {
        if state == .speaking {
            client.send(.bargeIn)
            player.reset()
            openMicGate()
        }

        let turnID = turnSequence.next()
        activeTurnID = turnID
        speechEndTimes = speechEndTimes.filter { $0.key >= turnID - 2 }
        client.send(.speechStart(turnID: turnID))

        do {
            micGate = .open
            try microphone.start()
            lastError = nil
            transition(to: .listening)
        } catch {
            lastError = error.localizedDescription
            client.send(.speechEnd(turnID: turnID))
            transition(to: .idle)
        }
    }

    private func installCallbacks() {
        client.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if connected {
                    self.client.send(.start)
                } else {
                    self.microphone.stop()
                    self.player.reset()
                    self.transition(to: .disconnected)
                }
            }
        }

        client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        client.onAudio = { [weak self] data in
            Task { @MainActor in
                self?.handleAudio(data)
            }
        }

        client.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
            }
        }

        microphone.onChunk = { [weak self] chunk in
            Task { @MainActor in
                guard let self, self.state == .listening, self.micGate == .open else { return }
                self.client.sendAudio(chunk)
            }
        }

        microphone.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
            }
        }

        player.onDrained = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.openMicGate()
                if self.state == .speaking {
                    self.transition(to: .idle)
                }
            }
        }

        player.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
            }
        }

        audioSession.onInterruptionBegan = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pressIsHeld = false
                if self.state == .listening {
                    self.endPushToTalk()
                }
                self.player.reset()
            }
        }

        audioSession.onInterruptionEnded = { [weak self] in
            self?.player.resumeAfterRouteChange()
        }
        audioSession.onRouteChanged = { [weak self] in
            self?.player.resumeAfterRouteChange()
        }
    }

    private func handle(_ event: ConversationServerEvent) {
        switch event {
        case .started:
            if state == .disconnected {
                transition(to: .idle)
            }
        case .stopped:
            transition(to: .disconnected)
        case let .ttsStart(turnID):
            playbackTurnID = turnID
            didMeasurePlaybackLatency = false
            microphone.stop()
            micGate = .tts
            client.send(.micGateTTS)
            player.beginTurn()
            transition(to: .speaking)
        case let .ttsEnd(turnID):
            guard playbackTurnID == turnID else { return }
            player.endTurn()
        case let .ttsReset(turnID):
            guard playbackTurnID == nil || playbackTurnID == turnID else { return }
            player.reset()
            playbackTurnID = nil
            openMicGate()
            if state == .speaking {
                transition(to: .idle)
            }
        case .reset:
            player.reset()
            playbackTurnID = nil
            openMicGate()
            if state != .listening {
                transition(to: .idle)
            }
        case .unknown:
            break
        }
    }

    private func handleAudio(_ data: Data) {
        if !didMeasurePlaybackLatency, let turnID = playbackTurnID,
           let speechEnd = speechEndTimes.removeValue(forKey: turnID) {
            let elapsed = ProcessInfo.processInfo.systemUptime - speechEnd
            let milliseconds = max(0, Int((elapsed * 1_000).rounded()))
            lastLatencyMilliseconds = milliseconds
            client.send(.deviceLatency(turnID: turnID, milliseconds: milliseconds))
            didMeasurePlaybackLatency = true
        }
        player.enqueue(data)
    }

    private func openMicGate() {
        guard micGate != .open else { return }
        micGate = .open
        client.send(.micGateOpen)
    }

    private func transition(to newState: ConversationState) {
        guard state != newState else { return }
        state = newState
        haptics.play(for: newState)
    }
}
