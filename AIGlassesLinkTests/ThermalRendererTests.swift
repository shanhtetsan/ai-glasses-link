import XCTest
@testable import AIGlassesLink

final class ThermalRendererTests: XCTestCase {
    func testPaletteEndpointsAndClamping() {
        XCTAssertEqual(
            FalseColorPalette.color(at: 0),
            RGBA(red: 0, green: 20, blue: 150, alpha: 255)
        )
        XCTAssertEqual(
            FalseColorPalette.color(at: 1),
            RGBA(red: 230, green: 20, blue: 0, alpha: 255)
        )
        XCTAssertEqual(FalseColorPalette.color(at: -1), FalseColorPalette.color(at: 0))
        XCTAssertEqual(FalseColorPalette.color(at: 2), FalseColorPalette.color(at: 1))
    }

    func testRendersNormalAndUniformFramesAtCanonicalSize() throws {
        let gradient = try ThermalFrame(values: (0..<768).map(Float.init))
        let gradientImage = try ThermalRenderer.render(gradient)
        XCTAssertEqual(gradientImage.width, 24)
        XCTAssertEqual(gradientImage.height, 32)

        let uniform = try ThermalFrame(values: [Float](repeating: 21.5, count: 768))
        let uniformImage = try ThermalRenderer.render(uniform)
        XCTAssertEqual(uniformImage.width, 24)
        XCTAssertEqual(uniformImage.height, 32)
    }
}
