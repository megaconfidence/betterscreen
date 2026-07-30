import AVFoundation
import AppKit
import Foundation

/// `BetterScreen --snapshot` — captures one frame from every candidate camera and
/// renders it as ASCII, plus writes a PNG.
///
/// Exists because a flat luminance trace has two very different causes that no API
/// can distinguish: the camera genuinely seeing an unchanging scene (obstructed
/// lens, closed clamshell lid, blank wall), versus autoexposure masking real
/// changes. Looking at the actual pixels settles it immediately.
@MainActor
final class CameraSnapshot: NSObject {
    private var pending: [AVCaptureDevice] = []
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private let frameQueue = DispatchQueue(label: "com.betterscreen.snapshot")
    private var captured = false
    private var currentDevice: AVCaptureDevice?

    func run() {
        print("BetterScreen camera snapshot")
        print(String(repeating: "=", count: 64))

        guard AmbientLightSensor.authorizationStatus == .authorized else {
            print("\nCamera not authorized (\(AmbientLightSensor.authorizationStatus.rawValue)).")
            exit(1)
        }

        // Every video device, not just metering candidates: the point is to see what
        // each one actually shows.
        pending = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        guard !pending.isEmpty else {
            print("\nNo cameras found.")
            exit(1)
        }
        next()
    }

    private func next() {
        session?.stopRunning()
        session = nil
        output = nil

        guard !pending.isEmpty else {
            print("\nDone. PNGs written to /tmp/betterscreen-snapshot-*.png")
            exit(0)
        }

        let device = pending.removeFirst()
        currentDevice = device
        captured = false

        print("\n\(String(repeating: "-", count: 64))")
        print("\(device.localizedName)")
        print("  uniqueID: \(device.uniqueID)   exposure lock: \(device.isExposureModeSupported(.locked))")

        let session = AVCaptureSession()
        if session.canSetSessionPreset(.low) { session.sessionPreset = .low }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                print("  Could not open (in use by another app?)")
                next()
                return
            }
            session.addInput(input)
        } catch {
            print("  Could not open: \(error.localizedDescription)")
            next()
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else {
            print("  Could not attach output")
            next()
            return
        }
        session.addOutput(output)

        self.session = session
        self.output = output
        session.startRunning()

        // Let autoexposure settle so the frame reflects the scene rather than the
        // startup transient.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.captured else { return }
            print("  No frame delivered within 2.5s")
            self.next()
        }
    }

    private func handle(_ pixelBuffer: CVPixelBuffer) {
        guard !captured else { return }
        captured = true

        let name = currentDevice?.localizedName ?? "camera"
        if let stats = Self.render(pixelBuffer) {
            print("  \(stats.width)x\(stats.height)  mean linear luminance \(String(format: "%.5f", stats.luminance))")
            print(String(format: "  uniformity: std dev %.5f of mean (%.1f%%)",
                         stats.stdDev, stats.mean > 0 ? stats.stdDev / stats.mean * 100 : 0))
            if stats.mean > 0, stats.stdDev / stats.mean < 0.05 {
                print("  >>> Nearly featureless — the lens is almost certainly obstructed.")
            }
            print("")
            for row in stats.ascii { print("    \(row)") }
            writePNG(pixelBuffer, name: name)
        } else {
            print("  Could not read frame")
        }

        DispatchQueue.main.async { [weak self] in self?.next() }
    }

    private struct Stats {
        let width: Int
        let height: Int
        let luminance: Double
        let mean: Double
        let stdDev: Double
        let ascii: [String]
    }

    /// Downsamples to a character grid and reports spread, which is the signal that
    /// actually matters: an obstructed lens is featureless regardless of brightness.
    private static func render(_ pixelBuffer: CVPixelBuffer, cols: Int = 56, rows: Int = 20) -> Stats? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let ramp = Array(" .:-=+*#%@")
        var lines: [String] = []
        var cellValues: [Double] = []

        for row in 0 ..< rows {
            var line = ""
            for col in 0 ..< cols {
                // Average the block this character represents, rather than point
                // sampling, so noise does not dominate the picture.
                let x0 = col * width / cols, x1 = max(x0 + 1, (col + 1) * width / cols)
                let y0 = row * height / rows, y1 = max(y0 + 1, (row + 1) * height / rows)
                var sum = 0.0
                var count = 0
                for y in y0 ..< y1 {
                    let rowPtr = bytes.advanced(by: y * stride)
                    for x in x0 ..< x1 {
                        let pixel = rowPtr.advanced(by: x * 4)
                        sum += (0.2126 * Double(pixel[2]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[0])) / 255
                        count += 1
                    }
                }
                let value = count > 0 ? sum / Double(count) : 0
                cellValues.append(value)
                line.append(ramp[min(ramp.count - 1, max(0, Int(value * Double(ramp.count))))])
            }
            lines.append(line)
        }

        let mean = cellValues.reduce(0, +) / Double(cellValues.count)
        let variance = cellValues.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(cellValues.count)
        let luma = LumaExtractor.extract(from: pixelBuffer)?.luminance ?? mean

        return Stats(
            width: width, height: height,
            luminance: luma, mean: mean, stdDev: variance.squareRoot(),
            ascii: lines
        )
    }

    private func writePNG(_ pixelBuffer: CVPixelBuffer, name: String) {
        let image = NSImage(size: NSSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        ))
        let rep = NSCIImageRep(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        image.addRepresentation(rep)

        let safe = name.replacingOccurrences(of: " ", with: "-").lowercased()
        let url = URL(fileURLWithPath: "/tmp/betterscreen-snapshot-\(safe).png")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
        print("\n  wrote \(url.path)")
    }
}

extension CameraSnapshot: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor in self.handle(pixelBuffer) }
    }
}
