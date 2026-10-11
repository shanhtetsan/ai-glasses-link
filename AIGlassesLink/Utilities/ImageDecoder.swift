import CoreGraphics
import Foundation
import ImageIO

enum ImageDecoderError: LocalizedError {
    case invalidJPEG

    var errorDescription: String? {
        "Camera payload is not a valid JPEG image."
    }
}

enum ImageDecoder {
    static func decodeJPEG(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == "public.jpeg" as CFString,
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw ImageDecoderError.invalidJPEG
        }
        return image
    }
}
