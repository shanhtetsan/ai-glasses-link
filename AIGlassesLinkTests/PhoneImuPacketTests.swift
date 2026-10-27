import XCTest
@testable import AIGlassesLink

final class PhoneImuPacketTests: XCTestCase {
    func testWireMessageIs33BytesAndRoundTripsLittleEndian() throws {
        let packet = PhoneImuPacket(
            sequence: 0x0102_0304,
            uptimeMilliseconds: 0xA1B2_C3D4,
            accelX: 1.25,
            accelY: -2.5,
            accelZ: 9.80665,
            gyroX: 90,
            gyroY: -180,
            gyroZ: 0.125
        )

        let message = packet.wireMessage()

        XCTAssertEqual(message.count, PhoneImuPacket.messageSize)
        XCTAssertEqual(message.first, MessageType.imu.rawValue)
        XCTAssertEqual(Array(message[1...4]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(try PhoneImuPacket.decodeWireMessage(message), packet)
    }

    func testFlatFaceUpPhoneHasPositiveGravityOnZ() {
        let acceleration = PhoneImuPacket.acceleration(rawX: 0, rawY: 0, rawZ: -1)

        XCTAssertEqual(acceleration.0, 0, accuracy: 0.0001)
        XCTAssertEqual(acceleration.1, 0, accuracy: 0.0001)
        XCTAssertEqual(acceleration.2, 9.80665, accuracy: 0.01)
    }
}
