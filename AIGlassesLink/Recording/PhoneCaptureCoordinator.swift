import Foundation

final class PhoneCaptureCoordinator: @unchecked Sendable {
    var onFrameSaved: (@Sendable (Data, Int) -> Void)?
    var onFrameSent: (@Sendable () -> Void)?
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
        frameSequence = UInt64(writer.framesSaved)
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

    private func handleFrame(_ jpeg: Data) {
        guard accepting else { return }
        frameSequence &+= 1
        do {
            try writer.saveFrame(jpeg, sequence: frameSequence)
            onFrameSaved?(jpeg, writer.framesSaved)
            var message = Data([MessageType.camera.rawValue])
            message.append(jpeg)
            sensorClient.send(message, kind: .frame)
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
