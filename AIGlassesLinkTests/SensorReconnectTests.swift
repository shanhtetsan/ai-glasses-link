import Foundation
import XCTest
@testable import AIGlassesLink

final class SensorReconnectTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testDefaultPolicyMatchesSpec() {
        let policy = SensorReconnectPolicy.standard
        XCTAssertEqual((0..<7).map(policy.delay(forRetry:)), [0.5, 1, 2, 4, 5, 5, 5])
        XCTAssertEqual(policy.pingInterval, 3)
        XCTAssertEqual(policy.pingTimeout, 6)
        XCTAssertEqual(policy.handshakeTimeout, 5)
    }

    func testCloseReasons() {
        XCTAssertEqual(PhoneSensorClient.closeReason(.init(closeCode: 1013)), "server_busy")
        XCTAssertEqual(PhoneSensorClient.closeReason(.init(closeCode: 1011)), "server_closed_1011")
        XCTAssertEqual(PhoneSensorClient.closeReason(.init(httpStatus: 409)), "handshake_http_409")
        XCTAssertEqual(
            PhoneSensorClient.closeReason(.init(errorDescription: "The network connection was lost.")),
            "error: The network connection was lost."
        )
    }

    /// Socket drops mid-trial, a retry hangs, the network comes back, and the stream resumes
    /// with seq continuing and no old frame resent.
    func testMidTrialDropReconnectsAndSeqContinues() throws {
        let sockets = FakeSocketFactory()
        let path = FakePathObserver()
        let camera = FakeCamera()
        // The second retry is far away, so a quick reconnect can only come from the network-back signal.
        let policy = SensorReconnectPolicy(backoff: [0.05, 30], handshakeTimeout: 30, pingInterval: 30, pingTimeout: 30)
        let client = PhoneSensorClient(
            endpoint: URL(string: "wss://example.test/ws/camera_thermal?source=phone")!,
            token: "",
            policy: policy,
            socketFactory: sockets.make,
            pathObserver: path
        )
        let writer = try PhoneCaptureWriter(
            sessionID: "T01_P01",
            trial: TrialFormData(trial: "T01", pid: "P01"),
            rootURL: root
        )
        let coordinator = PhoneCaptureCoordinator(
            writer: writer,
            sensorClient: client,
            camera: camera,
            motion: FakeMotion()
        )
        let connected = Box(false)
        coordinator.onConnectionChange = { connected.value = $0 }

        coordinator.start(buttonMonotonicNanoseconds: 1)
        try waitUntil { sockets.count == 1 }
        path.report(true)
        sockets.socket(0).open()
        try waitUntil { connected.value }

        camera.emit()
        camera.emit()
        try waitUntil { sockets.socket(0).sentSequences == [1, 2] }

        // Wi-Fi drops: the server side vanishes.
        sockets.socket(0).close(.init(errorDescription: "The network connection was lost."))
        try waitUntil { !connected.value }
        camera.emit()
        try waitUntil { writer.framesSaved == 3 }

        // First retry fires after 0.05 s but its handshake hangs while the network is down.
        try waitUntil { sockets.count == 2 }
        path.report(false)
        try waitUntil { sockets.socket(1).cancelled }
        path.report(true)
        try waitUntil { sockets.count == 3 }
        sockets.socket(2).open()
        try waitUntil { connected.value }

        camera.emit()
        try waitUntil { sockets.socket(2).sentSequences == [4] }
        XCTAssertEqual(sockets.socket(1).sentSequences, [])

        coordinator.stop(buttonMonotonicNanoseconds: 2)
        try waitUntil { sockets.socket(2).cancelled }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sockets.count, 3, "no retries after the trial stops")
        XCTAssertTrue(path.cancelled)

        let events = try phoneEvents(writer)
        let opens = events.filter { $0["event"] as? String == "socket_open" }
        XCTAssertEqual(opens.map { $0["attempts"] as? Int }, [1, 2])
        XCTAssertEqual(opens.last?["frames_not_sent"] as? Int, 1)
        let closes = events.filter { $0["event"] as? String == "socket_close" }
        XCTAssertEqual(
            closes.map { $0["reason"] as? String },
            ["error: The network connection was lost.", "network_lost", "button_stop"]
        )
        XCTAssertEqual(try PhoneCaptureWriter.frameSequences(in: writer.framesURL).sorted(), [1, 2, 3, 4])
    }

    func testServerBusyKeepsBackingOff() throws {
        let sockets = FakeSocketFactory()
        let policy = SensorReconnectPolicy(backoff: [0.01, 0.02, 0.03, 0.04], handshakeTimeout: 30, pingInterval: 30, pingTimeout: 30)
        let client = PhoneSensorClient(
            endpoint: URL(string: "wss://example.test/ws")!,
            token: "",
            policy: policy,
            socketFactory: sockets.make,
            pathObserver: FakePathObserver()
        )
        let delays = Box<[TimeInterval]>([])
        let events = Box<[PhoneSensorClient.Event]>([])
        client.onRetryScheduled = { delay in delays.mutate { $0.append(delay) } }
        client.onEvent = { event in events.mutate { $0.append(event) } }

        client.connect()
        try waitUntil { sockets.count == 1 }
        sockets.socket(0).open()
        sockets.socket(0).close(.init(errorDescription: "lost"))
        // Each retry is accepted, then the server refuses it with 1013 because it still holds the old socket.
        for index in 1...3 {
            try waitUntil { sockets.count == index + 1 }
            sockets.socket(index).open()
            sockets.socket(index).close(.init(closeCode: 1013))
        }
        try waitUntil { delays.value.count == 4 }
        client.disconnect()

        XCTAssertEqual(delays.value, [0.01, 0.02, 0.03, 0.04], "server_busy must not reset the backoff")
        let reasons = events.value.compactMap { event -> String? in
            if case let .closed(reason, _) = event { return reason }
            return nil
        }
        XCTAssertEqual(reasons.prefix(4), ["error: lost", "server_busy", "server_busy", "server_busy"])
        let attempts = events.value.compactMap { event -> Int? in
            if case let .opened(attempts) = event { return attempts }
            return nil
        }
        XCTAssertEqual(attempts, [1, 1, 2, 3])
    }

    func testUnansweredPingClosesAndReconnects() throws {
        let sockets = FakeSocketFactory(answerPings: false)
        let policy = SensorReconnectPolicy(backoff: [0.01], handshakeTimeout: 30, pingInterval: 0.05, pingTimeout: 0.1)
        let client = PhoneSensorClient(
            endpoint: URL(string: "wss://example.test/ws")!,
            token: "",
            policy: policy,
            socketFactory: sockets.make,
            pathObserver: FakePathObserver()
        )
        let reasons = Box<[String]>([])
        client.onEvent = { event in
            if case let .closed(reason, _) = event { reasons.mutate { $0.append(reason) } }
        }
        client.connect()
        try waitUntil { sockets.count == 1 }
        sockets.socket(0).open()
        try waitUntil { reasons.value.first == "ping_timeout" }
        try waitUntil { sockets.count == 2 }
        XCTAssertTrue(sockets.socket(0).cancelled)
        client.disconnect()
    }

    func testStuckHandshakeTimesOut() throws {
        let sockets = FakeSocketFactory()
        let policy = SensorReconnectPolicy(backoff: [0.01], handshakeTimeout: 0.05, pingInterval: 30, pingTimeout: 30)
        let client = PhoneSensorClient(
            endpoint: URL(string: "wss://example.test/ws")!,
            token: "",
            policy: policy,
            socketFactory: sockets.make,
            pathObserver: FakePathObserver()
        )
        let reasons = Box<[String]>([])
        client.onEvent = { event in
            if case let .closed(reason, _) = event { reasons.mutate { $0.append(reason) } }
        }
        client.connect()
        try waitUntil { reasons.value.first == "handshake_timeout" }
        try waitUntil { sockets.count >= 2 }
        client.disconnect()
    }

    // MARK: - Helpers

    private func phoneEvents(_ writer: PhoneCaptureWriter) throws -> [[String: Any]] {
        try PhoneCaptureUploadPackage.jsonLines(in: writer.directoryURL.appendingPathComponent("phone.jsonl"))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                throw WaitTimeout()
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

// MARK: - Fakes

struct WaitTimeout: Error {}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

final class FakeSocket: SensorSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let onEvent: @Sendable (SensorSocketEvent) -> Void
    private let answerPings: Bool
    private var sent: [Data] = []
    private var isCancelled = false

    init(answerPings: Bool, onEvent: @escaping @Sendable (SensorSocketEvent) -> Void) {
        self.answerPings = answerPings
        self.onEvent = onEvent
    }

    var cancelled: Bool { lock.withLock { isCancelled } }
    var sentSequences: [UInt64] {
        lock.withLock { sent }.compactMap { JPEGSequenceStamp.readSequence(from: Data($0.dropFirst())) }
    }

    func open() { onEvent(.opened) }
    func close(_ info: SensorSocketCloseInfo) { onEvent(.closed(info)) }

    func start() {}
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { sent.append(data) }
        completion(nil)
    }
    func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
        if answerPings { completion(nil) }
    }
    func cancel() { lock.withLock { isCancelled = true } }
}

