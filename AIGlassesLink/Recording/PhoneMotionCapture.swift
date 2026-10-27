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
        guard manager.isDeviceMotionAvailable else {
            onError?(PhoneMotionError.unavailable)
            return
        }
        sequence = 0
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.onError?(error)
                return
            }
            guard let motion else { return }
            self.sequence &+= 1
            let monotonic = DispatchTime.now().uptimeNanoseconds
            let uptimeMS = UInt32(truncatingIfNeeded: monotonic / 1_000_000)
            self.onPacket?(
                PhoneImuPacket(
                    sequence: self.sequence,
                    uptimeMilliseconds: uptimeMS,
                    motion: motion
                ),
                monotonic
            )
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

enum PhoneMotionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Motion sensors are unavailable on this device."
    }
}
