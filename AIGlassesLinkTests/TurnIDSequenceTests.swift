import XCTest
@testable import AIGlassesLink

final class TurnIDSequenceTests: XCTestCase {
    func testTurnIDsStartAtOneAndIncrementOncePerUtterance() {
        var sequence = TurnIDSequence()
        XCTAssertEqual(sequence.next(), 1)
        XCTAssertEqual(sequence.next(), 2)
        XCTAssertEqual(sequence.next(), 3)
        XCTAssertEqual(sequence.current, 3)
    }
}
