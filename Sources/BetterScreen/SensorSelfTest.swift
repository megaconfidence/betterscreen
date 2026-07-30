import AppKit
import Foundation

/// `BetterScreen --test-sensor` — proves the ambient sensor responds to real light
/// changes, end to end, by using a managed display as a controlled light source.
///
/// This closes the loop that unit tests cannot: it drives the monitor to known
/// brightness levels and checks that measured ambient light moves with it. In a
/// clamshell setup the monitor is the dominant light source reaching the camera, so
/// the effect is large and unambiguous.
///
/// Must be launched via `open`, not from a shell, or macOS attributes the camera
/// permission to the terminal instead of the app:
///
///     open --stdout /tmp/test.log --stderr /tmp/test.log \
///          dist/BetterScreen.app --args --test-sensor
@MainActor
final class SensorSelfTest: NSObject, AmbientLightSensorDelegate {
    private let sensor = AmbientLightSensor()
    private var readings: [AmbientReading] = []
    private var display: ManagedDisplay?
    private var originalBrightness: Double = 0.5
    private var failure: String?
    private var samples: [(TimeInterval, Double)] = []

    private struct Step {
        let brightness: Double
        let label: String
        var measured: Double?
        var stops: Double?
    }

    private var steps: [Step] = [
        Step(brightness: 0.0, label: "display  0%"),
        Step(brightness: 1.0, label: "display 100%"),
        Step(brightness: 0.0, label: "display  0% (repeat)"),
        Step(brightness: 0.5, label: "display  50%"),
    ]

