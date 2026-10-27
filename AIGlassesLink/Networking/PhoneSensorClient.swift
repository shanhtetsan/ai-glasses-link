import Foundation

struct SensorReconnectPolicy: Equatable, Sendable {
    /// Wait before each retry after a drop; the last value repeats.
    var backoff: [TimeInterval] = [0.5, 1, 2, 4, 5]
    var handshakeTimeout: TimeInterval = 5
    var pingInterval: TimeInterval = 3
    var pingTimeout: TimeInterval = 6

    static let standard = SensorReconnectPolicy()

    func delay(forRetry index: Int) -> TimeInterval {
        backoff[min(max(index, 0), backoff.count - 1)]
    }
}

/// Streams phone frames and IMU to /ws/camera_thermal?source=phone and keeps the socket
/// connected while a trial runs: it retries with backoff after any drop, retries at once
/// when the network comes back, and pings to catch silently dead connections.
final class PhoneSensorClient: @unchecked Sendable {
    enum PayloadKind: String, Sendable {
        case frame
        case imu
    }

    enum SendResult: Equatable, Sendable {
        case sent
        /// No open socket; the payload was dropped (the local copy and upload cover it).
        case notConnected
        case failed(String)
    }

    enum Event: Equatable, Sendable {
        /// `attempts` counts connection attempts since the last working connection dropped.
        case opened(attempts: Int)
        case closed(reason: String, wasOpen: Bool)
    }

    static let serverBusyCloseCode = 1013

    var onEvent: (@Sendable (Event) -> Void)?
    var onSendResult: (@Sendable (PayloadKind, SendResult) -> Void)?
    /// Test hook: called with each backoff delay as a retry is scheduled.
    var onRetryScheduled: (@Sendable (TimeInterval) -> Void)?

    private let endpoint: URL
    private let token: String
    private let policy: SensorReconnectPolicy
    private let makeSocket: SensorSocketFactory
    private let pathObserver: NetworkPathObserving
    private let queue = DispatchQueue(label: "com.aiglasses.link.phone-sensor")

    private var running = false
    private var socket: SensorSocket?
    private var socketGeneration = 0
    private var socketIsOpen = false
    private var attemptsSinceDrop = 0
    private var retryIndex = 0
    private var retryWorkItem: DispatchWorkItem?
    private var handshakeWorkItem: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var pingTimeoutWorkItem: DispatchWorkItem?
    private var networkAvailable: Bool?

    init(
        endpoint: URL,
        token: String,
        policy: SensorReconnectPolicy = .standard,
        socketFactory: @escaping SensorSocketFactory = URLSessionSensorSocket.factory,
        pathObserver: NetworkPathObserving = NWPathObserver()
    ) {
        self.endpoint = endpoint
        self.token = token
        self.policy = policy
        makeSocket = socketFactory
        self.pathObserver = pathObserver
    }

