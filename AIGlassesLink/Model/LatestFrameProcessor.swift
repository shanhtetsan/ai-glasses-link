import CoreGraphics
import Foundation

final class LatestFrameProcessor<Input>: @unchecked Sendable {
    typealias Output = CGImage

    var onResult: (@Sendable (Result<Output, Error>) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let process: @Sendable (Input) throws -> Output
    private var pending: Input?
    private var isProcessing = false

    init(label: String, process: @escaping @Sendable (Input) throws -> Output) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.process = process
    }

    func submit(_ item: Input) {
        lock.lock()
        if isProcessing {
            pending = item
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()

        queue.async { [weak self] in
            self?.drain(startingWith: item)
        }
    }

    private func drain(startingWith first: Input) {
        var current: Input? = first

        while let item = current {
            onResult?(Result { try process(item) })

            lock.lock()
            current = pending
            pending = nil
            if current == nil {
                isProcessing = false
            }
            lock.unlock()
        }
    }
}
