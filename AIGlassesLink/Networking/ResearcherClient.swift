import Foundation

final class ResearcherClient: @unchecked Sendable {
    static let defaultBaseURL = URL(string: BackendSettings.defaultBackendURL)!

    var onJPEG: (@Sendable (Data) -> Void)?
    var onUIText: (@Sendable (String) -> Void)?
    var onMetrics: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.aiglasses.link.researcher-client")
    private let session: URLSession
    private var baseURL: URL
    private var viewerTask: URLSessionWebSocketTask?
    private var uiTask: URLSessionWebSocketTask?
    private var metricsTimer: DispatchSourceTimer?
    private var running = false

    init(
        baseURL: URL = defaultBaseURL,
        configuration: URLSessionConfiguration = .default
    ) {
        self.baseURL = baseURL
        session = URLSession(configuration: configuration)
    }

    func updateBackend(_ baseURL: URL) {
        queue.async { [weak self] in
            guard let self, self.baseURL != baseURL else { return }
            let shouldRestart = self.running
            self.running = false
            self.viewerTask?.cancel(with: .goingAway, reason: nil)
            self.uiTask?.cancel(with: .goingAway, reason: nil)
            self.viewerTask = nil
            self.uiTask = nil
            self.metricsTimer?.cancel()
            self.metricsTimer = nil
            self.baseURL = baseURL
            if shouldRestart {
                self.running = true
                self.openViewer()
                self.openUI()
                self.startMetricsPolling()
            }
        }
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
        guard running, viewerTask == nil,
              let url = BackendEndpoint.webSocketURL(base: baseURL, path: "/ws/viewer") else { return }
        let task = session.webSocketTask(with: url)
        viewerTask = task
        task.resume()
        receiveViewer(on: task)
    }

    private func openUI() {
        guard running, uiTask == nil,
              let url = BackendEndpoint.webSocketURL(base: baseURL, path: "/ws_ui") else { return }
        let task = session.webSocketTask(with: url)
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
        guard running,
              let url = BackendEndpoint.httpURL(base: baseURL, path: "/latency/metrics") else { return }
        session.dataTask(with: url) { [weak self] data, response, error in
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
