import Foundation

final class PhoneSensorClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum PayloadKind: String, Sendable {
        case frame
        case imu
    }

    var onConnectionChange: (@Sendable (Bool) -> Void)?
    var onSendResult: (@Sendable (PayloadKind, Bool, String?) -> Void)?

    private let endpoint: URL
    private let token: String
    private let queue = DispatchQueue(label: "com.aiglasses.link.phone-sensor")
    private lazy var session = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var reconnectWorkItem: DispatchWorkItem?

    init(endpoint: URL, token: String) {
        self.endpoint = endpoint
        self.token = token
        super.init()
    }

    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.openIfNeeded()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            let oldTask = self.task
            self.task = nil
            oldTask?.cancel(with: .normalClosure, reason: nil)
            self.onConnectionChange?(false)
        }
    }

    func send(_ data: Data, kind: PayloadKind) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let task = self.task else {
                self.onSendResult?(kind, false, "Socket is not connected")
                return
            }
            task.send(.data(data)) { [weak self, weak task] error in
                guard let self else { return }
                if let error {
                    self.onSendResult?(kind, false, error.localizedDescription)
                    self.queue.async {
                        if let task { self.handleDisconnect(of: task) }
                    }
                } else {
                    self.onSendResult?(kind, true, nil)
                }
            }
        }
    }

    private func openIfNeeded() {
        guard running, task == nil else { return }
        var request = URLRequest(url: endpoint)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Trial-Token")
        }
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()
    }

    private func receiveNext(on receivingTask: URLSessionWebSocketTask) {
        receivingTask.receive { [weak self, weak receivingTask] result in
            guard let self, let receivingTask else { return }
            switch result {
            case .success:
                self.queue.async {
                    guard self.task === receivingTask else { return }
                    self.receiveNext(on: receivingTask)
                }
            case .failure:
                self.queue.async { self.handleDisconnect(of: receivingTask) }
            }
        }
    }

    private func handleDisconnect(of disconnectedTask: URLSessionWebSocketTask) {
        guard task === disconnectedTask else { return }
        task = nil
        onConnectionChange?(false)
        guard running else { return }
        let item = DispatchWorkItem { [weak self] in self?.openIfNeeded() }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask, self.task === webSocketTask else { return }
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
        queue.async { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            self.handleDisconnect(of: webSocketTask)
        }
    }
}
