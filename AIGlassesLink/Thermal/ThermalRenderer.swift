import CoreGraphics
import Foundation

struct RGBA: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

enum FalseColorPalette {
    static func color(at normalizedValue: Float) -> RGBA {
        let value = max(0, min(1, normalizedValue))

        // Five-stop blue → cyan → green → yellow → red palette.
        let stops: [RGBA] = [
            RGBA(red: 0, green: 20, blue: 150, alpha: 255),
            RGBA(red: 0, green: 220, blue: 255, alpha: 255),
            RGBA(red: 30, green: 210, blue: 80, alpha: 255),
            RGBA(red: 255, green: 225, blue: 0, alpha: 255),
            RGBA(red: 230, green: 20, blue: 0, alpha: 255)
        ]

        let scaled = value * Float(stops.count - 1)
        let lowerIndex = min(Int(scaled), stops.count - 1)
        let upperIndex = min(lowerIndex + 1, stops.count - 1)
        let fraction = scaled - Float(lowerIndex)
        let lower = stops[lowerIndex]
        let upper = stops[upperIndex]

        func interpolate(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Float(a) + (Float(b) - Float(a)) * fraction).rounded())
        }

        return RGBA(
            red: interpolate(lower.red, upper.red),
            green: interpolate(lower.green, upper.green),
            blue: interpolate(lower.blue, upper.blue),
            alpha: 255
        )
    }
}

enum ThermalRenderer {
    static func render(_ frame: ThermalFrame) throws -> CGImage {
        guard let minimum = frame.values.min(), let maximum = frame.values.max() else {
            throw ThermalError.renderFailed
        }

        let range = maximum - minimum
        var pixels = [UInt8]()
        pixels.reserveCapacity(frame.values.count * 4)

        for value in frame.values {
            let normalized: Float = range > 0 ? (value - minimum) / range : 0.5
            let color = FalseColorPalette.color(at: normalized)
            pixels.append(color.red)
            pixels.append(color.green)
            pixels.append(color.blue)
            pixels.append(color.alpha)
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: ThermalFrame.width,
                  height: ThermalFrame.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: ThermalFrame.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw ThermalError.renderFailed
        }
        return image
    }
}
