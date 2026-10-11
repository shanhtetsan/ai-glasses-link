import Foundation

struct FrameRateCounter {
    private var timestamps: [TimeInterval] = []
    private let window: TimeInterval

    init(window: TimeInterval = 1.0) {
        self.window = window
    }

    mutating func record(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        timestamps.append(timestamp)
        prune(at: timestamp)
    }

    mutating func framesPerSecond(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        prune(at: timestamp)
        return Double(timestamps.count) / window
    }

    mutating func reset() {
        timestamps.removeAll(keepingCapacity: true)
    }

    private mutating func prune(at timestamp: TimeInterval) {
        let cutoff = timestamp - window
        timestamps.removeAll { $0 <= cutoff }
    }
}
