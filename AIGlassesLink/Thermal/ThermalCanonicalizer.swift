import Foundation

struct ThermalFrame: Equatable, Sendable {
    static let width = 24
    static let height = 32

    let values: [Float]

    init(values: [Float]) throws {
        guard values.count == Self.width * Self.height else {
            throw ThermalError.invalidValueCount(values.count)
        }
        self.values = values
    }

    subscript(row: Int, column: Int) -> Float {
        values[row * Self.width + column]
    }
}

enum ThermalError: LocalizedError, Equatable {
    case invalidPayloadSize(Int)
    case nonFiniteValue(index: Int)
    case invalidValueCount(Int)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case let .invalidPayloadSize(size):
            "Thermal payload was \(size) bytes; expected 3072."
        case let .nonFiniteValue(index):
            "Thermal payload contains a non-finite value at index \(index)."
        case let .invalidValueCount(count):
            "Thermal frame contained \(count) values; expected 768."
        case .renderFailed:
            "Could not render the thermal frame."
        }
    }
}

enum ThermalCanonicalizer {
    static let nativeRows = 24
    static let nativeColumns = 32
    static let payloadSize = nativeRows * nativeColumns * MemoryLayout<Float>.size

    /// Decodes the native 24x32 row-major grid, rotates it 90 degrees
    /// counter-clockwise, then flips the rotated grid horizontally.
    static func decodeAndCanonicalize(_ payload: Data) throws -> ThermalFrame {
        guard payload.count == payloadSize else {
            throw ThermalError.invalidPayloadSize(payload.count)
        }

        let bytes = [UInt8](payload)
        var native = [Float]()
        native.reserveCapacity(nativeRows * nativeColumns)

        for index in 0..<(nativeRows * nativeColumns) {
            let offset = index * 4
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            let value = Float(bitPattern: bits)
            guard value.isFinite else {
                throw ThermalError.nonFiniteValue(index: index)
            }
            native.append(value)
        }

        var canonical = [Float](
            repeating: 0,
            count: ThermalFrame.width * ThermalFrame.height
        )

        for sourceRow in 0..<nativeRows {
            for sourceColumn in 0..<nativeColumns {
                // CCW: (r, c) -> (31-c, r). Horizontal flip of the resulting
                // 32x24 grid: (r, c) -> (r, 23-c).
                let destinationRow = nativeColumns - 1 - sourceColumn
                let destinationColumn = nativeRows - 1 - sourceRow
                canonical[destinationRow * ThermalFrame.width + destinationColumn] =
                    native[sourceRow * nativeColumns + sourceColumn]
            }
        }

        return try ThermalFrame(values: canonical)
    }
}
