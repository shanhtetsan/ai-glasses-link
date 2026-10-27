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
    private let camera: PhoneCameraCapture
    private let motion: PhoneMotionCapture
    private let queue = DispatchQueue(label: "com.aiglasses.link.phone-capture-writer")
    private var frameSequence: UInt64
    private var accepting = false

    init(
        writer: PhoneCaptureWriter,
        sensorClient: PhoneSensorClient,
        camera: PhoneCameraCapture = PhoneCameraCapture(),
        motion: PhoneMotionCapture = PhoneMotionCapture()
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
        camera.stop()
        motion.stop()
        sensorClient.disconnect()
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
        sensorClient.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.queue.async {
                if self.accepting {
                    try? self.writer.logPhoneEvent(connected ? "socket_open" : "socket_close")
                }
                self.onConnectionChange?(connected)
            }
        }
        sensorClient.onSendResult = { [weak self] kind, succeeded, message in
            guard let self else { return }
            self.queue.async {
                guard self.accepting else { return }
                if succeeded {
                    if kind == .frame { self.onFrameSent?() }
                } else {
                    try? self.writer.logPhoneEvent(
                        "send_failure",
                        details: [
                            "payload": kind.rawValue,
                            "error": message ?? "unknown",
                        ]
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
