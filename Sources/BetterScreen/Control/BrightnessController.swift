import AppKit
import Foundation
import IOKit.ps

/// Drives display brightness from ambient light readings.
///
/// Responsibilities, in the order they matter:
///  - reject noise, so brightness does not visibly hunt
///  - ramp rather than jump, because a step change is far more distracting than a
///    slow one, even a large one
///  - notice when the user overrules us, and learn from it instead of fighting
///  - release the camera whenever metering is pointless
@MainActor
final class BrightnessController {
    static let shared = BrightnessController()

    private let sensor = AmbientLightSensor()
    private var rampTimer: Timer?
    private var driftTimer: Timer?

    private(set) var latestReading: AmbientReading?
    private(set) var lastError: AmbientSensorError?
    private(set) var isPaused = false
    private(set) var pauseReason: String?

    /// Candidate light level awaiting the settle delay.
    private var pendingStops: (value: Double, since: Date)?

    private struct Ramp {
        var from: Double
        var to: Double
        var startedAt: Date
        var duration: TimeInterval
    }

    private var ramps: [String: Ramp] = [:]

    /// Last value we ourselves wrote, per display key. Anything else the hardware
    /// reports is by definition someone else's doing.
    private var lastWritten: [String: Double] = [:]

    /// Light level in effect when the current target was chosen, so a manual
    /// adjustment is attributed to the right lighting condition.
    private var stopsAtLastTarget: Double?

    private var screenIsLocked = false
    private var screensAsleep = false

    private init() {
        sensor.delegate = self
    }

    var isEnabled: Bool { SettingsStore.shared.settings.isAutoBrightnessEnabled }
    var activeCameraName: String? { sensor.activeCameraName }

    // MARK: - Lifecycle