    func connect() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.attemptsSinceDrop = 0
            self.retryIndex = 0
            self.networkAvailable = nil
            self.pathObserver.start(queue: self.queue) { [weak self] available in
                self?.handleNetworkChange(available)
            }
            self.openSocket()
        }
    }

    /// Stops the socket and all retries. Called when the trial stops.
    func disconnect() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.pathObserver.cancel()
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.closeSocket(reason: "button_stop", scheduleRetry: false)
        }
    }

    func send(_ data: Data, kind: PayloadKind) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.socketIsOpen, let socket = self.socket else {
                self.onSendResult?(kind, .notConnected)
                return
            }
            let generation = self.socketGeneration
            socket.send(data) { [weak self] error in
                guard let self else { return }
                guard let error else {
                    self.onSendResult?(kind, .sent)
                    return
                }
                self.onSendResult?(kind, .failed(error.localizedDescription))
                self.queue.async {
                    guard generation == self.socketGeneration else { return }
                    self.closeSocket(reason: "send_failed: \(error.localizedDescription)")
                }
            }
        }
    }

    static func closeReason(_ info: SensorSocketCloseInfo) -> String {
        if info.closeCode == serverBusyCloseCode { return "server_busy" }
        if let status = info.httpStatus { return "handshake_http_\(status)" }
        if let code = info.closeCode { return "server_closed_\(code)" }
        if let error = info.errorDescription { return "error: \(error)" }
        return "closed"
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func openSocket() {
        guard running, socket == nil else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        attemptsSinceDrop += 1
        socketGeneration += 1
        let generation = socketGeneration

        var request = URLRequest(url: endpoint)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Trial-Token")
        }
        let newSocket = makeSocket(request) { [weak self] event in
            self?.queue.async { self?.handle(event, generation: generation) }
        }
        socket = newSocket
        socketIsOpen = false

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == self.socketGeneration, !self.socketIsOpen else { return }
            self.closeSocket(reason: "handshake_timeout")
        }
        handshakeWorkItem = timeout
        queue.asyncAfter(deadline: .now() + policy.handshakeTimeout, execute: timeout)
        newSocket.start()
    }

    private func handle(_ event: SensorSocketEvent, generation: Int) {
        guard generation == socketGeneration, socket != nil else { return }
        switch event {
        case .opened:
            handshakeWorkItem?.cancel()
            handshakeWorkItem = nil
            socketIsOpen = true
            onEvent?(.opened(attempts: attemptsSinceDrop))
            startPinging()
        case let .closed(info):
            closeSocket(reason: Self.closeReason(info), alreadyClosed: true)
        }
    }

    private func closeSocket(reason: String, scheduleRetry: Bool = true, alreadyClosed: Bool = false) {
        guard let current = socket else { return }
        let wasOpen = socketIsOpen
        socket = nil
        socketIsOpen = false
        socketGeneration += 1
        handshakeWorkItem?.cancel()
        handshakeWorkItem = nil
        stopPinging()
        if !alreadyClosed { current.cancel() }

        // A working connection was lost: start counting attempts and backoff afresh.
        // server_busy means the server still holds the old socket, so keep backing off.
        if wasOpen && reason != "server_busy" {
            attemptsSinceDrop = 0
            retryIndex = 0
        }
        onEvent?(.closed(reason: reason, wasOpen: wasOpen))
        if scheduleRetry { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard running, retryWorkItem == nil else { return }
        let delay = policy.delay(forRetry: retryIndex)
        retryIndex += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.openSocket()
        }
        retryWorkItem = item
        onRetryScheduled?(delay)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleNetworkChange(_ available: Bool) {
        guard running else { return }
        let previous = networkAvailable
        networkAvailable = available
        if !available {
            if previous != false { closeSocket(reason: "network_lost") }
            return
        }
        // Ignore the monitor's first report; act only when the network comes back.
        guard previous == false, !socketIsOpen else { return }
        // Drop any pending wait or stuck handshake and try now.
        if socket != nil { closeSocket(reason: "network_back_restart", scheduleRetry: false) }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        openSocket()
    }

    // MARK: - Keepalive

    private func startPinging() {
        stopPinging()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + policy.pingInterval, repeating: policy.pingInterval)
        timer.setEventHandler { [weak self] in self?.sendPing() }
        pingTimer = timer
        timer.resume()
    }

    private func stopPinging() {
        pingTimer?.cancel()
        pingTimer = nil
        pingTimeoutWorkItem?.cancel()
        pingTimeoutWorkItem = nil
    }

    private func sendPing() {
        // One ping in flight at a time; a slow pong just delays the next ping.
        guard socketIsOpen, let socket, pingTimeoutWorkItem == nil else { return }
        let generation = socketGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == self.socketGeneration else { return }
            self.closeSocket(reason: "ping_timeout")
        }
        pingTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + policy.pingTimeout, execute: timeout)
        socket.sendPing { [weak self] error in
            self?.queue.async {
                guard let self, generation == self.socketGeneration else { return }
                self.pingTimeoutWorkItem?.cancel()
                self.pingTimeoutWorkItem = nil
                if let error {
                    self.closeSocket(reason: "ping_failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
