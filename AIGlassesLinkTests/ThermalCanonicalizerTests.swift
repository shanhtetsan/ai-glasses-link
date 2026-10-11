import Foundation
import XCTest
@testable import AIGlassesLink

final class ThermalCanonicalizerTests: XCTestCase {
    func testCanonicalMappingMatchesBackendTransform() throws {
        let native = (0..<(24 * 32)).map(Float.init)
        let frame = try ThermalCanonicalizer.decodeAndCanonicalize(littleEndianData(native))

        XCTAssertEqual(frame.values.count, 768)
        XCTAssertEqual(frame[31, 23], native[0])       // native top-left
        XCTAssertEqual(frame[0, 23], native[31])      // native top-right
        XCTAssertEqual(frame[31, 0], native[23 * 32]) // native bottom-left
        XCTAssertEqual(frame[0, 0], native[23 * 32 + 31]) // native bottom-right

        for sourceRow in 0..<24 {
            for sourceColumn in 0..<32 {
                let destinationRow = 31 - sourceColumn
                let destinationColumn = 23 - sourceRow
                XCTAssertEqual(
                    frame[destinationRow, destinationColumn],
                    native[sourceRow * 32 + sourceColumn]
                )
            }
        }
    }

    func testRejectsWrongLength() {
        XCTAssertThrowsError(
            try ThermalCanonicalizer.decodeAndCanonicalize(Data(count: 3_068))
        ) { error in
            XCTAssertEqual(error as? ThermalError, .invalidPayloadSize(3_068))
        }
    }

    func testRejectsEveryNonFiniteRepresentation() {
        for invalidValue in [Float.nan, Float.infinity, -Float.infinity] {
            var values = [Float](repeating: 20, count: 768)
            values[257] = invalidValue
            XCTAssertThrowsError(
                try ThermalCanonicalizer.decodeAndCanonicalize(littleEndianData(values))
            ) { error in
                XCTAssertEqual(error as? ThermalError, .nonFiniteValue(index: 257))
            }
        }
    }

    private func littleEndianData(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}
