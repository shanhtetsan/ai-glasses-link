import CoreGraphics
import Foundation
import Network

@MainActor
final class DeviceLinkModel: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .stopped
    @Published private(set) var wifiAddress: String?
    @Published private(set) var cameraImage: CGImage?
    @Published private(set) var thermalImage: CGImage?
    @Published private(set) var cameraFPS = 0.0
    @Published private(set) var thermalFPS = 0.0
    @Published private(set) var imuHz = 0.0
    @Published private(set) var lastError: String?

    let configuration: ServerConfiguration

    var endpointURL: String {
        let host = wifiAddress ?? "<iPhone Wi-Fi IP>"
        return "ws://\(host):\(configuration.port)\(configuration.path)"
    }

    private let server: WebSocketServer
    private let cameraProcessor: LatestFrameProcessor<Data>
    private let thermalProcessor: LatestFrameProcessor<Data>
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.aiglasses.link.path-monitor")
    private var cameraRate = FrameRateCounter()
    private var thermalRate = FrameRateCounter()
    private var imuRate = FrameRateCounter()
    private var fpsTimer: Timer?
    private var isRunning = false

    init(configuration: ServerConfiguration = .fromBundle()) {
        self.configuration = configuration
        self.server = WebSocketServer(configuration: configuration)

        self.cameraProcessor = LatestFrameProcessor(
            label: "com.aiglasses.link.camera-decode",
            process: { payload in
                try ImageDecoder.decodeJPEG(payload)
            }
        )

        self.thermalProcessor = LatestFrameProcessor(
            label: "com.aiglasses.link.thermal-render",
            process: { payload in
                let frame = try ThermalCanonicalizer.decodeAndCanonicalize(payload)
                return try ThermalRenderer.render(frame)
            }
        )

        cameraProcessor.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(image):
                    self.cameraImage = image
                    self.cameraRate.record()
                    self.lastError = nil
                case let .failure(error):
                    self.lastError = error.localizedDescription
                }
            }
        }

        thermalProcessor.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(image):
                    self.thermalImage = image
                    self.thermalRate.record()
                    self.lastError = nil
                case let .failure(error):
                    self.lastError = error.localizedDescription
                }
            }
        }

        server.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.status = status
            }
        }

        server.onBinaryMessage = { [weak self] data in
            self?.handle(data)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshWiFiAddress()
        startPathMonitoring()
        server.start()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFrameRates()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        server.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        cameraRate.reset()
        thermalRate.reset()
        imuRate.reset()
        cameraFPS = 0
        thermalFPS = 0
        imuHz = 0
    }

    private nonisolated func handle(_ data: Data) {
        do {
            switch try IncomingMessage.parse(data) {
            case let .camera(payload):
                cameraProcessor.submit(payload)
            case let .thermal(payload):
                thermalProcessor.submit(payload)
            case .imu:
                Task { @MainActor [weak self] in self?.imuRate.record() }
            case .status:
                break
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func refreshFrameRates() {
        let now = ProcessInfo.processInfo.systemUptime
        cameraFPS = cameraRate.framesPerSecond(at: now)
        thermalFPS = thermalRate.framesPerSecond(at: now)
        imuHz = imuRate.framesPerSecond(at: now)
    }

    private func startPathMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refreshWiFiAddress()
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func refreshWiFiAddress() {
        wifiAddress = WiFiAddressProvider.ipv4Address()
    }
}
