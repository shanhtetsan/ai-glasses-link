import Foundation
import XCTest
@testable import AIGlassesLink

final class IncomingMessageTests: XCTestCase {
    func testDispatchesAllFourMessageTypes() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        XCTAssertEqual(try IncomingMessage.parse(framed(0x01, jpeg)), .camera(jpeg))

        let thermal = Data(repeating: 0xAA, count: 3_072)
        XCTAssertEqual(try IncomingMessage.parse(framed(0x02, thermal)), .thermal(thermal))

        let imu = Data(repeating: 0xBB, count: 32)
        XCTAssertEqual(try IncomingMessage.parse(framed(0x03, imu)), .imu(imu))

        let status = Data(repeating: 0xCC, count: 16)
        XCTAssertEqual(try IncomingMessage.parse(framed(0x04, status)), .status(status))
    }

    func testRejectsEmptyAndUnknownMessages() {
        XCTAssertThrowsError(try IncomingMessage.parse(Data())) { error in
            XCTAssertEqual(error as? IncomingMessageError, .missingDiscriminator)
        }
        XCTAssertThrowsError(try IncomingMessage.parse(Data([0x05]))) { error in
            XCTAssertEqual(error as? IncomingMessageError, .unknownType(0x05))
        }
    }

    func testValidatesFixedPayloadSizes() {
        XCTAssertThrowsError(try IncomingMessage.parse(framed(0x02, Data(count: 3_071))))
        XCTAssertThrowsError(try IncomingMessage.parse(framed(0x03, Data(count: 31))))
        XCTAssertThrowsError(try IncomingMessage.parse(framed(0x04, Data(count: 17))))
    }

    private func framed(_ type: UInt8, _ payload: Data) -> Data {
        var message = Data([type])
        message.append(payload)
        return message
    }
}
