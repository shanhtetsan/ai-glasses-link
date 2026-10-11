import CoreGraphics
import Foundation

@MainActor
final class ResearcherModel: ObservableObject {
    @Published private(set) var cameraImage: CGImage?
    @Published private(set) var partialTranscript = ""
    @Published private(set) var finalTranscript = ""
    @Published private(set) var latencySummary = "Waiting for metrics"
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
                self?.latencySummary = Self.formatMetrics(data)
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

    private static func formatMetrics(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8) ?? "Metrics unavailable"
        }

        var entries: [String] = []
        flattenMetrics(object, path: [], into: &entries)
        return entries.prefix(8).joined(separator: "\n").isEmpty
            ? "No latency samples"
            : entries.prefix(8).joined(separator: "\n")
    }

    private static func flattenMetrics(_ value: Any, path: [String], into entries: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                flattenMetrics(dictionary[key] as Any, path: path + [key], into: &entries)
            }
        } else if let array = value as? [Any] {
            for (index, item) in array.enumerated() {
                flattenMetrics(item, path: path + [String(index)], into: &entries)
            }
        } else if let number = value as? NSNumber {
            entries.append("\(path.joined(separator: ".")): \(number)")
        } else if let string = value as? String {
            entries.append("\(path.joined(separator: ".")): \(string)")
        }
    }
}
