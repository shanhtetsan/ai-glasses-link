import Foundation

final class PhoneCaptureCoordinator: @unchecked Sendable {
    var onFrameSaved: (@Sendable (Data, Int) -> Void)?
    var onFrameSent: (@Sendable () -> Void)?
    var onFrameStampFailed: (@Sendable () -> Void)?
    var onIMUSaved: (@Sendable () -> Void)?
    var onConnectionChange: (@Sendable (Bool) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let writer: PhoneCaptureWriter
    private let sensorClient: PhoneSensorClient
    private let camera: PhoneFrameSource
    private let motion: PhoneMotionSource
    private let queue = DispatchQueue(label: "com.aiglasses.link.phone-capture-writer")
    private var frameSequence: UInt64
    private var accepting = false
    /// Payloads captured while the socket was down; reported in the next socket_open.
    private var framesNotSent = 0
    private var imuNotSent = 0

    init(
        writer: PhoneCaptureWriter,
        sensorClient: PhoneSensorClient,
        camera: PhoneFrameSource = PhoneCameraCapture(),
        motion: PhoneMotionSource = PhoneMotionCapture()
    ) {
        self.writer = writer
        self.sensorClient = sensorClient
        self.camera = camera
        self.motion = motion
        frameSequence = writer.highestFrameSequence
        installCallbacks()
    }

    func start(buttonMonotonicNanoseconds: UInt64) {
        queue.sync {
            accepting = true
            framesNotSent = 0
            imuNotSent = 0
            do {
                try writer.logPhoneEvent(
                    "button_start",
                    monotonicNanoseconds: buttonMonotonicNanoseconds
                )
            } catch {
                onError?(error)
            }
        }
        sensorClient.connect()
        camera.start()
        motion.start()
    }

    func stop(buttonMonotonicNanoseconds: UInt64) {
        queue.sync {
            guard accepting else { return }
            do {
                try writer.logPhoneEvent(
                    "socket_close",
                    details: ["reason": "button_stop"]
                )
                try writer.logPhoneEvent(
                    "button_stop",
                    monotonicNanoseconds: buttonMonotonicNanoseconds
                )
            } catch {
                onError?(error)
            }
            accepting = false
            writer.close()
        }
        camera.stop()
        motion.stop()
        sensorClient.disconnect()
    }

    private func installCallbacks() {
        camera.onJPEG = { [weak self] jpeg in
            self?.queue.async { self?.handleFrame(jpeg) }
        }
        camera.onError = { [weak self] error in self?.onError?(error) }
        motion.onPacket = { [weak self] packet, monotonic in
            self?.queue.async { self?.handleIMU(packet, monotonic: monotonic) }
        }
        motion.onError = { [weak self] error in self?.onError?(error) }
        sensorClient.onEvent = { [weak self] event in
            guard let self else { return }
            self.queue.async { self.handleSocketEvent(event) }
        }
        sensorClient.onSendResult = { [weak self] kind, result in
            guard let self else { return }
            self.queue.async {
                guard self.accepting else { return }
                switch result {
                case .sent:
                    if kind == .frame { self.onFrameSent?() }
                case .notConnected:
                    // Not resent later; the uploaded capture has every frame.
                    if kind == .frame { self.framesNotSent += 1 } else { self.imuNotSent += 1 }
                case let .failed(message):
                    try? self.writer.logPhoneEvent(
                        "send_failure",
                        details: ["payload": kind.rawValue, "error": message]
                    )
                }
            }
        }
    }

    /// Stamps the frame once; the saved copy and the wire message carry the same bytes.
    static func makeFramePayloads(
        jpeg: Data,
        sequence: UInt64
    ) throws -> (stamped: Data, wireMessage: Data) {
        let stamped = try JPEGSequenceStamp.stamp(jpeg, sequence: sequence)
        var message = Data([MessageType.camera.rawValue])
        message.append(stamped)
        return (stamped, message)
    }

    private func handleSocketEvent(_ event: PhoneSensorClient.Event) {
        switch event {
        case let .opened(attempts):
            if accepting {
                try? writer.logPhoneEvent(
                    "socket_open",
                    details: [
                        "attempts": attempts,
                        "frames_not_sent": framesNotSent,
                        "imu_not_sent": imuNotSent,
                    ]
                )
            }
            framesNotSent = 0
            imuNotSent = 0
            onConnectionChange?(true)
        case let .closed(reason, wasOpen):
            if accepting {
                try? writer.logPhoneEvent(
                    "socket_close",
                    details: ["reason": reason, "was_open": wasOpen]
                )
            }
            onConnectionChange?(false)
        }
    }

    private func handleFrame(_ jpeg: Data) {
        guard accepting else { return }
        frameSequence &+= 1
        let payloads: (stamped: Data, wireMessage: Data)
        do {
            payloads = try Self.makeFramePayloads(jpeg: jpeg, sequence: frameSequence)
        } catch {
            // Not a valid JPEG, so it is neither saved nor sent; record why.
            onFrameStampFailed?()
            do {
                try writer.logFrameStampFailure(
                    sequence: frameSequence,
                    reason: error.localizedDescription,
                    byteCount: jpeg.count
                )
            } catch {
                onError?(error)
            }
            return
        }
        do {
            try writer.saveFrame(payloads.stamped, sequence: frameSequence)
            onFrameSaved?(payloads.stamped, writer.framesSaved)
            sensorClient.send(payloads.wireMessage, kind: .frame)
        } catch {
            onError?(error)
        }
    }

    private func handleIMU(_ packet: PhoneImuPacket, monotonic: UInt64) {
        guard accepting else { return }
        do {
            try writer.saveIMU(packet, monotonicNanoseconds: monotonic)
            onIMUSaved?()
            sensorClient.send(packet.wireMessage(), kind: .imu)
        } catch {
            onError?(error)
        }
    }
}
