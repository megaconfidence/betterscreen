import CoreVideo
import Foundation

/// Photometric summary of one captured frame.
struct FrameLuma {
    /// Mean relative luminance, 0...1, in a *linear* light domain.
    let luminance: Double
    /// Fraction of sampled pixels at or near full scale. Above ~0.02 the mean is
    /// an underestimate and the reading should not be trusted for gain ratios.
    let clippedHigh: Double
    /// Fraction of sampled pixels at or near zero.
    let clippedLow: Double

    var isClipped: Bool { clippedHigh > 0.02 || clippedLow > 0.50 }
}

/// Computes mean linear luminance from a BGRA pixel buffer.
enum LumaExtractor {
    /// sRGB electro-optical transfer function, tabulated for all 256 byte values.
    ///
    /// Averaging gamma-encoded values would be photometrically wrong: it
    /// systematically overestimates dim scenes, because the encoding devotes far
    /// more code space to the low end. Light metering has to happen in linear light.
    private static let eotf: [Double] = (0 ... 255).map { value in
        let normalized = Double(value) / 255.0
        return normalized <= 0.04045
            ? normalized / 12.92
            : pow((normalized + 0.055) / 1.055, 2.4)
    }

    /// Samples the buffer on a stride and returns its mean linear luminance.
    ///
    /// `targetSamples` caps the work regardless of resolution, so this stays cheap
    /// even if a 4K webcam hands us a full-size frame.
    static func extract(from pixelBuffer: CVPixelBuffer, targetSamples: Int = 8000) -> FrameLuma? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        // Stride so that roughly targetSamples pixels are visited.
        let totalPixels = width * height
        let step = max(1, Int((Double(totalPixels) / Double(targetSamples)).squareRoot()))

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var clippedHigh = 0
        var clippedLow = 0
        var count = 0

        for y in stride(from: 0, to: height, by: step) {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: step) {
                let pixel = row.advanced(by: x * 4)
                // BGRA byte order.
                let blue = Int(pixel[0])
                let green = Int(pixel[1])
                let red = Int(pixel[2])

                // Rec. 709 luminance weights, applied after linearisation.
                let luminance = 0.2126 * eotf[red] + 0.7152 * eotf[green] + 0.0722 * eotf[blue]
                sum += luminance

                let peak = max(red, max(green, blue))
                if peak >= 250 { clippedHigh += 1 }
                if peak <= 3 { clippedLow += 1 }
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return FrameLuma(
            luminance: sum / Double(count),
            clippedHigh: Double(clippedHigh) / Double(count),
            clippedLow: Double(clippedLow) / Double(count)
        )
    }
}
