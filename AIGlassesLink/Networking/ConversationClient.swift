import Foundation

enum ConversationCommand: Equatable {
    case start
    case stop
    case speechStart(turnID: Int)
    case speechEnd(turnID: Int)
    case bargeIn
    case micGateTTS
    case micGateOpen
    case deviceLatency(turnID: Int, milliseconds: Int)

    var text: String {
        switch self {
        case .start:
            "START"
        case .stop:
            "STOP"
        case let .speechStart(turnID):
            "SPEECH_START:\(turnID)"
        case let .speechEnd(turnID):
            "SPEECH_END:\(turnID)"
        case .bargeIn:
            "BARGE_IN"
        case .micGateTTS:
            "MIC_GATE:TTS"
        case .micGateOpen:
            "MIC_GATE:OPEN"
        case let .deviceLatency(turnID, milliseconds):
            "LATENCY:DEVICE:\(turnID):\(milliseconds)"
        }
    }
}

enum ConversationServerEvent: Equatable {
    case ttsStart(turnID: Int)
    case ttsEnd(turnID: Int)
    case ttsReset(turnID: Int)
    case started
    case stopped
    case reset
    case unknown(String)

    static func decode(_ text: String) -> ConversationServerEvent {
        switch text {
        case "OK:STARTED": return .started
        case "OK:STOPPED": return .stopped
        case "RESET": return .reset
        default: break
        }

        let components = text.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "TTS",
              let turnID = Int(components[2]) else {
            return .unknown(text)
        }

        switch components[1] {
        case "START": return .ttsStart(turnID: turnID)
        case "END": return .ttsEnd(turnID: turnID)
        case "RESET": return .ttsReset(turnID: turnID)
        default: return .unknown(text)
        }
    }
}

final class ConversationClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let defaultURL = URL(
        string: "wss://ai-glasses-for-research.fly.dev/ws_audio"
    )!

    var onConnectionChange: (@Sendable (Bool) -> Void)?
    var onEvent: (@Sendable (ConversationServerEvent) -> Void)?
    var onAudio: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let endpoint: URL
    private let queue = DispatchQueue(label: "com.aiglasses.link.conversation-client")
    private lazy var session = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var intentionallyDisconnected = false

    init(endpoint: URL = defaultURL) {
        self.endpoint = endpoint
        super.init()
    }

    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.intentionallyDisconnected = false
            self.openIfNeeded()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.intentionallyDisconnected = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            let existingTask = self.task
            self.task = nil
            existingTask?.cancel(with: .normalClosure, reason: nil)
            self.onConnectionChange?(false)
        }
    }

    func send(_ command: ConversationCommand) {
        send(.string(command.text))
    }

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        send(.data(data))
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        queue.async { [weak self] in
            guard let self, let task = self.task else { return }
            task.send(message) { [weak self, weak task] error in
                guard let error, let self, let task else { return }
                self.onError?(error)
                self.queue.async {
                    self.handleDisconnect(of: task)
                }
            }
        }
    }

    private func openIfNeeded() {
        guard task == nil else { return }
        let newTask = session.webSocketTask(with: endpoint)
        task = newTask
        newTask.resume()
    }

    private func receiveNext(on receivingTask: URLSessionWebSocketTask) {
        receivingTask.receive { [weak self, weak receivingTask] result in
            guard let self, let receivingTask else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .string(text):
                    self.onEvent?(ConversationServerEvent.decode(text))
                case let .data(data):
                    self.onAudio?(data)
                @unknown default:
                    break
                }
                self.queue.async {
                    guard self.task === receivingTask else { return }
                    self.receiveNext(on: receivingTask)
                }
            case let .failure(error):
                self.onError?(error)
                self.queue.async {
                    self.handleDisconnect(of: receivingTask)
                }
            }
        }
    }

    private func handleDisconnect(of disconnectedTask: URLSessionWebSocketTask) {
        guard task === disconnectedTask else { return }
        task = nil
        onConnectionChange?(false)
        guard !intentionallyDisconnected else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let delay = min(pow(2, Double(reconnectAttempt)), 30)
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let item = DispatchWorkItem { [weak self] in
            self?.openIfNeeded()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask, self.task === webSocketTask else { return }
            self.reconnectAttempt = 0
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.onConnectionChange?(true)
            self.receiveNext(on: webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            self.handleDisconnect(of: webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        if let error {
            onError?(error)
        }
        queue.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            self.handleDisconnect(of: webSocketTask)
        }
    }
}
