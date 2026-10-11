import SwiftUI

struct ResearcherView: View {
    @ObservedObject var researcher: ResearcherModel
    @ObservedObject var device: DeviceLinkModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cameraCard
                    transcriptCard
                    latencyCard
                    directLinkCard
                    if let error = researcher.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Researcher")
        }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live glasses camera", systemImage: "camera.fill").font(.headline)
            ZStack {
                Color.black
                if let image = researcher.cameraImage {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text("Waiting for /ws/viewer")
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(
                researcher.cameraImage == nil
                    ? "Live camera unavailable"
                    : "Live camera image from the glasses"
            )
        }
        .researcherCard()
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcript", systemImage: "text.bubble.fill").font(.headline)
            Text(transcriptText)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .textSelection(.enabled)
                .accessibilityLabel("Transcript. \(transcriptText)")
        }
        .researcherCard()
    }

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Latency metrics", systemImage: "timer").font(.headline)
            HStack(spacing: 8) {
                latencyTile(title: "Last", value: researcher.latencyMetrics.last)
                latencyTile(title: "Median", value: researcher.latencyMetrics.median)
                latencyTile(title: "P95", value: researcher.latencyMetrics.p95)
            }
            Text("\(researcher.latencyMetrics.completedTurnCount) turns")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .researcherCard()
    }

    private func latencyTile(title: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) latency, \(value)")
    }

    private var directLinkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Legacy direct-link diagnostic", systemImage: "network").font(.headline)
            Text(device.endpointURL).font(.caption.monospaced()).textSelection(.enabled)
            Text(directLinkStatus).font(.caption).foregroundStyle(.secondary)
        }
        .researcherCard()
    }

    private var transcriptText: String {
        let parts = [researcher.finalTranscript, researcher.partialTranscript].filter { !$0.isEmpty }
        return parts.isEmpty ? "Waiting for /ws_ui" : parts.joined(separator: "\n")
    }

    private var directLinkStatus: String {
        switch device.status {
        case .stopped: "Stopped"
        case .listening: "Listening"
        case let .connected(peer): "Connected: \(peer)"
        case let .failed(message): "Error: \(message)"
        }
    }
}

private extension View {
    func researcherCard() -> some View {
        padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
