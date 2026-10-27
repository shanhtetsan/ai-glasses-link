import AVFoundation
import CoreImage
import Foundation

/// Something that produces encoded camera frames for phone capture.
protocol PhoneFrameSource: AnyObject {
    var onJPEG: (@Sendable (Data) -> Void)? { get set }
    var onError: (@Sendable (Error) -> Void)? { get set }
    func start()
    func stop()
}

final class PhoneCameraCapture: NSObject, PhoneFrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onJPEG: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.aiglasses.link.phone-camera-session")
    private let outputQueue = DispatchQueue(label: "com.aiglasses.link.phone-camera-output")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastFrameNanoseconds: UInt64 = 0

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndStart()
                } else {
                    self?.onError?(PhoneCameraError.permissionDenied)
                }
            }
        default:
            onError?(PhoneCameraError.permissionDenied)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.session.inputs.isEmpty {
                    try self.configureSession()
                }
                guard !self.session.isRunning else { return }
                self.lastFrameNanoseconds = 0
                self.session.startRunning()
            } catch {
                self.onError?(error)
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw PhoneCameraError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PhoneCameraError.configurationFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw PhoneCameraError.configurationFailed }
        session.addOutput(output)
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastFrameNanoseconds == 0 || now - lastFrameNanoseconds >= 250_000_000 else { return }
        lastFrameNanoseconds = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let targetWidth = 640.0
        if abs(image.extent.width - targetWidth) > 0.5 {
            let scale = targetWidth / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else {
            onError?(PhoneCameraError.encodingFailed)
            return
        }
        onJPEG?(jpeg)
    }
}

enum PhoneCameraError: LocalizedError {
    case permissionDenied
    case cameraUnavailable
    case configurationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is required for Phone camera mode."
        case .cameraUnavailable: "The back camera is unavailable."
        case .configurationFailed: "The back camera could not be configured."
        case .encodingFailed: "A camera frame could not be encoded as JPEG."
        }
    }
}
