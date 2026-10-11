import UIKit

@MainActor
protocol HapticProviding: AnyObject {
    func play(for state: ConversationState)
}

@MainActor
final class HapticFeedback: HapticProviding {
    private var generation = 0

    func play(for state: ConversationState) {
        generation += 1
        let currentGeneration = generation

        switch state {
        case .idle:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .listening:
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred(intensity: 1)
        case .thinking:
            pulse(style: .rigid, intensity: 0.65)
            schedule(after: 0.14, generation: currentGeneration) { [weak self] in
                self?.pulse(style: .rigid, intensity: 0.65)
            }
        case .speaking:
            pulse(style: .soft, intensity: 0.8)
            schedule(after: 0.10, generation: currentGeneration) { [weak self] in
                self?.pulse(style: .soft, intensity: 0.8)
            }
            schedule(after: 0.20, generation: currentGeneration) { [weak self] in
                self?.pulse(style: .soft, intensity: 0.8)
            }
        case .disconnected:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        }
    }

    private func pulse(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }

    private func schedule(
        after delay: TimeInterval,
        generation expectedGeneration: Int,
        action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            action()
        }
    }
}
