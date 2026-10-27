import Foundation

/// Writes a frame's sequence number into a JPEG as a COM segment ("seq=<n>")
/// placed right after the SOI marker, so a frame can be matched to frames/<seq>.jpg.
enum JPEGSequenceStamp {
    static let commentPrefix = "seq="

    static func stamp(_ jpeg: Data, sequence: UInt64) throws -> Data {
        guard jpeg.count >= 2,
              jpeg[jpeg.startIndex] == 0xFF,
              jpeg[jpeg.startIndex + 1] == 0xD8 else {
            throw JPEGSequenceStampError.missingSOI
        }
        let text = Data("\(commentPrefix)\(sequence)".utf8)
        // The segment length counts its own two bytes plus the comment text.
        let length = text.count + 2

        var stamped = Data(capacity: jpeg.count + 2 + length)
        stamped.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xFE])
        stamped.append(UInt8(length >> 8))
        stamped.append(UInt8(length & 0xFF))
        stamped.append(text)
        stamped.append(jpeg.dropFirst(2))
        return stamped
    }

    /// Returns the sequence from the first "seq=" COM segment before the image data, if any.
    static func readSequence(from jpeg: Data) -> UInt64? {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            // Start of scan: image data follows, so no more header segments.
            if marker == 0xDA { return nil }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { return nil }
            if marker == 0xFE {
                let body = bytes[(index + 4)..<(index + 2 + length)]
                if let text = String(bytes: body, encoding: .ascii),
                   text.hasPrefix(commentPrefix) {
                    return UInt64(text.dropFirst(commentPrefix.count))
                }
            }
            index += 2 + length
        }
        return nil
    }
}

enum JPEGSequenceStampError: LocalizedError, Equatable {
    case missingSOI

    var errorDescription: String? {
        switch self {
        case .missingSOI: "Camera frame does not start with a JPEG SOI marker."
        }
    }
}