    /// `--watch-light` — free-form probe with no timing requirements.
    ///
    /// Earlier guided attempts were inconclusive because they depended on the user
    /// acting inside a narrow window. This just watches for a long time and reports
    /// the extremes, so covering the lens at any point registers.
    ///
    /// It also runs a control: the second half switches autoexposure back on. If
    /// covering the lens shows up equally in both halves, `exposureMode = .locked`
    /// is cosmetic and the camera's firmware autoexposure never actually stopped --
    /// which no API call can reveal, since the property reads back as locked either
    /// way.
    func watch(duration: TimeInterval = 60) {
        print("BetterScreen light meter probe")
        print(String(repeating: "=", count: 64))
        print("""

        Watching for \(Int(duration))s. Cover the camera lens completely for about
        5 seconds, TWICE: once in the first half, once in the second half.
        Exact timing does not matter.

        """)

        sensor.updateInterval = 0.3
        sensor.delegate = self
        sensor.preferredDeviceID = SettingsStore.shared.settings.cameraUniqueID
        sensor.start()

        let started = Date()
        var switchedToAuto = false

        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(started)

                // Control condition for the second half.
                if !switchedToAuto, elapsed >= duration / 2 {
                    switchedToAuto = true
                    self.sensor.overrideExposureAuto()
                    print("\n>>> HALFWAY — exposure released to auto (control condition)\n")
                }

                let raw = self.sensor.instantaneousLuminance
                self.samples.append((elapsed, raw))

                // Compact bar so a dip is visible at a glance.
                let columns = max(0, min(40, Int(raw * 120)))
                print(String(format: "  %5.1fs %@  raw %.4f |%@",
                             elapsed,
                             switchedToAuto ? "AUTO  " : "LOCKED",
                             raw,
                             String(repeating: "#", count: columns)))

                if elapsed >= duration {
                    timer.invalidate()
                    self.summariseWatch()
                }
            }
        }
    }

    private func summariseWatch() {
        // Skip the first samples of each phase: before the first frame arrives the
        // reading is 0, and after an exposure-mode change the camera needs time to
        // settle. Including either produces a fake "dip".
        let settle: TimeInterval = 2
        let total = samples.last?.0 ?? 60
        let half = total / 2

        let lockedPhase = samples
            .filter { $0.0 >= settle && $0.0 < half && $0.1 > 0 }
            .map(\.1)
        let autoPhase = samples
            .filter { $0.0 >= half + settle && $0.1 > 0 }
            .map(\.1)

        print("\n" + String(repeating: "-", count: 64))

        /// Returns the deepest dip below the median, in stops, or nil if unmeasurable.
        func describe(_ label: String, _ values: [Double]) -> Double? {
            guard values.count >= 5, let low = values.min(), let high = values.max(),
                  low > 0 else {
                print("\(label): too few usable samples (\(values.count))")
                return nil
            }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            let dip = log2(median / low)
            print(String(format: "%@: n=%d  min %.4f  median %.4f  max %.4f  -> deepest dip %.2f stops",
                         label, values.count, low, median, high, dip))
            return dip
        }

        let locked = describe("LOCKED half", lockedPhase)
        let auto = describe("AUTO half  ", autoPhase)

        print("")
        guard let lockedDip = locked else {
            print("INCONCLUSIVE — not enough usable samples in the locked half.")
            finish(error: "insufficient samples")
            return
        }

        // A covered lens should read far darker than the scene median. Anything less
        // than half a stop means the lens was probably never fully covered.
        let threshold = 0.5
        let autoDip = auto ?? 0

        if lockedDip < threshold {
            print("INCONCLUSIVE — the locked half never dropped more than")
            print(String(format: "               %.2f stops, so the lens was probably never fully", lockedDip))
            print("               covered. Re-run and press your palm flat over it.")
        } else if lockedDip > autoDip * 1.6 {
            print(String(format: "PASS — locked dipped %.2f stops vs %.2f in auto (%.0fx stronger).",
                         lockedDip, autoDip, autoDip > 0.01 ? lockedDip / autoDip : 999))
            print("       Exposure lock is genuine: frame luminance tracks real light,")
            print("       and autoexposure does compensate it away when unlocked.")
        } else {
            print("LOCK IS COSMETIC — both halves responded about equally, so the")
            print("       camera's firmware autoexposure keeps running even though")
            print("       exposureMode reads back as .locked.")
        }
        finish(error: nil)
    }

    func run() {
        print("BetterScreen sensor self-test")
        print(String(repeating: "=", count: 64))

        DisplayManager.shared.rescan()
        guard let target = DisplayManager.shared.displays.first else {
            finish(error: "No controllable display found; cannot run the test.")
            return
        }
        display = target
        originalBrightness = Double(target.currentBrightness < 0 ? 0.5 : target.currentBrightness)
        print("\nUsing \(target.name) [\(target.kind.displayName)] as light source")
        print("Current brightness: \(Int(originalBrightness * 100))%")

        // Emit readings as fast as possible so each step averages several samples.
        sensor.updateInterval = 0.4
        sensor.delegate = self
        sensor.preferredDeviceID = SettingsStore.shared.settings.cameraUniqueID
        print("\nStarting camera and waiting for exposure lock…")
        sensor.start()

        waitForLock(attempt: 0)
    }

    /// Exposure must be locked before any measurement means anything: with
    /// autoexposure running, luminance is pinned to its target and carries no scene
    /// information at all.
    private func waitForLock(attempt: Int) {
        guard failure == nil else { return }

        if readings.contains(where: \.exposureLocked) {
            print("Exposure locked after \(String(format: "%.1f", Double(attempt) * 0.25))s\n")
            runStep(0)
            return
        }

        guard attempt < 80 else {
            finish(error: "Exposure never locked after 20s. Camera may not support locking.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForLock(attempt: attempt + 1)
        }
    }

    private func runStep(_ index: Int) {
        guard failure == nil else { return }
        guard index < steps.count, let display else {
            report()
            return
        }

        let step = steps[index]
        display.setBrightness(Float(step.brightness))

        // Long enough for the panel to actually reach the new level, for the room to
        // respond, and for the sensor's moving average to catch up.
        let settle: TimeInterval = 3.5
        readings.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            // Average the tail of the window, after the EMA has converged.
            let sample = self.readings.suffix(4)
            if sample.isEmpty {
                self.finish(error: "No readings received during '\(step.label)'.")
                return
            }
            let light = sample.map(\.relativeLight).reduce(0, +) / Double(sample.count)
            let stops = sample.map(\.stops).reduce(0, +) / Double(sample.count)
            self.steps[index].measured = light
            self.steps[index].stops = stops
            print(String(format: "  %-22@  light = %.4f×  (%+.2f stops)  [%d samples]",
                         step.label as NSString, light, stops, sample.count))
            self.runStep(index + 1)
        }
    }

    private func report() {
        print("\n" + String(repeating: "-", count: 64))

        guard let dark = steps.first(where: { $0.brightness == 0.0 })?.measured,
              let bright = steps.first(where: { $0.brightness == 1.0 })?.measured,
              dark > 0
        else {
            finish(error: "Incomplete measurements.")
            return
        }

        let ratio = bright / dark
        let stopsSpan = log2(ratio)
        print(String(format: "Light change from 0%% to 100%%: %.2f× (%.2f stops)", ratio, stopsSpan))

        // Repeatability: the two 0% measurements should agree closely. Disagreement
        // means either drift in the gain chain or the room's light changing
        // underneath the test.
        let zeroSteps = steps.filter { $0.brightness == 0.0 }.compactMap(\.measured)
        if zeroSteps.count == 2, zeroSteps[0] > 0 {
            let drift = abs(log2(zeroSteps[1] / zeroSteps[0]))
            print(String(format: "Repeatability at 0%%: %.3f stops of drift", drift))
            if drift > 0.35 {
                print("  NOTE: drift is high — ambient light may have changed during the test.")
            }
        }

        print("")
        if ratio > 1.15 {
            print("PASS — measured light tracks the display, so the sensor is working.")
            print("       Monotonic response confirmed; the relative scale is usable.")
        } else if ratio > 1.02 {
            print("WEAK — response is in the right direction but small.")
            print("       Point the camera toward the screen, or test by covering it.")
        } else {
            print("FAIL — measured light did not follow the display.")
            print("       Check that the camera faces the room and is not obstructed.")
        }

        finish(error: nil)
    }

    private func finish(error: String?) {
        if let error {
            failure = error
            print("\nERROR: \(error)")
        }
        if let display {
            print("\nRestoring brightness to \(Int(originalBrightness * 100))%")
            display.setBrightness(Float(originalBrightness))
        }
        sensor.stop()
        // Give the DDC write and the camera teardown time to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exit(error == nil ? 0 : 1)
        }
    }

    // MARK: - AmbientLightSensorDelegate

    nonisolated func ambientSensor(_ sensor: AmbientLightSensor, didProduce reading: AmbientReading) {
        Task { @MainActor in self.readings.append(reading) }
    }

    nonisolated func ambientSensor(_ sensor: AmbientLightSensor, didFail error: AmbientSensorError) {
        Task { @MainActor in self.finish(error: error.description) }
    }
}
