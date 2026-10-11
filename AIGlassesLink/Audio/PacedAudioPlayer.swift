import AVFoundation
import Foundation

struct PCM16JitterBuffer {
    private var packets: [Data] = []
    private(set) var byteCount = 0

    var isEmpty: Bool { packets.isEmpty }

    mutating func enqueue(_ packet: Data) {
        guard !packet.isEmpty else { return }
        packets.append(packet)
        byteCount += packet.count
    }

    mutating func dequeue() -> Data? {
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        byteCount -= packet.count
        return packet
    }

    mutating func flush() {
        packets.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    mutating func reset() {
        flush()
    }
}

enum PacedAudioPlayerError: LocalizedError {
    case invalidPCMByteCount(Int)
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case let .invalidPCMByteCount(count):
            "Received an odd PCM16 byte count: \(count)."
        case .bufferCreationFailed:
            "Could not create a PCM playback buffer."
        }
    }
}

final class PacedAudioPlayer: @unchecked Sendable {
    static let inputSampleRate = 8_000.0

    var onDrained: (@Sendable () -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.aiglasses.link.paced-player")
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: inputSampleRate,
        channels: 1,
        interleaved: false
    )!
    private let prebufferBytes: Int

    private var jitterBuffer = PCM16JitterBuffer()
    private var scheduledBufferCount = 0
    private var drainRequested = false
    private var playbackStarted = false
    private var prepared = false
    private var generation = 0

    init(prebufferDuration: TimeInterval = 0.12) {
        prebufferBytes = max(2, Int(Self.inputSampleRate * 2 * prebufferDuration))
    }

    func prepare() throws {
        try queue.sync {
            guard !prepared else {
                if !engine.isRunning {
                    try engine.start()
                }
                return
            }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)
            engine.prepare()
            try engine.start()
            prepared = true
        }
    }

    func beginTurn() {
        queue.async { [weak self] in
            guard let self else { return }
            self.drainRequested = false
            self.playbackStarted = false
        }
    }

    func enqueue(_ pcm16: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard pcm16.count.isMultiple(of: 2) else {
                self.onError?(PacedAudioPlayerError.invalidPCMByteCount(pcm16.count))
                return
            }
            self.jitterBuffer.enqueue(pcm16)
            self.pump()
        }
    }

    func endTurn() {
        queue.async { [weak self] in
            guard let self else { return }
            self.drainRequested = true
            self.pump()
            self.finishIfDrained()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.player.stop()
            self.jitterBuffer.reset()
            self.scheduledBufferCount = 0
            self.drainRequested = false
            self.playbackStarted = false
        }
    }

    func resumeAfterRouteChange() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.engine.isRunning {
                    try self.engine.start()
                }
                self.pump()
            } catch {
                self.onError?(error)
            }
        }
    }

    private func pump() {
        guard prepared else { return }
        guard playbackStarted || drainRequested || jitterBuffer.byteCount >= prebufferBytes else {
            return
        }
        playbackStarted = true

        while let packet = jitterBuffer.dequeue() {
            do {
                let buffer = try makeBuffer(from: packet)
                let scheduledGeneration = generation
                scheduledBufferCount += 1
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async {
                        guard let self, self.generation == scheduledGeneration else { return }
                        self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
                        self.finishIfDrained()
                    }
                }
            } catch {
                onError?(error)
            }
        }

        if !player.isPlaying, scheduledBufferCount > 0 {
            player.play()
        }
    }

    private func finishIfDrained() {
        guard drainRequested, jitterBuffer.isEmpty, scheduledBufferCount == 0 else { return }
        drainRequested = false
        playbackStarted = false
        onDrained?()
    }

    private func makeBuffer(from data: Data) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount),
              let samples = buffer.int16ChannelData?[0] else {
            throw PacedAudioPlayerError.bufferCreationFailed
        }

        buffer.frameLength = frameCount
        _ = data.copyBytes(
            to: UnsafeMutableBufferPointer(start: samples, count: Int(frameCount))
        )
        return buffer
    }
}
