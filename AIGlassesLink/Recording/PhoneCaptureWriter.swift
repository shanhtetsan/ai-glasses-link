import Foundation

struct TrialFormData: Codable, Equatable, Sendable {
    var trial = ""
    var pid = ""
    var site = ""
    var cond = ""
    var task = ""
    var successCriterion = ""

    enum CodingKeys: String, CodingKey {
        case trial, pid, site, cond, task
        case successCriterion = "success_criterion"
    }
}

enum PhoneCaptureUploadState: String, Codable, Sendable {
    case pending
    case uploading
    case uploaded
}

struct PhoneCaptureManifest: Codable, Equatable, Sendable {
    let sessionID: String
    let trial: TrialFormData
    let createdAt: String
    var uploadState: PhoneCaptureUploadState
    var lastUploadError: String?
    var uploadAttempts: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case trial
        case createdAt = "created_at"
        case uploadState = "upload_state"
        case lastUploadError = "last_upload_error"
        case uploadAttempts = "upload_attempts"
    }
}

final class PhoneCaptureWriter: @unchecked Sendable {
    static let capturesFolderName = "PhoneCaptures"

    let sessionID: String
    let directoryURL: URL
    let framesURL: URL

    private let lock = NSLock()
    private let fileManager: FileManager
    private let imuHandle: FileHandle
    private let phoneHandle: FileHandle
    private(set) var framesSaved: Int
    private var closed = false

    init(
        sessionID: String,
        trial: TrialFormData,
        rootURL: URL = PhoneCaptureWriter.defaultRootURL(),
        fileManager: FileManager = .default
    ) throws {
        guard Self.isSafeSessionID(sessionID) else {
            throw PhoneCaptureWriterError.invalidSessionID
        }
        self.sessionID = sessionID
        self.fileManager = fileManager
        directoryURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        framesURL = directoryURL.appendingPathComponent("frames", isDirectory: true)

        try fileManager.createDirectory(at: framesURL, withIntermediateDirectories: true)
        let imuURL = directoryURL.appendingPathComponent("imu.jsonl")
        let phoneURL = directoryURL.appendingPathComponent("phone.jsonl")
        imuHandle = try Self.appendHandle(at: imuURL, fileManager: fileManager)
        phoneHandle = try Self.appendHandle(at: phoneURL, fileManager: fileManager)
        framesSaved = try fileManager.contentsOfDirectory(
            at: framesURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "jpg" }.count

        let manifestURL = directoryURL.appendingPathComponent("capture.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            let manifest = PhoneCaptureManifest(
                sessionID: sessionID,
                trial: trial,
                createdAt: Self.wallClockTimestamp(),
                uploadState: .pending,
                lastUploadError: nil,
                uploadAttempts: 0
            )
            try Self.writeManifest(manifest, to: manifestURL)
        }
        try logPhoneEvent("app_start")
    }

    deinit {
        close()
    }

    func saveFrame(_ jpeg: Data, sequence: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw PhoneCaptureWriterError.closed }
        let destination = framesURL.appendingPathComponent("\(sequence).jpg")
        try jpeg.write(to: destination, options: [.atomic])
        let handle = try FileHandle(forWritingTo: destination)
        try handle.synchronize()
        try handle.close()
        framesSaved += 1
    }

    func saveIMU(_ packet: PhoneImuPacket, monotonicNanoseconds: UInt64) throws {
        try appendJSONLine(
            [
                "ts": Self.wallClockTimestamp(),
                "monotonic_ns": monotonicNanoseconds,
                "sequence": packet.sequence,
                "uptime_ms": packet.uptimeMilliseconds,
                "accel_x": packet.accelX,
                "accel_y": packet.accelY,
                "accel_z": packet.accelZ,
                "gyro_x": packet.gyroX,
                "gyro_y": packet.gyroY,
                "gyro_z": packet.gyroZ,
            ],
            to: imuHandle
        )
    }

    func logPhoneEvent(
        _ event: String,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        details: [String: Any] = [:]
    ) throws {
        var object = details
        object["event"] = event
        object["ts"] = Self.wallClockTimestamp()
        object["monotonic_ns"] = monotonicNanoseconds
        try appendJSONLine(object, to: phoneHandle)
    }

    func logFrameStampFailure(sequence: UInt64, reason: String, byteCount: Int) throws {
        try logPhoneEvent(
            "frame_stamp_failure",
            details: ["seq": sequence, "error": reason, "bytes": byteCount]
        )
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        try? imuHandle.synchronize()
        try? phoneHandle.synchronize()
        try? imuHandle.close()
        try? phoneHandle.close()
        closed = true
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport.appendingPathComponent(capturesFolderName, isDirectory: true)
    }

    static func loadManifest(in directoryURL: URL) throws -> PhoneCaptureManifest {
        let data = try Data(contentsOf: directoryURL.appendingPathComponent("capture.json"))
        return try JSONDecoder().decode(PhoneCaptureManifest.self, from: data)
    }

    static func writeManifest(_ manifest: PhoneCaptureManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }

    private func appendJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw PhoneCaptureWriterError.closed }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func appendHandle(at url: URL, fileManager: FileManager) throws -> FileHandle {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private static func wallClockTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 65
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }
}

enum PhoneCaptureWriterError: LocalizedError {
    case invalidSessionID
    case closed

    var errorDescription: String? {
        switch self {
        case .invalidSessionID: "The backend returned an invalid session id."
        case .closed: "The local capture writer is closed."
        }
    }
}
