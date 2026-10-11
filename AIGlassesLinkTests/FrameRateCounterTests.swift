import XCTest
@testable import AIGlassesLink

final class FrameRateCounterTests: XCTestCase {
    func testCountsOnlyFramesInsideRollingWindow() {
        var counter = FrameRateCounter(window: 1)
        counter.record(at: 10.0)
        counter.record(at: 10.2)
        counter.record(at: 10.8)

        XCTAssertEqual(counter.framesPerSecond(at: 10.9), 3)
        XCTAssertEqual(counter.framesPerSecond(at: 11.1), 2)
        XCTAssertEqual(counter.framesPerSecond(at: 12.0), 0)
    }

    func testResetClearsFrames() {
        var counter = FrameRateCounter()
        counter.record(at: 1)
        counter.reset()
        XCTAssertEqual(counter.framesPerSecond(at: 1.1), 0)
    }
}
