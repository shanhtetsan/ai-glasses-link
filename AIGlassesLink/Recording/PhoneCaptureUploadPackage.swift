import Foundation

/// manifest.json as the backend upload contract defines it: exactly these 7 keys.
struct PhoneCaptureUploadManifest: Codable, Equatable, Sendable {
    let sessionID: String
    let appVersion: String
    let device: String
    let frames: Int
    let imuSamples: Int
    let startedTS: String
    let endedTS: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case appVersion = "app_version"
        case device
        case frames
        case imuSamples = "imu_samples"
        case startedTS = "started_ts"
        case endedTS = "ended_ts"
    }
}

/// Builds the upload ZIP contents for one capture folder. The ZIP holds only
/// manifest.json, imu.jsonl, phone.jsonl and frames/<digits>.jpg; capture.json stays local.
enum PhoneCaptureUploadPackage {
    static let manifestFileName = "manifest.json"

    struct Contents {
        let manifest: PhoneCaptureUploadManifest
        let items: [StoredZipWriter.Item]
    }

    /// Writes manifest.json into the capture folder and returns the files to archive.
    static func prepare(
        directory: URL,
        sessionID: String,
        appVersion: String = currentAppVersion(),
        device: String = currentDeviceModel(),
        fileManager: FileManager = .default
    ) throws -> Contents {
        let imuURL = directory.appendingPathComponent("imu.jsonl")
        let phoneURL = directory.appendingPathComponent("phone.jsonl")
        for url in [imuURL, phoneURL] where !fileManager.fileExists(atPath: url.path) {
            throw PhoneCaptureUploadPackageError.missingFile(url.lastPathComponent)
        }

        let framesURL = directory.appendingPathComponent("frames", isDirectory: true)
        let sequences = fileManager.fileExists(atPath: framesURL.path)
            ? try PhoneCaptureWriter.frameSequences(in: framesURL, fileManager: fileManager).sorted()
            : []
        var frameItems: [StoredZipWriter.Item] = []
        for sequence in sequences {
            let name = "\(sequence).jpg"
            let url = framesURL.appendingPathComponent(name)
            guard try startsWithSOI(url) else {
                throw PhoneCaptureUploadPackageError.invalidFrame(name)
            }
            frameItems.append(StoredZipWriter.Item(path: "frames/\(name)", fileURL: url))
        }

        let phoneLines = try jsonLines(in: phoneURL)
        let fallbackStart = (try? PhoneCaptureWriter.loadManifest(in: directory))?.createdAt
        let (startedTS, endedTS) = sessionTimes(phoneEvents: phoneLines, fallbackStart: fallbackStart)

        let manifest = PhoneCaptureUploadManifest(
            sessionID: sessionID,
            appVersion: appVersion,
            device: device,
            frames: frameItems.count,
            imuSamples: try jsonLines(in: imuURL).count,
            startedTS: startedTS,
            endedTS: endedTS
        )
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])

        let items = [
            StoredZipWriter.Item(path: manifestFileName, fileURL: manifestURL),
            StoredZipWriter.Item(path: "imu.jsonl", fileURL: imuURL),
            StoredZipWriter.Item(path: "phone.jsonl", fileURL: phoneURL),
        ] + frameItems
        return Contents(manifest: manifest, items: items)
    }

    /// Non-empty lines of a JSONL file that parse as JSON objects.
    static func jsonLines(in url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).compactMap { line in
            let trimmed = line.filter { $0 != 0x0D }
            guard !trimmed.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(trimmed))) as? [String: Any]
        }
    }

    /// started_ts is the first button_start, ended_ts the last button_stop. If those are
    /// missing (e.g. the app was killed mid-trial) fall back to the first and last logged events.
    static func sessionTimes(
        phoneEvents: [[String: Any]],
        fallbackStart: String?
    ) -> (started: String, ended: String) {
        func utc(_ event: [String: Any]) -> String? {
            guard let text = event["ts"] as? String,
                  let date = ISO8601DateFormatter().date(from: text) else { return nil }
            return ISO8601DateFormatter().string(from: date)
        }
        let starts = phoneEvents.filter { $0["event"] as? String == "button_start" }.compactMap(utc)
        let stops = phoneEvents.filter { $0["event"] as? String == "button_stop" }.compactMap(utc)
        let all = phoneEvents.compactMap(utc)
        let fallback = fallbackStart.flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { ISO8601DateFormatter().string(from: $0) }
        let started = starts.first ?? all.first ?? fallback ?? ISO8601DateFormatter().string(from: Date())
        let ended = stops.last ?? all.last ?? started
        return (started, ended)
    }

    static func currentAppVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Hardware model identifier, e.g. "iPhone16,1".
    static func currentDeviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func startsWithSOI(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 2) ?? Data()
        return head == Data([0xFF, 0xD8])
    }
}

enum PhoneCaptureUploadPackageError: LocalizedError, Equatable {
    case missingFile(String)
    case invalidFrame(String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(name): "Capture is missing \(name)."
        case let .invalidFrame(name): "frames/\(name) is not a JPEG (no FF D8 header)."
        }
    }
}
