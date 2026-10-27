import CoreMotion
import Foundation

final class PhoneMotionCapture: @unchecked Sendable {
    var onPacket: (@Sendable (PhoneImuPacket, UInt64) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.aiglasses.link.phone-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var sequence: UInt32 = 0

    func start() {
        guard manager.isAccelerometerAvailable, manager.isGyroAvailable else {
            onError?(PhoneMotionError.unavailable)
            return
        }
        sequence = 0
        manager.accelerometerUpdateInterval = 1.0 / 50.0
        manager.gyroUpdateInterval = 1.0 / 50.0
        manager.startGyroUpdates()
        manager.startAccelerometerUpdates(to: queue) { [weak self] sample, error in
            guard let self else { return }
            if let error {
                self.onError?(error)
                return
            }
            guard let sample else { return }
            self.sequence &+= 1
            let monotonic = DispatchTime.now().uptimeNanoseconds
            let uptimeMS = UInt32(truncatingIfNeeded: monotonic / 1_000_000)
            let rotationRate = self.manager.gyroData?.rotationRate
                ?? CMRotationRate(x: 0, y: 0, z: 0)
            self.onPacket?(
                PhoneImuPacket(
                    sequence: self.sequence,
                    uptimeMilliseconds: uptimeMS,
                    acceleration: sample.acceleration,
                    rotationRate: rotationRate
                ),
                monotonic
            )
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
    }
}

enum PhoneMotionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Motion sensors are unavailable on this device."
    }
}
