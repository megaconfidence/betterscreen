import AVFoundation
import CoreGraphics
import Foundation

/// `BetterScreen --diagnose` — prints what the app can see and control, then exits.
///
/// Safe to run straight from a terminal: nothing here touches the camera, so it
/// avoids the TCC attribution problem where a directly-executed binary has its
/// permission grant recorded against the terminal rather than the app.
enum Diagnostics {
    static func run() {
        print("BetterScreen diagnostics")
        print(String(repeating: "=", count: 64))

        printEnvironment()
        printDisplays()
        printAVServices()
        printCameras()
    }

    private static func printEnvironment() {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        print("\nEnvironment")
        print("  macOS:               \(version)")
        print("  DisplayServices SPI: \(DisplayServicesSPI.isAvailable ? "available" : "UNAVAILABLE")")
    }

    private static func printDisplays() {
        print("\nDisplays")
        let displays = DisplayInfo.onlineDisplays()
        if displays.isEmpty { print("  (none)") }

        for id in displays {
            let name = DisplayInfo.productName(for: id) ?? "Unknown"
            let kind = ManagedDisplay.classify(id)
            print("\n  [\(id)] \(name)")
            print("    kind:              \(kind.rawValue)")
            print("    builtin:           \(CGDisplayIsBuiltin(id) != 0)")
            print("    asleep:            \(CGDisplayIsAsleep(id) != 0)")
            print("    vendor/model:      \(CGDisplayVendorNumber(id)) / \(CGDisplayModelNumber(id))")
            print("    serial:            \(CGDisplaySerialNumber(id))")
            print("    persistent key:    \(DisplayInfo.persistentKey(for: id))")
            print("    HDR active (3rd):  \(DisplayInfo.isThirdPartyHDRActive(id))")
            print("    DS canChange:      \(DisplayServicesSPI.canChangeBrightness(id))")
            print("    DS isSmartDisplay: \(DisplayServicesSPI.isSmartDisplay(id))")
            if let brightness = DisplayServicesSPI.brightness(for: id) {
                print("    DS brightness:     \(String(format: "%.3f", brightness))")
            } else {
                print("    DS brightness:     unsupported")
            }
            print("    has ALC:           \(DisplayServicesSPI.hasAmbientLightCompensation(id))")
            if let alc = DisplayServicesSPI.ambientLightCompensationEnabled(id) {
                print("    ALC enabled:       \(alc)")
            }
            print("    IODisplayLocation: \(DisplayInfo.ioDisplayLocation(for: id) ?? "nil")")
        }
    }

    private static func printAVServices() {
        print("\nIOAVService ports (DDC/CI)")
        let ports = AVServiceLocator.enumeratePorts()
        if ports.isEmpty { print("  (none)") }

        for port in ports {
            print("\n  port #\(port.index)")
            print("    framebuffer:  \(port.framebufferPath)")
            print("    AV service:   \(port.service == nil ? "none (built-in or non-external)" : "present")")
            print("    product:      \(port.productName ?? "nil")")
            print("    vendor/model: \(port.vendorID.map(String.init) ?? "nil") / \(port.productID.map(String.init) ?? "nil")")
            print("    serial:       \(port.serialNumber.map(String.init) ?? "nil")")
            print("    EDID UUID:    \(port.edidUUID ?? "nil")")
        }

        // Exercise the real matching path, then attempt one live DDC read so the
        // whole stack is proven end to end rather than just the enumeration.
        let ddcDisplays = DisplayInfo.onlineDisplays().filter { ManagedDisplay.classify($0) == .ddc }
        guard !ddcDisplays.isEmpty else { return }

        print("\nDDC matching and live read")
        let matched = AVServiceLocator.match(displays: ddcDisplays)
        for id in ddcDisplays {
            let name = DisplayInfo.productName(for: id) ?? "Unknown"
            guard let service = matched[id] else {
                print("  [\(id)] \(name): NO MATCH — DDC unavailable")
                continue
            }
            if let reply = DDCTransport.shared.getVCP(.brightness, service: service, displayID: id) {
                let percent = Double(reply.current) / Double(reply.max) * 100
                print("  [\(id)] \(name): brightness \(reply.current)/\(reply.max) (\(String(format: "%.0f%%", percent)))")
            } else {
                // Reads legitimately fail ~12% of the time even with retries; a
                // failure here does not imply writes will fail.
                print("  [\(id)] \(name): matched, but VCP read failed (reads are unreliable; writes usually still work)")
            }
        }
    }

