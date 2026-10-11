import Foundation
import XCTest
@testable import AIGlassesLink

final class JitterBufferTests: XCTestCase {
    func testDequeuesPCMInArrivalOrder() {
        var buffer = PCM16JitterBuffer()
        let first = Data([0x01, 0x00])
        let second = Data([0x02, 0x00, 0x03, 0x00])

        buffer.enqueue(first)
        buffer.enqueue(second)
        XCTAssertEqual(buffer.byteCount, 6)
        XCTAssertEqual(buffer.dequeue(), first)
        XCTAssertEqual(buffer.dequeue(), second)
        XCTAssertNil(buffer.dequeue())
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testResetFlushesEveryQueuedPacketImmediately() {
        var buffer = PCM16JitterBuffer()
        buffer.enqueue(Data(repeating: 0x11, count: 640))
        buffer.enqueue(Data(repeating: 0x22, count: 2_040))

        buffer.reset()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertNil(buffer.dequeue())
    }
}