    func start() {
        DisplayManager.shared.onDisplaysChanged = { [weak self] in
            self?.handleDisplaysChanged()
        }
        observePauseConditions()
        applySettings()

        // External brightness changes (monitor buttons, F1/F2, Control Centre) are
        // the main learning signal, so poll for them.
        driftTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForManualAdjustments() }
        }
    }

    func stop() {
        sensor.stop()
        rampTimer?.invalidate()
        rampTimer = nil
        driftTimer?.invalidate()
        driftTimer = nil
    }

    /// Re-reads configuration and starts or stops the camera accordingly.
    func applySettings() {
        let settings = SettingsStore.shared.settings
        sensor.updateInterval = settings.updateInterval
        sensor.preferredDeviceID = settings.cameraUniqueID

        guard settings.isAutoBrightnessEnabled else {
            sensor.stop()
            cancelAllRamps()
            return
        }

        if let reason = currentPauseReason() {
            isPaused = true
            pauseReason = reason
            sensor.stop()
            cancelAllRamps()
            Log.control.info("Paused: \(reason)")
            return
        }

        isPaused = false
        pauseReason = nil
        lastError = nil
        sensor.start()
    }

    func setEnabled(_ enabled: Bool) {
        SettingsStore.shared.update { $0.isAutoBrightnessEnabled = enabled }
        applySettings()
    }

    private func cancelAllRamps() {
        ramps.removeAll()
        rampTimer?.invalidate()
        rampTimer = nil
    }

    // MARK: - Pause conditions

    private func observePauseConditions() {
        let workspace = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()

        // Screen lock is only reported through the distributed centre.
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.screenIsLocked = true
                self?.applySettings()
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.screenIsLocked = false
                self?.applySettings()
            }
        }

        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.screensAsleep = asleep
                    self?.applySettings()
                }
            }
        }

        // Power source changes have no notification worth wiring up; a slow poll is
        // enough, since the setting only gates camera use.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, SettingsStore.shared.settings.pauseOnBattery else { return }
                let shouldPause = self.currentPauseReason() != nil
                if shouldPause != self.isPaused { self.applySettings() }
            }
        }
    }

    private func currentPauseReason() -> String? {
        let settings = SettingsStore.shared.settings
        if settings.pauseWhenScreenLocked {
            if screenIsLocked { return "screen locked" }
            if screensAsleep { return "display asleep" }
        }
        if settings.pauseOnBattery, Self.isOnBattery() { return "on battery" }
        return nil
    }

    /// True when running from the battery rather than AC.
    private static func isOnBattery() -> Bool {
        var remaining: Bool?
        let estimate = IOPSGetTimeRemainingEstimate()
        // kIOPSTimeRemainingUnlimited means an unlimited (i.e. AC) power source.
        remaining = estimate != kIOPSTimeRemainingUnlimited
        return remaining ?? false
    }

    private func handleDisplaysChanged() {
        // Drop ramps for displays that went away; a stale ramp would keep writing to
        // a display ID that no longer refers to the same panel.
        let liveKeys = Set(DisplayManager.shared.displays.map(\.persistentKey))
        ramps = ramps.filter { liveKeys.contains($0.key) }
        lastWritten = lastWritten.filter { liveKeys.contains($0.key) }

        // A newly attached display should not wait for the next reading.
        if let stops = stopsAtLastTarget ?? latestReading?.stops, isEnabled, !isPaused {
            applyTarget(stops: stops, immediate: false)
        }
    }

    // MARK: - Target selection

    /// Accepts a new light level only once it has held steady, then ramps to it.
    ///
    /// Two independent guards, because they catch different things: the settle delay
    /// rejects transients (someone walking past the camera, a passing cloud), while
    /// the change threshold rejects sustained-but-tiny drift that would otherwise
    /// produce a steady trickle of DDC traffic.
    private func considerReading(_ reading: AmbientReading) {
        guard isEnabled, !isPaused else { return }

        // The sensor flags readings it cannot trust: clipped frames, or a scene
        // outside the camera's dynamic range. Acting on those drives the display to
        // an extreme -- a covered lens once produced a 7-stop reading and took the
        // monitor to 6% -- so hold the current brightness and discard any candidate
        // that was maturing, since it may already be contaminated.
        guard reading.isReliable else {
            if pendingStops != nil {
                Log.control.debug("Discarding candidate: sensor reading is out of range")
                pendingStops = nil
            }
            return
        }

        let settings = SettingsStore.shared.settings
        let stops = reading.stops

        guard let pending = pendingStops else {
            pendingStops = (stops, Date())
            return
        }

        // A large jump restarts the clock; small variation extends the existing
        // candidate rather than resetting it.
        if abs(stops - pending.value) > 0.75 {
            pendingStops = (stops, Date())
            return
        }

        pendingStops = (stops, pending.since)
        guard Date().timeIntervalSince(pending.since) >= settings.stabilityDelay else { return }

        applyTarget(stops: stops, immediate: false)
        pendingStops = (stops, Date())
    }

    private func applyTarget(stops: Double, immediate: Bool) {
        guard !DisplayManager.shared.isReconfiguring else { return }
        let settings = SettingsStore.shared.settings
        stopsAtLastTarget = stops

        for display in DisplayManager.shared.displays {
            let displaySettings = settings.displays[display.persistentKey] ?? DisplaySettings()
            guard displaySettings.isManaged else { continue }

            let target = displaySettings.curve.brightness(atStops: stops)
            let current = Double(display.currentBrightness)

            guard current < 0 || abs(target - current) >= settings.changeThreshold else { continue }

            if immediate || settings.transitionDuration <= 0 || current < 0 {
                write(target, to: display)
            } else {
                ramps[display.persistentKey] = Ramp(
                    from: current,
                    to: target,
                    startedAt: Date(),
                    duration: settings.transitionDuration
                )
            }
        }

        startRampTimerIfNeeded()
    }

    // MARK: - Ramping

    private func startRampTimerIfNeeded() {
        guard !ramps.isEmpty, rampTimer == nil else { return }
        // ~20 Hz. DDC writes cost ~3 ms and are serialised across displays, so this
        // stays well within budget even with several monitors.
        rampTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepRamps() }
        }
    }

    private func stepRamps() {
        guard !DisplayManager.shared.isReconfiguring else { return }
        let now = Date()

        for (key, ramp) in ramps {
            guard let display = DisplayManager.shared.display(forKey: key) else {
                ramps.removeValue(forKey: key)
                continue
            }

            let elapsed = now.timeIntervalSince(ramp.startedAt)
            let progress = ramp.duration > 0 ? min(elapsed / ramp.duration, 1.0) : 1.0
            // Smoothstep: zero velocity at both ends, so neither the start nor the
            // end of a transition draws the eye.
            let eased = progress * progress * (3 - 2 * progress)
            write(ramp.from + (ramp.to - ramp.from) * eased, to: display)

            if progress >= 1.0 { ramps.removeValue(forKey: key) }
        }

        if ramps.isEmpty {
            rampTimer?.invalidate()
            rampTimer = nil
        }
    }

    private func write(_ value: Double, to display: ManagedDisplay) {
        guard display.setBrightness(Float(value)) else { return }
        lastWritten[display.persistentKey] = Double(display.currentBrightness)
    }

    // MARK: - Manual override & learning

    /// Detects brightness changes we did not make and treats them as preferences.
    ///
    /// Only meaningful for DisplayServices-driven displays: DDC reads return a
    /// valid-but-stale value often enough that polling a DDC monitor would
    /// manufacture phantom "user adjustments".
    private func pollForManualAdjustments() {
        guard isEnabled, !isPaused, ramps.isEmpty, !DisplayManager.shared.isReconfiguring else { return }
        guard let stops = stopsAtLastTarget else { return }

        for display in DisplayManager.shared.displays {
            guard display.kind == .builtIn || display.kind == .appleExternal else { continue }
            guard let actual = display.readBrightness(),
                  let written = lastWritten[display.persistentKey] else { continue }

            // Comfortably above slider quantisation, so rounding cannot masquerade
            // as intent.
            guard abs(Double(actual) - written) > 0.03 else { continue }

            Log.control.info(String(
                format: "Manual adjustment on %@: %.3f -> %.3f",
                display.name, written, Double(actual)
            ))
            recordPreference(brightness: Double(actual), stops: stops, display: display)
        }
    }

    /// Called by the UI when the user drags a brightness slider, and by drift
    /// detection when they use the hardware controls.
    func recordPreference(brightness: Double, stops: Double? = nil, display: ManagedDisplay) {
        guard let stops = stops ?? latestReading?.stops else {
            Log.control.debug("Not learning: no ambient reading yet")
            return
        }

        // Never learn from a clipped frame: its level is a bound, not a measurement,
        // so the correction would be filed under the wrong lighting condition.
        if let reading = latestReading, !reading.isReliable, stops == reading.stops {
            Log.control.debug("Not learning: current reading is out of measuring range")
            return
        }

        SettingsStore.shared.updateDisplay(display.persistentKey) { settings in
            settings.lastKnownName = display.name
            settings.curve.learn(stops: stops, chosenBrightness: brightness)
        }
        lastWritten[display.persistentKey] = brightness
    }

    /// Manual brightness set from the UI. Cancels any ramp for that display so the
    /// slider does not fight the transition.
    func setBrightnessManually(_ value: Double, for display: ManagedDisplay) {
        ramps.removeValue(forKey: display.persistentKey)
        write(value, to: display)
    }

    /// Recomputes and applies immediately, e.g. after the user edits the curve.
    func reapplyNow() {
        guard let stops = stopsAtLastTarget ?? latestReading?.stops else { return }
        applyTarget(stops: stops, immediate: true)
    }
}

// MARK: - AmbientLightSensorDelegate

extension BrightnessController: AmbientLightSensorDelegate {
    nonisolated func ambientSensor(_ sensor: AmbientLightSensor, didProduce reading: AmbientReading) {
        Task { @MainActor in
            self.latestReading = reading
            self.lastError = nil
            Log.ambient.debug(String(
                format: "light=%.3f× (%+.2f stops) raw=%.4f gain=%.4f clip=%.2f/%.2f locked=%@ reliable=%@",
                reading.relativeLight, reading.stops, reading.rawLuminance, reading.gainFactor,
                reading.clippedHigh, reading.clippedLow,
                reading.exposureLocked ? "y" : "n", reading.isReliable ? "y" : "n"
            ))
            self.considerReading(reading)
            MenuBarController.shared?.refresh()
        }
    }

    nonisolated func ambientSensor(_ sensor: AmbientLightSensor, didFail error: AmbientSensorError) {
        Task { @MainActor in
            self.lastError = error
            MenuBarController.shared?.refresh()
        }
    }
}