    /// `--test-ddc` — sweeps brightness on every controllable display and reads each
    /// value back, then restores the original.
    ///
    /// Isolates display control from the camera entirely, and needs no permissions,
    /// so it is safe to run straight from a shell.
    /// `--set-brightness <0-100>` — sets every controllable display to a known
    /// level. Needed to establish a repeatable baseline before a test run, since the
    /// app anchors its curve to whatever brightness it finds at launch.
    static func setBrightness(percent: Double) {
        let clamped = min(max(percent, 0), 100)
        print(String(format: "Setting all controllable displays to %.0f%%", clamped))

        let displays = DisplayInfo.onlineDisplays().compactMap { id -> ManagedDisplay? in
            let kind = ManagedDisplay.classify(id)
            let services = kind == .ddc ? AVServiceLocator.match(displays: [id]) : [:]
            let display = ManagedDisplay(displayID: id, kind: kind, avService: services[id])
            return display.isControllable ? display : nil
        }

        guard !displays.isEmpty else {
            print("No controllable displays found.")
            return
        }

        for display in displays {
            let ok = display.setBrightness(Float(clamped / 100))
            print("  \(display.name) [\(display.kind.displayName)]: \(ok ? "ok" : "FAILED")")
        }
    }

    static func testDisplayControl() {
        print("BetterScreen display control test")
        print(String(repeating: "=", count: 64))

        let displays = DisplayInfo.onlineDisplays().compactMap { id -> ManagedDisplay? in
            let kind = ManagedDisplay.classify(id)
            let services = kind == .ddc ? AVServiceLocator.match(displays: [id]) : [:]
            let display = ManagedDisplay(displayID: id, kind: kind, avService: services[id])
            return display.isControllable ? display : nil
        }

        guard !displays.isEmpty else {
            print("\nNo controllable displays found.")
            return
        }

        for display in displays {
            print("\n\(display.name) [\(display.kind.displayName)]")

            guard let original = display.readBrightness() else {
                print("  Could not read current brightness; skipping to avoid leaving it somewhere unexpected.")
                continue
            }
            print(String(format: "  original: %.0f%%", original * 100))

            var successes = 0
            let targets: [Float] = [0.20, 0.50, 0.80, 1.00, 0.50]

            for target in targets {
                let wrote = display.setBrightness(target)
                // Readback is best-effort: DDC reads fail ~12% of the time even with
                // retries, so a failed read here does not mean the write failed.
                let readBack = display.readBrightness()
                let matched = readBack.map { abs($0 - target) <= 0.03 } ?? false
                if matched { successes += 1 }

                let readText = readBack.map { String(format: "%.0f%%", $0 * 100) } ?? "read failed"
                print(String(
                    format: "  set %3.0f%% -> write %@, readback %@ %@",
                    target * 100,
                    wrote ? "ok" : "FAILED",
                    readText,
                    matched ? "MATCH" : ""
                ))
            }

            print("  \(successes)/\(targets.count) verified by readback")
            if successes == 0 {
                print("  NOTE: no readback matched. Either reads are failing (common) or")
                print("        this panel ignores DDC. Watch the screen during the sweep.")
            }

            display.setBrightness(original)
            print(String(format: "  restored to %.0f%%", original * 100))
        }
    }

    private static func printCameras() {
        print("\nCameras")
        print("  authorization: \(describeAuthStatus(AmbientLightSensor.authorizationStatus))")
        let cameras = AmbientLightSensor.availableCameras()
        if cameras.isEmpty { print("  (none)") }
        for camera in cameras {
            print("\n  \(camera.localizedName)")
            print("    uniqueID:     \(camera.uniqueID)")
            print("    type:         \(camera.deviceType.rawValue)")
            print("    connected:    \(camera.isConnected)")
            print("    in use:       \(camera.isInUseByAnotherApplication)")
            // Exposure lock is what makes wide-range metering possible; without it
            // the sensor is limited to cold-frame sampling.
            print("    lock exposure:\(camera.isExposureModeSupported(.locked))")
            print("    auto exposure:\(camera.isExposureModeSupported(.continuousAutoExposure))")
        }
    }

    private static func describeAuthStatus(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown"
        }
    }
}
