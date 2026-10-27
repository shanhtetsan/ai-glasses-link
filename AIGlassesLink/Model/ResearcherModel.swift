import CoreGraphics
import Foundation

struct ResearcherLatencyMetrics: Equatable {
    var last = "--"
    var median = "--"
    var p95 = "--"
    var completedTurnCount = 0
}

@MainActor
final class ResearcherModel: ObservableObject {
    @Published private(set) var cameraImage: CGImage?
    @Published private(set) var partialTranscript = ""
    @Published private(set) var finalTranscript = ""
    @Published private(set) var latencyMetrics = ResearcherLatencyMetrics()
    @Published private(set) var initializationSummary = ""
    @Published private(set) var lastError: String?

    private let client: ResearcherClient
    private let frameProcessor: LatestFrameProcessor<Data>

    init(client: ResearcherClient = ResearcherClient()) {
        self.client = client
        frameProcessor = LatestFrameProcessor(
            label: "com.aiglasses.link.researcher-jpeg",
            process: { try ImageDecoder.decodeJPEG($0) }
        )
        installCallbacks()
    }

    func start() {
        client.start()
    }

    func stop() {
        client.stop()
    }

    func updateBackend(_ baseURL: URL) {
        client.updateBackend(baseURL)
    }

    private func installCallbacks() {
        frameProcessor.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(image):
                    self.cameraImage = image
                case let .failure(error):
                    self.lastError = error.localizedDescription
                }
            }
        }

        client.onJPEG = { [weak self] data in
            self?.frameProcessor.submit(data)
        }
        client.onUIText = { [weak self] text in
            Task { @MainActor in
                self?.handleUIMessage(text)
            }
        }
        client.onMetrics = { [weak self] data in
            Task { @MainActor in
                guard let metrics = Self.decodeMetrics(data) else { return }
                self?.latencyMetrics = metrics
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func handleUIMessage(_ message: String) {
        if message.hasPrefix("PARTIAL:") {
            partialTranscript = String(message.dropFirst("PARTIAL:".count))
        } else if message.hasPrefix("FINAL:") {
            let text = String(message.dropFirst("FINAL:".count))
            if !text.isEmpty {
                finalTranscript += finalTranscript.isEmpty ? text : "\n\(text)"
            }
            partialTranscript = ""
        } else if message.hasPrefix("INIT:") {
            initializationSummary = String(message.dropFirst("INIT:".count))
        }
    }

    private static func decodeMetrics(_ data: Data) -> ResearcherLatencyMetrics? {
        guard let response = try? JSONDecoder().decode(MetricsResponse.self, from: data) else {
            return nil
        }
        return ResearcherLatencyMetrics(
            last: formatMilliseconds(
                response.latestCompletedTurn?.speechEndToFirstI2SMS
            ),
            median: response.display?.median?.text
                ?? formatMilliseconds(response.rollingMedianMS),
            p95: response.display?.p95?.text
                ?? formatMilliseconds(response.p95MS),
            completedTurnCount: response.completedCount ?? 0
        )
    }

    private static func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded())) ms"
    }
}

private struct MetricsResponse: Decodable {
    let latestCompletedTurn: CompletedTurn?
    let rollingMedianMS: Double?
    let p95MS: Double?
    let completedCount: Int?
    let display: MetricsDisplay?

    enum CodingKeys: String, CodingKey {
        case latestCompletedTurn = "latest_completed_turn"
        case rollingMedianMS = "rolling_median_ms"
        case p95MS = "p95_ms"
        case completedCount = "completed_count"
        case display
    }
}

private struct CompletedTurn: Decodable {
    let speechEndToFirstI2SMS: Double?

    enum CodingKeys: String, CodingKey {
        case speechEndToFirstI2SMS = "speech_end_to_first_i2s_ms"
    }
}

private struct MetricsDisplay: Decodable {
    let backendTotal: DisplayMetric?
    let median: DisplayMetric?
    let p95: DisplayMetric?

    enum CodingKeys: String, CodingKey {
        case backendTotal = "backend_total"
        case median
        case p95
    }
}

private struct DisplayMetric: Decodable {
    let text: String?
}
