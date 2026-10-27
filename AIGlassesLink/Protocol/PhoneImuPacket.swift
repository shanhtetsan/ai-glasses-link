import CoreMotion
import Foundation

struct PhoneImuPacket: Equatable, Sendable {
    static let gravity = 9.80665
    static let payloadSize = 32
    static let messageSize = 33

    let sequence: UInt32
    let uptimeMilliseconds: UInt32
    let accelX: Float
    let accelY: Float
    let accelZ: Float
    let gyroX: Float
    let gyroY: Float
    let gyroZ: Float

    init(
        sequence: UInt32,
        uptimeMilliseconds: UInt32,
        accelX: Float,
        accelY: Float,
        accelZ: Float,
        gyroX: Float,
        gyroY: Float,
        gyroZ: Float
    ) {
        self.sequence = sequence
        self.uptimeMilliseconds = uptimeMilliseconds
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
    }

    init(sequence: UInt32, uptimeMilliseconds: UInt32, motion: CMDeviceMotion) {
        let acceleration = CMAcceleration(
            x: motion.userAcceleration.x + motion.gravity.x,
            y: motion.userAcceleration.y + motion.gravity.y,
            z: motion.userAcceleration.z + motion.gravity.z
        )
        self.init(
            sequence: sequence,
            uptimeMilliseconds: uptimeMilliseconds,
            accelX: Float(-acceleration.x * Self.gravity),
            accelY: Float(-acceleration.y * Self.gravity),
            accelZ: Float(-acceleration.z * Self.gravity),
            gyroX: Float(motion.rotationRate.x * 180 / .pi),
            gyroY: Float(motion.rotationRate.y * 180 / .pi),
            gyroZ: Float(motion.rotationRate.z * 180 / .pi)
        )
    }

    func wireMessage() -> Data {
        var data = Data([MessageType.imu.rawValue])
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(uptimeMilliseconds)
        for value in [accelX, accelY, accelZ, gyroX, gyroY, gyroZ] {
            data.appendLittleEndian(value.bitPattern)
        }
        return data
    }

    static func decodeWireMessage(_ data: Data) throws -> PhoneImuPacket {
        guard data.count == messageSize, data.first == MessageType.imu.rawValue else {
            throw PhoneImuPacketError.invalidMessage
        }
        let bytes = Array(data.dropFirst())
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        return PhoneImuPacket(
            sequence: uint32(0),
            uptimeMilliseconds: uint32(4),
            accelX: Float(bitPattern: uint32(8)),
            accelY: Float(bitPattern: uint32(12)),
            accelZ: Float(bitPattern: uint32(16)),
            gyroX: Float(bitPattern: uint32(20)),
            gyroY: Float(bitPattern: uint32(24)),
            gyroZ: Float(bitPattern: uint32(28))
        )
    }

    static func acceleration(rawX: Double, rawY: Double, rawZ: Double) -> (Float, Float, Float) {
        (
            Float(-rawX * gravity),
            Float(-rawY * gravity),
            Float(-rawZ * gravity)
        )
    }
}

enum PhoneImuPacketError: Error {
    case invalidMessage
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
