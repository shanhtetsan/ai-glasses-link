import Foundation
import XCTest
@testable import AIGlassesLink

final class PhoneCaptureUploadTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func testZipWithSkippedSeqMatchesServerContract() throws {
        let writer = try makeWriter()
        try writer.logPhoneEvent("button_start")
        for sequence: UInt64 in [1, 2, 4] {
            try writer.saveFrame(try JPEGSequenceStamp.stamp(Self.tinyJPEG, sequence: sequence), sequence: sequence)
        }
        for index in 0..<3 {
            try writer.saveIMU(Self.packet(UInt32(index)), monotonicNanoseconds: UInt64(index))
        }
        try writer.logPhoneEvent("button_stop")
        writer.close()
        // A blank line and a corrupt line must not be counted as IMU samples.
        let imuURL = writer.directoryURL.appendingPathComponent("imu.jsonl")
        let imuHandle = try FileHandle(forWritingTo: imuURL)
        try imuHandle.seekToEnd()
        try imuHandle.write(contentsOf: Data("\n{\"sequence\": 9, trunc\n".utf8))
        try imuHandle.close()

        let contents = try PhoneCaptureUploadPackage.prepare(
            directory: writer.directoryURL,
            sessionID: writer.sessionID,
            appVersion: "1.0 (1)",
            device: "iPhone16,1"
        )
        let archive = root.appendingPathComponent("\(writer.sessionID).zip")
        try StoredZipWriter.createArchive(items: contents.items, at: archive)
        let entries = try Self.storedZipEntries(Data(contentsOf: archive))

        XCTAssertEqual(
            Set(entries.keys),
            ["manifest.json", "imu.jsonl", "phone.jsonl", "frames/1.jpg", "frames/2.jpg", "frames/4.jpg"]
        )
        XCTAssertNil(entries["capture.json"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: writer.directoryURL.appendingPathComponent("capture.json").path
        ), "capture.json stays in the local copy")

