import SwiftUI

struct RecordView: View {
    @ObservedObject var model: RecordModel
    @ObservedObject var researcher: ResearcherModel
    @ObservedObject var device: DeviceLinkModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceAndTrialCard
                    actionButton
                    liveStatusCard
                    cameraCard
                    latencyCard
                    transcriptCard
                    if let error = model.lastError ?? researcher.lastError {
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
            .navigationTitle("Record")
        }
    }

    private var sourceAndTrialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $model.source) {
                ForEach(RecordSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRecording || model.isWorking)

            Group {
                trialField("Trial", text: $model.form.trial)
                trialField("Participant ID", text: $model.form.pid)
                trialField("Site", text: $model.form.site)
                trialField("Condition", text: $model.form.cond)
                trialField("Task", text: $model.form.task)
                trialField("Success criterion", text: $model.form.successCriterion, axis: .vertical)
            }
            .disabled(model.isRecording || model.isWorking)
        }
        .recordCard()
    }

    private func trialField(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {
        TextField(title, text: text, axis: axis)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private var actionButton: some View {
        Button {
            Task {
                if model.isRecording { await model.stop() }
                else { await model.start() }
            }
        } label: {
            HStack {
                if model.isWorking { ProgressView().tint(.white) }
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                Text(model.isRecording ? "Stop" : "Start")
            }
            .font(.title2.bold())
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .blue)
        .disabled(model.isWorking || (!model.isRecording && !model.canStart))
        .accessibilityHint(model.isRecording ? "Stops the trial and local recording." : "Creates the trial before streaming begins.")
    }

    private var liveStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Live status", systemImage: "waveform.path.ecg").font(.headline)
            if let sessionID = model.sessionID {
                Text(sessionID).font(.caption.monospaced()).textSelection(.enabled)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statusTile("FPS", fpsText)
                statusTile("IMU", imuText)
                statusTile("Connected", connectedText)
                statusTile("Elapsed", elapsedText)
                statusTile("Frames local / sent", "\(model.framesSaved) / \(model.framesSent)")
                    .gridCellColumns(2)
            }
        }
        .recordCard()
    }

    private func statusTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live preview", systemImage: "camera.fill").font(.headline)
            ZStack {
                Color.black
                if let image = previewImage {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text("Waiting for \(model.source.rawValue.lowercased())")
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .recordCard()
    }

    private var latencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Latency metrics", systemImage: "timer").font(.headline)
            HStack(spacing: 8) {
                latencyTile("Last", researcher.latencyMetrics.last)
                latencyTile("Median", researcher.latencyMetrics.median)
                latencyTile("P95", researcher.latencyMetrics.p95)
            }
            Text("\(researcher.latencyMetrics.completedTurnCount) turns")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .recordCard()
    }

    private func latencyTile(_ title: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcript", systemImage: "text.bubble.fill").font(.headline)
            Text(transcriptText)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .textSelection(.enabled)
        }
        .recordCard()
    }

    private var previewImage: CGImage? {
        model.source == .phone ? model.phonePreview : researcher.cameraImage
    }

    private var fpsText: String {
        let value = model.source == .phone ? model.phoneFPS : device.cameraFPS
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private var imuText: String {
        let value = model.source == .phone ? model.imuHz : device.imuHz
        return value.formatted(.number.precision(.fractionLength(1))) + " Hz"
    }

    private var connectedText: String {
        if model.source == .phone { return model.phoneConnected ? "Yes" : "No" }
        if case .connected = device.status { return "Yes" }
        return "No"
    }

    private var elapsedText: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var transcriptText: String {
        let parts = [researcher.finalTranscript, researcher.partialTranscript].filter { !$0.isEmpty }
        return parts.isEmpty ? "Waiting for /ws_ui" : parts.joined(separator: "\n")
    }
}

private extension View {
    func recordCard() -> some View {
        padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
