import SwiftUI

struct SessionView: View {
    @ObservedObject var model: ConversationModel

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
                Text(model.state == .listening ? "Tap to Stop" : "Tap to Talk")
                    .font(.title2.bold())
            }
            .foregroundStyle(.white)
        }
        .frame(width: 230, height: 230)
        .opacity(model.state == .disconnected ? 0.55 : 1)
        .contentShape(Circle())
        .onTapGesture(perform: toggleTalking)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(model.state.label)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction {
            toggleTalking()
        }
    }

    private var instructionText: String {
        switch model.state {
        case .idle: "Tap once to start, tap again to stop."
        case .listening: "Tap again when you finish speaking."
        case .thinking: "Your request was heard."
        case .speaking: "Tap to interrupt."
        case .disconnected: "Reconnecting to the conversation service."
        }
    }

    private func toggleTalking() {
        guard model.state != .disconnected else { return }
        if model.state == .listening {
            model.endPushToTalk()
        } else {
            model.beginPushToTalk()
        }
    }

    private var accessibilityLabel: String {
        switch model.state {
        case .listening: "Stop talking"
        case .speaking: "Interrupt and talk"
        default: "Talk"
        }
    }

    private var accessibilityHint: String {
        switch model.state {
        case .listening: "Double tap to finish this utterance."
        case .speaking: "Double tap to interrupt the response and begin talking."
        default: "Double tap to begin talking, then double tap again when finished."
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
