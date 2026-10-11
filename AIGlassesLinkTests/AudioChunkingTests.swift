import Foundation
import XCTest
@testable import AIGlassesLink

final class AudioChunkingTests: XCTestCase {
    func testEmitsOnlyExact640ByteChunksAndKeepsRemainder() {
        var chunker = PCMChunker()
        XCTAssertTrue(chunker.append(Data(repeating: 0x01, count: 639)).isEmpty)

        let first = chunker.append(Data([0x02]))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].count, 640)
        XCTAssertTrue(chunker.pending.isEmpty)

        let next = chunker.append(Data(repeating: 0x03, count: 1_281))
        XCTAssertEqual(next.map(\.count), [640, 640])
        XCTAssertEqual(chunker.pending, Data([0x03]))
    }

    func testResetDropsPartialAudio() {
        var chunker = PCMChunker()
        _ = chunker.append(Data(repeating: 0xAA, count: 100))
        chunker.reset()
        XCTAssertTrue(chunker.pending.isEmpty)
    }
}
