import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DeviceLinkModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    endpointCard
                    feedCard

                    if let lastError = model.lastError {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Glasses Link")
        }
    }

    private var endpointCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.status.tint)
                    .frame(width: 10, height: 10)
                Text(model.status.title)
                    .font(.headline)
                Spacer()
                Text("Port \(model.configuration.port)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("ESP32 WebSocket URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.endpointURL)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case let .connected(peer) = model.status {
                Label(peer, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.wifiAddress == nil {
                Label("Connect this iPhone and the ESP32 to the same Wi-Fi network.", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var feedCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                cameraView

                thermalInset
                    .frame(width: 104, height: 144)
                    .padding(10)
            }
            // The mounted camera sends 320x240 landscape JPEGs. The backend's
            // canonical RGB view is a 90-degree counter-clockwise rotation,
            // producing a 240x320 portrait frame.
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .background(.black)

            HStack(spacing: 18) {
                metric(title: "CAM", value: model.cameraFPS)
                metric(title: "THERMAL", value: model.thermalFPS)
                Spacer()
                Text("FPS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var cameraView: some View {
        if let image = model.cameraImage {
            GeometryReader { proxy in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // Lay out in the source's landscape bounds, then rotate
                    // only the decoded image at display time. No JPEG re-encode.
                    .frame(width: proxy.size.height, height: proxy.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .clipped()
        } else {
            VStack(spacing: 9) {
                Image(systemName: "camera")
                    .font(.system(size: 30))
                Text("Waiting for camera frames")
                    .font(.subheadline)
            }
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var thermalInset: some View {
        ZStack {
            Color.black

            if let image = model.thermalImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "thermometer.medium")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("THERMAL")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.black.opacity(0.65))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 5)
    }

    private func metric(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(1))))
                .font(.headline.monospacedDigit())
        }
    }
}

private extension ConnectionStatus {
    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .listening:
            "Listening"
        case .connected:
            "ESP32 connected"
        case let .failed(message):
            "Server error: \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .stopped:
            .secondary
        case .listening:
            .orange
        case .connected:
            .green
        case .failed:
            .red
        }
    }
}
