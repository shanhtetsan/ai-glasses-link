import AVFoundation
import Foundation

struct PCMChunker {
    let chunkSize: Int
    private(set) var pending = Data()

    init(chunkSize: Int = 640) {
        precondition(chunkSize > 0)
        self.chunkSize = chunkSize
    }

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var chunks: [Data] = []

        while pending.count >= chunkSize {
            chunks.append(Data(pending.prefix(chunkSize)))
            pending.removeFirst(chunkSize)
        }
        return chunks
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case formatUnavailable
    case converterUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            "The microphone input format is unavailable."
        case .converterUnavailable:
            "The microphone audio converter could not be created."
        case .conversionFailed:
            "Microphone audio could not be converted to 16 kHz PCM."
        }
    }
}

final class MicrophoneCapture: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let chunkSize = 640

    var onChunk: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(
        label: "com.aiglasses.link.microphone-conversion",
        qos: .userInteractive
    )
    private var converter: AVAudioConverter?
    private var chunker = PCMChunker(chunkSize: chunkSize)
    private var running = false

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneCaptureError.formatUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.converterUnavailable
        }

        self.converter = converter
        chunker.reset()
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.convert(buffer, using: converter, outputFormat: outputFormat)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw error
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        running = false
        processingQueue.async { [weak self] in
            self?.chunker.reset()
        }
    }

    private func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) {
        let ratio = Self.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            onError?(MicrophoneCaptureError.conversionFailed)
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || conversionError != nil {
            onError?(conversionError ?? MicrophoneCaptureError.conversionFailed)
            return
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return }
        let converted = Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
        for chunk in chunker.append(converted) {
            onChunk?(chunk)
        }
    }
}
