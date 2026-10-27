import CoreGraphics
import Foundation

enum RecordSource: String, CaseIterable, Identifiable, Sendable {
    case glasses = "Glasses"
    case phone = "Phone camera"

    var id: Self { self }
}

@MainActor
final class RecordModel: ObservableObject {
    @Published var source: RecordSource = .glasses
    @Published var form = TrialFormData()
    @Published private(set) var isRecording = false
    @Published private(set) var isWorking = false
    @Published private(set) var sessionID: String?
    @Published private(set) var phonePreview: CGImage?
    @Published private(set) var phoneConnected = false
    @Published private(set) var phoneFPS = 0.0
    @Published private(set) var imuHz = 0.0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var framesSaved = 0
    @Published private(set) var framesSent = 0
    @Published private(set) var lastError: String?

    let backendSettings: BackendSettings

    private let apiClient: TrialAPIClient
    private var coordinator: PhoneCaptureCoordinator?
    private var startedAt: Date?
    private var displayTimer: Timer?
    private var frameRate = FrameRateCounter()
    private var imuRate = FrameRateCounter()

    init(
        backendSettings: BackendSettings,
        apiClient: TrialAPIClient = TrialAPIClient()
    ) {
        self.backendSettings = backendSettings
        self.apiClient = apiClient
    }

    var canStart: Bool {
        !form.trial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !form.pid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && backendSettings.normalizedBaseURL != nil
            && !isWorking
    }

    func start() async {
        guard !isRecording, canStart,
              let baseURL = backendSettings.normalizedBaseURL else { return }
        isWorking = true
        lastError = nil
        framesSaved = 0
        framesSent = 0
        phonePreview = nil
        let buttonTime = DispatchTime.now().uptimeNanoseconds
        var openedServerTrial = false
        do {
            let cleanForm = sanitizedForm
            let returnedSessionID = try await apiClient.startTrial(
                cleanForm,
                baseURL: baseURL,
                token: backendSettings.trialToken
            )
            openedServerTrial = true
            sessionID = returnedSessionID

            if source == .phone {
                guard let endpoint = BackendEndpoint.webSocketURL(
                    base: baseURL,
                    path: "/ws/camera_thermal",
                    queryItems: [URLQueryItem(name: "source", value: "phone")]
                ) else {
                    throw TrialAPIError.invalidBackendURL
                }
                let writer = try PhoneCaptureWriter(sessionID: returnedSessionID, trial: cleanForm)
                let coordinator = PhoneCaptureCoordinator(
                    writer: writer,
                    sensorClient: PhoneSensorClient(
                        endpoint: endpoint,
                        token: backendSettings.trialToken
                    )
                )
                installCallbacks(on: coordinator)
                self.coordinator = coordinator
                framesSaved = writer.framesSaved
                framesSent = 0
                coordinator.start(buttonMonotonicNanoseconds: buttonTime)
            }

            startedAt = Date()
            isRecording = true
            startDisplayTimer()
        } catch {
            if openedServerTrial {
                try? await apiClient.endTrial(
                    baseURL: baseURL,
                    token: backendSettings.trialToken
                )
            }
            lastError = error.localizedDescription
        }
        isWorking = false
    }

    func stop() async {
        guard isRecording, !isWorking,
              let baseURL = backendSettings.normalizedBaseURL else { return }
        isWorking = true
        lastError = nil
        coordinator?.stop(buttonMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
        coordinator = nil
        phoneConnected = false
        isRecording = false
        stopDisplayTimer()
        do {
            try await apiClient.endTrial(
                baseURL: baseURL,
                token: backendSettings.trialToken
            )
        } catch {
            lastError = error.localizedDescription
        }
        isWorking = false
    }

    private var sanitizedForm: TrialFormData {
        TrialFormData(
            trial: form.trial.trimmingCharacters(in: .whitespacesAndNewlines),
            pid: form.pid.trimmingCharacters(in: .whitespacesAndNewlines),
            site: form.site.trimmingCharacters(in: .whitespacesAndNewlines),
            cond: form.cond.trimmingCharacters(in: .whitespacesAndNewlines),
            task: form.task.trimmingCharacters(in: .whitespacesAndNewlines),
            successCriterion: form.successCriterion.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func installCallbacks(on coordinator: PhoneCaptureCoordinator) {
        coordinator.onFrameSaved = { [weak self] jpeg, count in
            let decoded = try? ImageDecoder.decodeJPEG(jpeg)
            Task { @MainActor in
                guard let self else { return }
                self.framesSaved = count
                self.frameRate.record()
                if let decoded { self.phonePreview = decoded }
            }
        }
        coordinator.onFrameSent = { [weak self] in
            Task { @MainActor in self?.framesSent += 1 }
        }
        coordinator.onIMUSaved = { [weak self] in
            Task { @MainActor in self?.imuRate.record() }
        }
        coordinator.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.phoneConnected = connected }
        }
        coordinator.onError = { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let uptime = ProcessInfo.processInfo.systemUptime
                self.phoneFPS = self.frameRate.framesPerSecond(at: uptime)
                self.imuHz = self.imuRate.framesPerSecond(at: uptime)
                if let startedAt = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        frameRate.reset()
        imuRate.reset()
        phoneFPS = 0
        imuHz = 0
    }
}
