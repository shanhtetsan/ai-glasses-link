import Combine
import Foundation

struct TrialListRow: Identifiable, Equatable {
    let sessionID: String
    let trial: String?
    let participant: String?
    let site: String?
    let condition: String?
    let sensorSource: String?
    let serverStatus: String?
    let date: String?
    let turnCount: Int?
    let phoneCaptureStatus: PhoneCaptureUploadState?
    let phoneCaptureError: String?
    let isAvailableOnServer: Bool

    var id: String { sessionID }
}

@MainActor
final class TrialsModel: ObservableObject {
    @Published private(set) var rows: [TrialListRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    let backendSettings: BackendSettings

    private let client: TrialsClient
    private let uploadManager: PhoneCaptureUploadManager
    private var serverTrials: [ServerTrial] = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        backendSettings: BackendSettings,
        uploadManager: PhoneCaptureUploadManager,
        client: TrialsClient = TrialsClient()
    ) {
        self.backendSettings = backendSettings
        self.uploadManager = uploadManager
        self.client = client
        uploadManager.$captures
            .sink { [weak self] _ in self?.mergeRows() }
            .store(in: &cancellables)
        mergeRows()
    }

    func refresh() async {
        uploadManager.refresh()
        guard let baseURL = backendSettings.normalizedBaseURL else {
            lastError = TrialAPIError.invalidBackendURL.localizedDescription
            mergeRows()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            serverTrials = try await client.fetchTrials(
                baseURL: baseURL,
                token: backendSettings.trialToken
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        mergeRows()
    }

    func detailURL(for row: TrialListRow) -> URL? {
        guard row.isAvailableOnServer,
              let baseURL = backendSettings.normalizedBaseURL else { return nil }
        return BackendEndpoint.httpURL(
            base: baseURL,
            path: "/trials/\(row.sessionID)"
        )
    }

    private func mergeRows() {
        let local = Dictionary(
            uniqueKeysWithValues: uploadManager.captures.map { ($0.sessionID, $0) }
        )
        var merged = serverTrials.map { trial in
            TrialListRow(
                sessionID: trial.id,
                trial: trial.trial,
                participant: trial.participant,
                site: trial.site,
                condition: trial.condition,
                sensorSource: trial.sensorSource,
                serverStatus: trial.status,
                date: trial.date,
                turnCount: trial.turnCount,
                phoneCaptureStatus: local[trial.id]?.status,
                phoneCaptureError: local[trial.id]?.lastError,
                isAvailableOnServer: true
            )
        }
        let serverIDs = Set(serverTrials.map(\.id))
        for capture in uploadManager.captures where !serverIDs.contains(capture.sessionID) {
            merged.append(TrialListRow(
                sessionID: capture.sessionID,
                trial: capture.trial.trial,
                participant: capture.trial.pid,
                site: capture.trial.site,
                condition: capture.trial.cond,
                sensorSource: "phone",
                serverStatus: nil,
                date: capture.createdAt,
                turnCount: nil,
                phoneCaptureStatus: capture.status,
                phoneCaptureError: capture.lastError,
                isAvailableOnServer: false
            ))
        }
        rows = merged.sorted { ($0.date ?? "") > ($1.date ?? "") }
    }
}
