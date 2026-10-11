import SwiftUI

struct SessionView: View {
    @ObservedObject var model: ConversationModel
    @State private var isPressing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: stateSymbol)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(stateColor)
                        .accessibilityHidden(true)
                    Text(model.state.label)
                        .font(.largeTitle.bold())
                    if let latency = model.lastLatencyMilliseconds {
                        Text("Response audio in \(latency) milliseconds")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Conversation state, \(model.state.label)")

                talkControl

                Text(instructionText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel("Conversation error. \(error)")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Session")
        }
    }

    private var talkControl: some View {
        ZStack {
            Circle().fill(model.state == .disconnected ? Color.gray : stateColor)
            Circle().stroke(.white.opacity(0.8), lineWidth: 5).padding(8)
            VStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 54, weight: .bold))
                Text(model.state == .listening ? "Release" : "Hold to Talk")
                    .font(.title2.bold())
            }
            .foregroundStyle(.white)
        }
        .frame(width: 230, height: 230)
        .scaleEffect(isPressing ? 0.96 : 1)
        .opacity(model.state == .disconnected ? 0.55 : 1)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing, model.state != .disconnected else { return }
                    isPressing = true
                    model.beginPushToTalk()
                }
                .onEnded { _ in
                    guard isPressing else { return }
                    isPressing = false
                    model.endPushToTalk()
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.state == .listening ? "Stop talking" : "Talk")
        .accessibilityValue(model.state.label)
        .accessibilityHint(
            model.state == .listening
                ? "Double tap to finish this utterance."
                : "Double tap to begin talking, then double tap again when finished."
        )
        .accessibilityAction {
            if model.state == .listening {
                isPressing = false
                model.endPushToTalk()
            } else if model.state != .disconnected {
                isPressing = true
                model.beginPushToTalk()
            }
        }
    }

    private var instructionText: String {
        switch model.state {
        case .idle: "Hold the button while speaking."
        case .listening: "Release when you finish speaking."
        case .thinking: "Your request was heard."
        case .speaking: "Hold the button to interrupt."
        case .disconnected: "Reconnecting to the conversation service."
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle: .blue
        case .listening: .green
        case .thinking: .orange
        case .speaking: .purple
        case .disconnected: .red
        }
    }

    private var stateSymbol: String {
        switch model.state {
        case .idle: "checkmark.circle.fill"
        case .listening: "ear.fill"
        case .thinking: "ellipsis.bubble.fill"
        case .speaking: "speaker.wave.3.fill"
        case .disconnected: "wifi.slash"
        }
    }
}
