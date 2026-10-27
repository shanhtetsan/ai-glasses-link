import Foundation
import XCTest
@testable import AIGlassesLink

final class PhoneCaptureWriterTests: XCTestCase {
    func testSocketDropDoesNotLoseLocallySavedFrames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let writer = try PhoneCaptureWriter(
            sessionID: "T01_P01",
            trial: TrialFormData(trial: "T01", pid: "P01"),
            rootURL: root
        )
        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9])

        try writer.saveFrame(first, sequence: 1)
        try writer.logPhoneEvent(
            "send_failure",
            details: ["payload": "frame", "error": "simulated socket drop"]
        )
        try writer.saveFrame(second, sequence: 2)
        writer.close()

        XCTAssertEqual(try Data(contentsOf: writer.framesURL.appendingPathComponent("1.jpg")), first)
        XCTAssertEqual(try Data(contentsOf: writer.framesURL.appendingPathComponent("2.jpg")), second)
        let log = try String(
            contentsOf: writer.directoryURL.appendingPathComponent("phone.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(log.contains("simulated socket drop"))
        XCTAssertEqual(writer.framesSaved, 2)
    }
}
