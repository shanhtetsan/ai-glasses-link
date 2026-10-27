import Foundation
import Network

/// How a sensor socket ended. The close code is the WebSocket close code, when one arrived.
struct SensorSocketCloseInfo: Equatable, Sendable {
    var closeCode: Int?
    var httpStatus: Int?
    var errorDescription: String?
}

enum SensorSocketEvent: Equatable, Sendable {
    case opened
    case closed(SensorSocketCloseInfo)
}

/// One WebSocket connection attempt. It reports `.opened` at most once and `.closed` at most
/// once, and reports nothing after `cancel()`.
protocol SensorSocket: AnyObject, Sendable {
    func start()
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func sendPing(completion: @escaping @Sendable (Error?) -> Void)
    func cancel()
}

typealias SensorSocketFactory = @Sendable (
    URLRequest,
    @escaping @Sendable (SensorSocketEvent) -> Void
) -> SensorSocket

/// Reports whether the device currently has a usable network path.
protocol NetworkPathObserving: AnyObject, Sendable {
    func start(queue: DispatchQueue, onChange: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

final class URLSessionSensorSocket: NSObject, SensorSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let factory: SensorSocketFactory = { request, onEvent in
        URLSessionSensorSocket(request: request, onEvent: onEvent)
    }

    private let request: URLRequest
    private let onEvent: @Sendable (SensorSocketEvent) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false

    init(request: URLRequest, onEvent: @escaping @Sendable (SensorSocketEvent) -> Void) {
        self.request = request
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        guard let task = lock.withLock({ task }) else {
            completion(URLError(.notConnectedToInternet))
            return
        }
        task.send(.data(data)) { [weak self, weak task] error in
            // A send that fails because the server closed the socket should report the close code.
            if error != nil, let task, task.closeCode != .invalid {
                self?.finish(SensorSocketCloseInfo(closeCode: task.closeCode.rawValue))
            }
            completion(error)
        }
    }

    func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
        guard let task = lock.withLock({ task }) else {
            completion(URLError(.notConnectedToInternet))
            return
        }
        task.sendPing { error in completion(error) }
    }

    func cancel() {
        let (session, task) = lock.withLock { () -> (URLSession?, URLSessionWebSocketTask?) in
            finished = true
            return (self.session, self.task)
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finish(_ info: SensorSocketCloseInfo) {
        let session: URLSession? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return self.session
        }
        guard let session else { return }
        onEvent(.closed(info))
        session.invalidateAndCancel()
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        // Incoming messages are not used; receiving keeps the socket's read side alive.
        // A receive failure is reported through didCloseWith/didCompleteWithError, which carry the close code.
        task.receive { [weak self, weak task] result in
            guard case .success = result, let self, let task else { return }
            self.receiveNext(on: task)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard !lock.withLock({ finished }) else { return }
        onEvent(.opened)
        receiveNext(on: webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(SensorSocketCloseInfo(closeCode: closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let webSocketTask = task as? URLSessionWebSocketTask
        let closeCode = webSocketTask.flatMap { $0.closeCode == .invalid ? nil : $0.closeCode.rawValue }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        finish(SensorSocketCloseInfo(
            closeCode: closeCode,
            httpStatus: status == 101 ? nil : status,
            errorDescription: error?.localizedDescription
        ))
    }
}

final class NWPathObserver: NetworkPathObserving, @unchecked Sendable {
    private var monitor: NWPathMonitor?

    func start(queue: DispatchQueue, onChange: @escaping @Sendable (Bool) -> Void) {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor?.cancel()
        monitor = nil
    }
}
