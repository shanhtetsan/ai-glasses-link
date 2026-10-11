import Foundation

struct ServerConfiguration: Sendable {
    static let defaultPort: UInt16 = 8081
    static let cameraThermalPath = "/ws/camera_thermal"

    let port: UInt16
    let path: String
    let maximumMessageSize: Int

    init(
        port: UInt16 = Self.defaultPort,
        path: String = Self.cameraThermalPath,
        maximumMessageSize: Int = 1_048_576
    ) {
        self.port = port
        self.path = path
        self.maximumMessageSize = maximumMessageSize
    }

    static func fromBundle(_ bundle: Bundle = .main) -> ServerConfiguration {
        let configuredPort = bundle.object(forInfoDictionaryKey: "WebSocketPort") as? NSNumber
        let value = configuredPort?.uint16Value ?? defaultPort
        return ServerConfiguration(port: value == 0 ? defaultPort : value)
    }
}
