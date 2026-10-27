import Foundation
import XCTest
@testable import AIGlassesLink

final class PhoneCaptureArchiveTests: XCTestCase {
    func testArchiveContainsCaptureFilesAndUploadPathUsesSessionID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("T07_P03", isDirectory: true)
        let frames = source.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: frames.appendingPathComponent("1.jpg"))
        try Data("{\"sequence\":1}\n".utf8).write(to: source.appendingPathComponent("imu.jsonl"))
        let archive = root.appendingPathComponent("T07_P03.zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try StoredZipWriter.createArchive(from: source, at: archive)

        let data = try Data(contentsOf: archive)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertTrue(data.range(of: Data("frames/1.jpg".utf8)) != nil)
        XCTAssertTrue(data.range(of: Data("imu.jsonl".utf8)) != nil)
        XCTAssertEqual(
            PhoneCaptureUploadClient.path(sessionID: "T07_P03"),
            "/internal/trial/T07_P03/phone_capture"
        )
    }
}
