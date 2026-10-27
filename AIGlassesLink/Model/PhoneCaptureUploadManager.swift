import Foundation

struct LocalCaptureRecord: Codable, Identifiable, Equatable, Sendable {
    let sessionID: String
    let trial: TrialFormData
    let createdAt: String
    var status: PhoneCaptureUploadState
    var lastError: String?
    var uploadAttempts: Int

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case trial
        case createdAt = "created_at"
        case status
        case lastError = "last_error"
        case uploadAttempts = "upload_attempts"
    }
}

@MainActor
final class PhoneCaptureUploadManager: ObservableObject {
    @Published private(set) var captures: [LocalCaptureRecord] = []

    private let backendSettings: BackendSettings
    private let client: PhoneCaptureUploadClient
    private let rootURL: URL
    private let fileManager: FileManager
    private var uploadTasks: [String: Task<Void, Never>] = [:]

    init(
        backendSettings: BackendSettings,
        client: PhoneCaptureUploadClient = PhoneCaptureUploadClient(),
        rootURL: URL = PhoneCaptureWriter.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.backendSettings = backendSettings
        self.client = client
        self.rootURL = rootURL
        self.fileManager = fileManager
        refresh()
    }

    func start() {
        refresh()
        for capture in captures where capture.status != .uploaded {
            enqueue(sessionID: capture.sessionID)
        }
    }

    func enqueue(sessionID: String) {
        refresh()
        guard uploadTasks[sessionID] == nil,
              captures.contains(where: { $0.sessionID == sessionID && $0.status != .uploaded }) else {
            return
        }
        uploadTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            var retry = 0
            while !Task.isCancelled {
                if await self.uploadOnce(sessionID: sessionID) { break }
                retry += 1
                let seconds = min(pow(2.0, Double(retry)), 60)
                try? await Task.sleep(for: .seconds(seconds))
            }
            self.uploadTasks[sessionID] = nil
        }
    }

    func refresh() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var records = try uploadedReceipts()
            let directories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for directory in directories {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                guard var manifest = try? PhoneCaptureWriter.loadManifest(in: directory) else { continue }
                if manifest.uploadState == .uploading {
                    manifest.uploadState = .pending
                    try? PhoneCaptureWriter.writeManifest(
                        manifest,
                        to: directory.appendingPathComponent("capture.json")
                    )
                }
                let record = LocalCaptureRecord(
                    sessionID: manifest.sessionID,
                    trial: manifest.trial,
                    createdAt: manifest.createdAt,
                    status: manifest.uploadState == .uploaded ? .uploaded : .pending,
                    lastError: manifest.lastUploadError,
                    uploadAttempts: manifest.uploadAttempts
                )
                if manifest.uploadState == .uploaded {
                    do {
                        try persistUploadedReceipt(record)
                        try? fileManager.removeItem(at: directory)
                        try? fileManager.removeItem(
                            at: rootURL.appendingPathComponent("\(manifest.sessionID).zip")
                        )
                    } catch {
                        // Keep the confirmed local copy until its durable receipt can be saved.
                    }
                }
                records.removeAll { $0.sessionID == manifest.sessionID }
                records.append(record)
            }
            captures = records.sorted { $0.createdAt > $1.createdAt }
        } catch {
            captures = []
        }
    }

    private func uploadOnce(sessionID: String) async -> Bool {
        guard let baseURL = backendSettings.normalizedBaseURL,
              let record = captures.first(where: { $0.sessionID == sessionID }) else {
            return false
        }
        let directory = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        let archive = rootURL.appendingPathComponent("\(sessionID).zip")
        do {
            try updateManifest(sessionID: sessionID) { manifest in
                manifest.uploadState = .uploading
                manifest.lastUploadError = nil
                manifest.uploadAttempts += 1
            }
            refresh()
            try await Task.detached(priority: .utility) {
                try StoredZipWriter.createArchive(from: directory, at: archive)
            }.value
            try await client.upload(
                archiveURL: archive,
                sessionID: sessionID,
                baseURL: baseURL,
                token: backendSettings.trialToken
            )
            try updateManifest(sessionID: sessionID) { manifest in
                manifest.uploadState = .uploaded
                manifest.lastUploadError = nil
            }
            try persistUploadedReceipt(record)
            try? fileManager.removeItem(at: directory)
            try? fileManager.removeItem(at: archive)
            refresh()
            return true
        } catch {
            try? updateManifest(sessionID: sessionID) { manifest in
                manifest.uploadState = .pending
                manifest.lastUploadError = error.localizedDescription
            }
            refresh()
            return false
        }
    }

    private func updateManifest(
        sessionID: String,
        mutate: (inout PhoneCaptureManifest) -> Void
    ) throws {
        let directory = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        let url = directory.appendingPathComponent("capture.json")
        var manifest = try PhoneCaptureWriter.loadManifest(in: directory)
        mutate(&manifest)
        try PhoneCaptureWriter.writeManifest(manifest, to: url)
    }

    private var receiptsURL: URL {
        rootURL.appendingPathComponent("uploaded.json")
    }

    private func uploadedReceipts() throws -> [LocalCaptureRecord] {
        guard fileManager.fileExists(atPath: receiptsURL.path) else { return [] }
        return try JSONDecoder().decode(
            [LocalCaptureRecord].self,
            from: Data(contentsOf: receiptsURL)
        )
    }

    private func persistUploadedReceipt(_ record: LocalCaptureRecord) throws {
        var receipts = try uploadedReceipts()
        var uploaded = record
        uploaded.status = .uploaded
        uploaded.lastError = nil
        receipts.removeAll { $0.sessionID == record.sessionID }
        receipts.append(uploaded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipts).write(to: receiptsURL, options: [.atomic])
    }
}