        let manifestData = try XCTUnwrap(entries["manifest.json"])
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any]).keys
        XCTAssertEqual(
            Set(keys),
            ["session_id", "app_version", "device", "frames", "imu_samples", "started_ts", "ended_ts"]
        )
        let manifest = try JSONDecoder().decode(PhoneCaptureUploadManifest.self, from: manifestData)
        XCTAssertEqual(manifest.sessionID, "T01_P01")
        XCTAssertEqual(manifest.frames, 3, "count of files, not the last seq (4)")
        XCTAssertEqual(manifest.imuSamples, 3)
        XCTAssertEqual(manifest.appVersion, "1.0 (1)")
        XCTAssertEqual(manifest.device, "iPhone16,1")
        for ts in [manifest.startedTS, manifest.endedTS] {
            XCTAssertTrue(ts.hasSuffix("Z"), ts)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: ts), ts)
        }
        XCTAssertLessThanOrEqual(manifest.startedTS, manifest.endedTS)

        for name in ["frames/1.jpg", "frames/2.jpg", "frames/4.jpg"] {
            XCTAssertEqual(entries[name]?.prefix(2), Data([0xFF, 0xD8]), name)
        }
        XCTAssertEqual(entries["frames/4.jpg"].flatMap(JPEGSequenceStamp.readSequence), 4)
    }

    func testResumeContinuesAfterHighestSeqWithoutOverwriting() throws {
        let first = try makeWriter()
        for sequence: UInt64 in [1, 2, 4] {
            try first.saveFrame(Self.tinyJPEG, sequence: sequence)
        }
        first.close()

        let resumed = try makeWriter()
        XCTAssertEqual(resumed.framesSaved, 3)
        XCTAssertEqual(resumed.highestFrameSequence, 4)

        // Rewriting an existing seq must not inflate the count.
        try resumed.saveFrame(Self.tinyJPEG, sequence: 4)
        XCTAssertEqual(resumed.framesSaved, 3)
        try resumed.saveFrame(Self.tinyJPEG, sequence: resumed.highestFrameSequence + 1)
        XCTAssertEqual(resumed.framesSaved, 4)
        XCTAssertEqual(resumed.highestFrameSequence, 5)
        resumed.close()
        XCTAssertEqual(
            try PhoneCaptureWriter.frameSequences(in: resumed.framesURL).sorted(),
            [1, 2, 4, 5]
        )
    }

    func testFrameWithoutSOIIsAPermanentFailure() throws {
        let writer = try makeWriter()
        try writer.saveFrame(Data([0x00, 0x00, 0xFF, 0xD9]), sequence: 1)
        writer.close()

        XCTAssertThrowsError(
            try PhoneCaptureUploadPackage.prepare(directory: writer.directoryURL, sessionID: writer.sessionID)
        ) { error in
            XCTAssertEqual(error as? PhoneCaptureUploadPackageError, .invalidFrame("1.jpg"))
            XCTAssertEqual(PhoneCaptureUploadManager.outcome(for: error), .failedPermanently)
        }
    }

    func testServerStatusesMapToRetryOrPermanentFailure() {
        for status in [422, 413] {
            XCTAssertEqual(
                PhoneCaptureUploadManager.outcome(for: TrialAPIError.http(status: status, message: nil)),
                .failedPermanently,
                "HTTP \(status)"
            )
        }
        for status in [409, 507, 500, 502, 503] {
            XCTAssertEqual(
                PhoneCaptureUploadManager.outcome(for: TrialAPIError.http(status: status, message: nil)),
                .retryLater,
                "HTTP \(status)"
            )
        }
        XCTAssertEqual(PhoneCaptureUploadManager.outcome(for: URLError(.timedOut)), .retryLater)
        XCTAssertEqual(
            PhoneCaptureUploadManager.describe(TrialAPIError.http(status: 422, message: "unexpected file capture.json")),
            "Upload rejected (HTTP 422): unexpected file capture.json"
        )
    }

    @MainActor
    func testFailedStateSurvivesReloadAndKeepsLocalCopy() throws {
        let writer = try makeWriter()
        writer.close()
        let manifestURL = writer.directoryURL.appendingPathComponent("capture.json")
        var manifest = try PhoneCaptureWriter.loadManifest(in: writer.directoryURL)
        manifest.uploadState = .failed
        manifest.lastUploadError = "Upload rejected (HTTP 422)"
        try PhoneCaptureWriter.writeManifest(manifest, to: manifestURL)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let manager = PhoneCaptureUploadManager(
            backendSettings: BackendSettings(defaults: defaults),
            rootURL: root
        )
        manager.start()
        let record = try XCTUnwrap(manager.captures.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.lastError, "Upload rejected (HTTP 422)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.directoryURL.path))
    }

    func testAuthAndNotFoundKeepRetryingWithVisibleMessages() {
        for status in [401, 403] {
            let error = TrialAPIError.http(status: status, message: "nope")
            XCTAssertEqual(PhoneCaptureUploadManager.outcome(for: error), .retryLater, "HTTP \(status)")
            XCTAssertEqual(PhoneCaptureUploadManager.describe(error), "Token rejected, check Settings")
        }
        let notFound = TrialAPIError.http(status: 404, message: nil)
        XCTAssertEqual(PhoneCaptureUploadManager.outcome(for: notFound), .retryLater)
        XCTAssertEqual(PhoneCaptureUploadManager.describe(notFound), "Trial not found on server")
    }

    func testR2StatusDecodingAndArchivedLabel() {
        func r2(_ json: String) -> String? {
            PhoneCaptureUploadReceipt.decode(Data(json.utf8)).r2Status
        }
        XCTAssertEqual(r2(#"{"ok": true, "r2": "done"}"#), "done")
        XCTAssertEqual(r2(#"{"r2": {"status": "queued"}}"#), "queued")
        XCTAssertEqual(r2(#"{"r2": true}"#), "done")
        XCTAssertNil(r2(#"{"ok": true}"#))
        XCTAssertNil(r2("not json"))

        XCTAssertTrue(PhoneCaptureUploadReceipt.isArchived("done"))
        XCTAssertFalse(PhoneCaptureUploadReceipt.isArchived("queued"))
        XCTAssertFalse(PhoneCaptureUploadReceipt.isArchived(nil))
    }

    @MainActor
    func testUploadedReceiptKeepsR2StatusAndOldReceiptsStillLoad() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipts = """
        [
          {"session_id": "T01_P01", "trial": {"trial": "T01", "pid": "P01", "site": "", "cond": "",
           "task": "", "success_criterion": ""}, "created_at": "2026-10-26T10:00:00Z",
           "status": "uploaded", "upload_attempts": 1, "r2_status": "done"},
          {"session_id": "T02_P01", "trial": {"trial": "T02", "pid": "P01", "site": "", "cond": "",
           "task": "", "success_criterion": ""}, "created_at": "2026-10-26T09:00:00Z",
           "status": "uploaded", "upload_attempts": 1}
        ]
        """
        try Data(receipts.utf8).write(to: root.appendingPathComponent("uploaded.json"))

        let manager = PhoneCaptureUploadManager(backendSettings: try Self.offlineSettings(), rootURL: root)
        let byID = Dictionary(uniqueKeysWithValues: manager.captures.map { ($0.sessionID, $0) })
        XCTAssertEqual(byID["T01_P01"]?.r2Status, "done")
        XCTAssertNil(byID["T02_P01"]?.r2Status)
    }

    @MainActor
    func testRetryResetsFailedCaptureAndDeletesNothing() async throws {
        let writer = try makeWriter()
        try writer.saveFrame(Self.tinyJPEG, sequence: 1)
        writer.close()
        var manifest = try PhoneCaptureWriter.loadManifest(in: writer.directoryURL)
        manifest.uploadState = .failed
        manifest.lastUploadError = "Upload rejected (HTTP 422)"
        try PhoneCaptureWriter.writeManifest(
            manifest,
            to: writer.directoryURL.appendingPathComponent("capture.json")
        )

        // No backend URL, so the single attempt cannot reach a server.
        let manager = PhoneCaptureUploadManager(backendSettings: try Self.offlineSettings(), rootURL: root)
        manager.retry(sessionID: writer.sessionID)
        XCTAssertEqual(manager.captures.first?.status, .pending)
        XCTAssertNil(manager.captures.first?.lastError)

        for _ in 0..<50 { await Task.yield() }
        XCTAssertNotEqual(manager.captures.first?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: writer.framesURL.appendingPathComponent("1.jpg").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: writer.directoryURL.appendingPathComponent("capture.json").path
        ))

        // Retry only applies to failed captures.
        manager.retry(sessionID: "does-not-exist")
        XCTAssertEqual(manager.captures.count, 1)
    }

    // MARK: - Helpers

    private static let tinyJPEG = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])

    @MainActor
    private static func offlineSettings() throws -> BackendSettings {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("", forKey: BackendSettings.backendURLKey)
        return BackendSettings(defaults: defaults)
    }

    private func makeWriter() throws -> PhoneCaptureWriter {
        try PhoneCaptureWriter(
            sessionID: "T01_P01",
            trial: TrialFormData(trial: "T01", pid: "P01"),
            rootURL: root
        )
    }

    private static func packet(_ sequence: UInt32) -> PhoneImuPacket {
        PhoneImuPacket(
            sequence: sequence, uptimeMilliseconds: sequence * 10,
            accelX: 0, accelY: 0, accelZ: 1, gyroX: 0, gyroY: 0, gyroZ: 0
        )
    }

    /// Reads a stored (uncompressed) ZIP via its central directory: name -> file bytes.
    private static func storedZipEntries(_ zip: Data) throws -> [String: Data] {
        let bytes = [UInt8](zip)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        let end = try XCTUnwrap(
            stride(from: bytes.count - 22, through: 0, by: -1).first { u32($0) == 0x0605_4B50 }
        )
        var offset = u32(end + 16)
        var entries: [String: Data] = [:]
        for _ in 0..<u16(end + 10) {
            XCTAssertEqual(u32(offset), 0x0201_4B50)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            entries[name] = Data(bytes[dataStart..<(dataStart + size)])
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}
