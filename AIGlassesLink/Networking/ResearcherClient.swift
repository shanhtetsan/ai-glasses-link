import Foundation

final class ResearcherClient: @unchecked Sendable {
    static let viewerURL = URL(string: "wss://ai-glasses-for-research.fly.dev/ws/viewer")!
    static let uiURL = URL(string: "wss://ai-glasses-for-research.fly.dev/ws_ui")!
    static let metricsURL = URL(string: "https://ai-glasses-for-research.fly.dev/latency/metrics")!

    var onJPEG: (@Sendable (Data) -> Void)?
    var onUIText: (@Sendable (String) -> Void)?
    var onMetrics: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.aiglasses.link.researcher-client")
    private let session: URLSession
    private var viewerTask: URLSessionWebSocketTask?
    private var uiTask: URLSessionWebSocketTask?
    private var metricsTimer: DispatchSourceTimer?
    private var running = false

    init(configuration: URLSessionConfiguration = .default) {
        session = URLSession(configuration: configuration)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.openViewer()
            self.openUI()
            self.startMetricsPolling()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.viewerTask?.cancel(with: .goingAway, reason: nil)
            self.uiTask?.cancel(with: .goingAway, reason: nil)
            self.viewerTask = nil
            self.uiTask = nil
            self.metricsTimer?.cancel()
            self.metricsTimer = nil
        }
    }

    private func openViewer() {
        guard running, viewerTask == nil else { return }
        let task = session.webSocketTask(with: Self.viewerURL)
        viewerTask = task
        task.resume()
        receiveViewer(on: task)
    }

    private func openUI() {
        guard running, uiTask == nil else { return }
        let task = session.webSocketTask(with: Self.uiURL)
        uiTask = task
        task.resume()
        receiveUI(on: task)
    }

    private func receiveViewer(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case let .success(message):
                if case let .data(data) = message {
                    self.onJPEG?(data)
                }
                self.queue.async {
                    guard self.running, self.viewerTask === task else { return }
                    self.receiveViewer(on: task)
                }
            case let .failure(error):
                self.onError?(error)
                self.queue.async {
                    guard self.viewerTask === task else { return }
                    self.viewerTask = nil
                    self.reconnectViewer()
                }
            }
        }
    }

    private func receiveUI(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message {
                    self.onUIText?(text)
                }
                self.queue.async {
                    guard self.running, self.uiTask === task else { return }
                    self.receiveUI(on: task)
                }
            case let .failure(error):
                self.onError?(error)
                self.queue.async {
                    guard self.uiTask === task else { return }
                    self.uiTask = nil
                    self.reconnectUI()
                }
            }
        }
    }

    private func reconnectViewer() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.openViewer()
        }
    }

    private func reconnectUI() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.openUI()
        }
    }

    private func startMetricsPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.fetchMetrics()
        }
        metricsTimer = timer
        timer.resume()
    }

    private func fetchMetrics() {
        guard running else { return }
        session.dataTask(with: Self.metricsURL) { [weak self] data, response, error in
            if let error {
                self?.onError?(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode), let data else {
                return
            }
            self?.onMetrics?(data)
        }.resume()
    }
}