final class FakeSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let answerPings: Bool
    private var sockets: [FakeSocket] = []

    init(answerPings: Bool = true) { self.answerPings = answerPings }

    var count: Int { lock.withLock { sockets.count } }
    func socket(_ index: Int) -> FakeSocket { lock.withLock { sockets[index] } }

    var make: SensorSocketFactory {
        { [self] _, onEvent in
            let socket = FakeSocket(answerPings: answerPings, onEvent: onEvent)
            lock.withLock { sockets.append(socket) }
            return socket
        }
    }
}

final class FakePathObserver: NetworkPathObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?
    private var queue: DispatchQueue?
    private var isCancelled = false

    var cancelled: Bool { lock.withLock { isCancelled } }

    func start(queue: DispatchQueue, onChange: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            self.queue = queue
            handler = onChange
        }
    }

    func cancel() { lock.withLock { isCancelled = true; handler = nil } }

    func report(_ available: Bool) {
        let (queue, handler) = lock.withLock { (self.queue, self.handler) }
        queue?.async { handler?(available) }
    }
}

final class FakeCamera: PhoneFrameSource, @unchecked Sendable {
    var onJPEG: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    func start() {}
    func stop() {}
    func emit() { onJPEG?(Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])) }
}

final class FakeMotion: PhoneMotionSource, @unchecked Sendable {
    var onPacket: (@Sendable (PhoneImuPacket, UInt64) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    func start() {}
    func stop() {}
}
