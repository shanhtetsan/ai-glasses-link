import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import AIGlassesLink

final class JPEGSequenceStampTests: XCTestCase {
    func testStampInsertsCOMSegmentRightAfterSOI() throws {
        for sequence: UInt64 in [42, 123_456] {
            let jpeg = try Self.makeJPEG()
            let stamped = try JPEGSequenceStamp.stamp(jpeg, sequence: sequence)

            let text = Array("seq=\(sequence)".utf8)
            let length = text.count + 2
            let expectedHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + text
            XCTAssertEqual(Array(stamped.prefix(expectedHeader.count)), expectedHeader, "seq \(sequence)")
            XCTAssertEqual(stamped.count, jpeg.count + 2 + length)
            XCTAssertEqual(stamped.dropFirst(expectedHeader.count), jpeg.dropFirst(2))
            XCTAssertEqual(JPEGSequenceStamp.readSequence(from: stamped), sequence)
        }
    }

    func testStampedJPEGStillDecodes() throws {
        let jpeg = try Self.makeJPEG(width: 64, height: 48)
        let stamped = try JPEGSequenceStamp.stamp(jpeg, sequence: 123_456)

        let image = try ImageDecoder.decodeJPEG(stamped)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(stamped as CFData, nil))
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testStreamedAndSavedFramesCarrySameSequence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let writer = try PhoneCaptureWriter(
            sessionID: "T01_P01",
            trial: TrialFormData(trial: "T01", pid: "P01"),
            rootURL: root
        )

        let sequence: UInt64 = 7
        let payloads = try PhoneCaptureCoordinator.makeFramePayloads(
            jpeg: try Self.makeJPEG(),
            sequence: sequence
        )
        try writer.saveFrame(payloads.stamped, sequence: sequence)
        writer.close()

        let saved = try Data(contentsOf: writer.framesURL.appendingPathComponent("\(sequence).jpg"))
        XCTAssertEqual(payloads.wireMessage.first, MessageType.camera.rawValue)
        let streamed = Data(payloads.wireMessage.dropFirst())

        XCTAssertEqual(JPEGSequenceStamp.readSequence(from: saved), sequence)
        XCTAssertEqual(JPEGSequenceStamp.readSequence(from: streamed), sequence)
        XCTAssertEqual(streamed, saved)
    }

    func testStampRejectsDataWithoutSOI() {
        XCTAssertThrowsError(try JPEGSequenceStamp.stamp(Data([0x00, 0x01, 0xFF, 0xD9]), sequence: 1)) {
            XCTAssertEqual($0 as? JPEGSequenceStampError, .missingSOI)
        }
        XCTAssertThrowsError(try JPEGSequenceStamp.stamp(Data(), sequence: 1))
        XCTAssertThrowsError(
            try PhoneCaptureCoordinator.makeFramePayloads(jpeg: Data([0x89, 0x50]), sequence: 1)
        )
    }

    func testStampFailureIsLoggedWithSequenceAndReason() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let writer = try PhoneCaptureWriter(
            sessionID: "T01_P01",
            trial: TrialFormData(trial: "T01", pid: "P01"),
            rootURL: root
        )

        try writer.logFrameStampFailure(
            sequence: 9,
            reason: JPEGSequenceStampError.missingSOI.localizedDescription,
            byteCount: 4
        )
        writer.close()

        let lines = try String(
            contentsOf: writer.directoryURL.appendingPathComponent("phone.jsonl"),
            encoding: .utf8
        ).split(separator: "\n")
        let event = try XCTUnwrap(
            lines.compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }.first { $0["event"] as? String == "frame_stamp_failure" }
        )
        XCTAssertEqual(event["seq"] as? Int, 9)
        XCTAssertEqual(event["error"] as? String, JPEGSequenceStampError.missingSOI.localizedDescription)
        XCTAssertEqual(event["bytes"] as? Int, 4)
        XCTAssertEqual(writer.framesSaved, 0)
    }

    private static func makeJPEG(width: Int = 32, height: Int = 24) throws -> Data {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(
            CIContext().jpegRepresentation(
                of: image,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [:]
            )
        )
    }
}
