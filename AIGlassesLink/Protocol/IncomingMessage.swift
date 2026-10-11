import Foundation

enum MessageType: UInt8, Sendable {
    case camera = 0x01
    case thermal = 0x02
    case imu = 0x03
    case status = 0x04
}

enum IncomingMessage: Equatable, Sendable {
    static let thermalPayloadSize = 3_072
    static let imuPayloadSize = 32
    static let statusPayloadSize = 16

    case camera(Data)
    case thermal(Data)
    case imu(Data)
    case status(Data)

    static func parse(_ message: Data) throws -> IncomingMessage {
        guard let discriminator = message.first else {
            throw IncomingMessageError.missingDiscriminator
        }
        guard let type = MessageType(rawValue: discriminator) else {
            throw IncomingMessageError.unknownType(discriminator)
        }

        let payload = Data(message.dropFirst())
        switch type {
        case .camera:
            guard !payload.isEmpty else {
                throw IncomingMessageError.emptyCameraPayload
            }
            return .camera(payload)
        case .thermal:
            try validateSize(payload, expected: thermalPayloadSize, type: type)
            return .thermal(payload)
        case .imu:
            try validateSize(payload, expected: imuPayloadSize, type: type)
            return .imu(payload)
        case .status:
            try validateSize(payload, expected: statusPayloadSize, type: type)
            return .status(payload)
        }
    }

    private static func validateSize(_ payload: Data, expected: Int, type: MessageType) throws {
        guard payload.count == expected else {
            throw IncomingMessageError.invalidPayloadSize(
                type: type,
                expected: expected,
                actual: payload.count
            )
        }
    }
}

enum IncomingMessageError: LocalizedError, Equatable {
    case missingDiscriminator
    case unknownType(UInt8)
    case emptyCameraPayload
    case invalidPayloadSize(type: MessageType, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .missingDiscriminator:
            "Received an empty WebSocket message."
        case let .unknownType(value):
            "Unknown message type 0x\(String(value, radix: 16, uppercase: true))."
        case .emptyCameraPayload:
            "Camera message did not contain a JPEG payload."
        case let .invalidPayloadSize(type, expected, actual):
            "\(type.label) payload was \(actual) bytes; expected \(expected)."
        }
    }
}

private extension MessageType {
    var label: String {
        switch self {
        case .camera: "Camera"
        case .thermal: "Thermal"
        case .imu: "IMU"
        case .status: "Status"
        }
    }
}
