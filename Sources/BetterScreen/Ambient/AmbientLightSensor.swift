import AVFoundation
import Foundation

/// One ambient light measurement.
struct AmbientReading {
    let timestamp: Date

    /// Ambient light relative to the level in effect when exposure was locked.
    ///
    /// 1.0 means "the same light as at the anchor point", 2.0 means "twice as
    /// bright", 0.5 means "half as bright". The scale is genuinely relative -- see
    /// the note on `AmbientLightSensor` for why absolute luminance is not
    /// obtainable on macOS.
    let relativeLight: Double

    /// Mean linear frame luminance at the gain actually in effect.
    let rawLuminance: Double

    /// Cumulative gain multiplier accumulated across re-ranges.
    let gainFactor: Double

    let clippedHigh: Double
    let clippedLow: Double
    let exposureLocked: Bool

    /// False when the frame is clipped badly enough that the value is a bound
    /// rather than a measurement. Such readings still drive brightness -- a clipped
    /// bright frame really does mean "bright" -- but are never learned from.
    let isReliable: Bool

    /// log2 of `relativeLight`: 0 at the anchor, +1 per doubling of light.
    var stops: Double { log2(max(relativeLight, 1e-6)) }
}

enum AmbientSensorError: Error, CustomStringConvertible, Equatable {
    case permissionDenied
    case noCameraAvailable
    case cameraInUse(String)
    case exposureLockUnsupported(String)
    case configurationFailed(String)

    var description: String {
        switch self {
        case .permissionDenied:
            "Camera access denied"
        case .noCameraAvailable:
            "No camera available"
        case let .cameraInUse(name):
            "\(name) could not be opened"
        case let .exposureLockUnsupported(name):
            "\(name) cannot lock exposure, which is required to measure light"
        case let .configurationFailed(reason):
            "Camera setup failed: \(reason)"
        }
    }
}

protocol AmbientLightSensorDelegate: AnyObject {
    func ambientSensor(_ sensor: AmbientLightSensor, didProduce reading: AmbientReading)
    func ambientSensor(_ sensor: AmbientLightSensor, didFail error: AmbientSensorError)
}

/// Uses a camera as a relative ambient light meter.
///
/// ## Why the reading is relative, not absolute
///
/// Autoexposure actively defeats naive light metering: it drives mean luminance to
/// a fixed target, so a dark room and a bright room both read as mid-grey. To
/// recover scene luminance you need the exposure the camera chose, and on macOS
/// that is unavailable by every route:
///
///  - `exposureDuration`, `ISO`, `lensAperture`, `exposureTargetOffset` and
///    `setExposureModeCustomWithDuration:ISO:` are all `API_UNAVAILABLE(macos)`.
///    Only `exposureMode` itself is exposed.
///  - Frame buffers carry no exposure metadata. Verified by dumping every
///    attachment on a Logitech C925e: only colour primaries, transfer function and
///    YCbCr matrix are present.
///  - Autoexposure has already converged by the time the first frame is delivered
///    (~0.5 s after `startRunning`), so there is no "cold" default-gain frame to
///    use as a fixed reference. Verified: luminance is flat at 0.249 -> 0.251
///    across the first two seconds.
///
/// With only relative luminance and no gain readout, absolute scene luminance is
/// unobservable -- that is a property of the API surface, not a missing trick.
/// Escaping it would require reading exposure over USB with UVC control requests.
///
/// ## What this does instead
///
/// `exposureMode = .locked` *is* available. With gain frozen, frame luminance
/// becomes proportional to scene luminance, giving an accurate measure of light
/// *relative* to the moment of locking:
///
///     relativeLight = rawLuminance / (aeTargetLuminance * gainFactor)
///
/// A single fixed exposure only spans roughly 50:1 before clipping or flooring, so
/// when the signal leaves the usable band the sensor re-ranges: briefly re-enable
/// autoexposure, then re-lock. The scene does not change across that switch, so
/// luminance measured just before and just after gives the gain ratio directly --
/// which is how gain is tracked despite never being readable. Chaining those
/// ratios makes the range effectively unbounded within a session.
///
/// Consequence for the rest of the app: the controller must treat the reading as
/// a relative signal anchored at startup, and re-anchor from user adjustments.
final class AmbientLightSensor: NSObject {
    weak var delegate: AmbientLightSensorDelegate?

    // MARK: - Configuration

    /// Unique ID of the camera to use; nil picks a default.
    var preferredDeviceID: String? {
        didSet { if preferredDeviceID != oldValue { restartIfRunning() } }
    }

    /// Seconds between emitted readings. Frames arrive far faster and are dropped.
    var updateInterval: TimeInterval = 2.0

    // MARK: - Tuning

    /// Time to let autoexposure converge, measured from the *first delivered
    /// frame* rather than from `startRunning`. The camera takes ~0.5 s to produce
    /// anything, and timing from session start would consume the whole window.
    private static let settleDuration: TimeInterval = 1.2

    /// Re-range when raw luminance leaves this band.
    ///
    /// The upper bound is far below 1.0 on purpose: a gain ratio measured from an
    /// already-clipped frame underestimates, and that error would compound at every
    /// re-range.
    private static let rerangeHigh = 0.55
    private static let rerangeLow = 0.02

    /// Minimum gap between re-ranges.
    ///
    /// Without this the sensor livelocks: a scene beyond the camera's range leaves
    /// raw luminance out of band, re-ranging cannot fix that, and the next frame
    /// immediately triggers another attempt. Observed in the field as 39 re-ranges
    /// in 55 s with gainFactor thrashing between 0.12 and 658.
    private static let rerangeCooldown: TimeInterval = 8

    /// Longest wait for autoexposure to converge during a re-range. Traversing a
    /// large gain change takes far longer than `settleDuration`, which is sized for
    /// the initial lock on an already well-exposed scene.
    private static let rerangeTimeout: TimeInterval = 4

    /// How long raw luminance must hold steady (within `rerangeStableTolerance`)
    /// before the new gain is considered converged.
    private static let rerangeStableWindow: TimeInterval = 0.5
    private static let rerangeStableTolerance = 0.03

    /// How long the light must hold steady *before* a re-range is allowed to start.
    ///
    /// A re-range derives gain from `lumaAfter / lumaBefore`, which is only the gain
    /// ratio if the scene is unchanged across the unlock/relock. Re-ranges trigger
    /// exactly when the light is moving, so measuring mid-transition attributes the
    /// scene change to gain and corrupts the scale permanently. Waiting for the room
    /// to stop changing is what makes the ratio meaningful.
    private static let preRerangeStableWindow: TimeInterval = 1.0
    private static let preRerangeStableTolerance = 0.05

    /// Consecutive failed re-ranges before declaring the scene out of range and
    /// giving up until it returns on its own.
    private static let maxRerangeAttempts = 2

    /// Largest believable gain change from a single re-range. Anything beyond this
    /// means the measurement caught autoexposure mid-ramp, and folding it in would
    /// corrupt the `relativeLight` scale for the rest of the session.
    private static let maxGainRatio = 64.0

    /// Clipping tolerances. A few percent of pixels at full scale is normal
    /// whenever a lamp or window is in frame, and does not invalidate the mean.
    private static let clipHighTolerance = 0.12
    private static let clipLowTolerance = 0.80

    // MARK: - Capture stack

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.betterscreen.ambient.session")
    private let frameQueue = DispatchQueue(label: "com.betterscreen.ambient.frames")

    private var device: AVCaptureDevice?
    private var isRunning = false

    private(set) var activeCameraName: String?

    // MARK: - Measurement state (frameQueue only)

    private enum Phase {
        /// Autoexposure converging; measuring its target luminance.
        case settling
        /// Exposure locked, emitting readings.
        case measuring
        /// Autoexposure temporarily re-enabled to pick a new gain.
        case reranging(lumaBefore: Double)
        /// Rebuilding the reference from scratch after a saturated excursion left
        /// the gain bookkeeping untrustworthy.
        case reanchoring
    }

    private var phase: Phase = .settling
    private var firstFrameAt: Date?

    /// The luminance autoexposure converges to. A device constant (~0.25 on the
    /// C925e) and the denominator that makes `relativeLight` equal 1.0 at anchor.
    private var aeTargetLuminance: Double?

    private var gainFactor: Double = 1.0
    private var smoothedRaw: Double?
    private var lastEmit = Date.distantPast
    private var exposureIsLocked = false
    private var rerangeStartedAt = Date.distantPast
    private var lastRerangeEndedAt = Date.distantPast
    private var reanchorStartedAt = Date.distantPast

    /// Timestamped luminance sample used to detect that luminance has stopped
    /// moving, both while waiting for autoexposure to converge and while waiting
    /// for the room itself to stop changing.
    private var settleProbe: (at: Date, luma: Double)?

    private var rerangeFailures = 0

    /// True once re-ranging has repeatedly failed to bring the signal back into
    /// band. The scene is outside what the camera can measure, so readings continue
    /// but are flagged unreliable and no further re-ranges are attempted until the
    /// signal recovers by itself.
    private var isOutOfRange = false

    /// Newest unsmoothed frame luminance. Diagnostics only -- the control path uses
    /// the smoothed value, but a raw figure is needed to tell a genuinely flat
    /// signal from an over-smoothed one.
    private(set) var instantaneousLuminance: Double = 0

    // MARK: - Camera discovery

    /// Cameras suitable for light metering.
    ///
    /// Continuity Camera is excluded: selecting it would wake the user's iPhone,
    /// and it is rarely pointed at the room.
    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.filter { !isVirtualCamera($0) }
    }

    /// Virtual cameras show whatever software feeds them, not the room. There is no
    /// API flag for this, so name matching is the only option; it only affects the
    /// default choice, and an explicit selection is always honoured.
    private static func isVirtualCamera(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return ["virtual", "obs", "snap camera", "loopback", "ndi", "mmhmm"].contains { name.contains($0) }
    }

    /// Exposure lock is a hard requirement: without it there is no measurement at
    /// all, only autoexposure's constant target.
    static func supportsExposureLock(_ device: AVCaptureDevice) -> Bool {
        device.isExposureModeSupported(.locked)
    }

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        switch Self.authorizationStatus {
        case .authorized:
            isRunning = true
            sessionQueue.async { [weak self] in self?.configureAndRun() }
        case .notDetermined:
            Self.requestAccess { [weak self] granted in
                guard let self else { return }
                if granted { self.start() } else { self.emitFailure(.permissionDenied) }
            }
        case .denied, .restricted:
            emitFailure(.permissionDenied)
        @unknown default:
            emitFailure(.permissionDenied)
        }
    }

    func stop() {
        isRunning = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            // Leave the camera as we found it, so other apps get working
            // autoexposure.
            self.setExposureMode(.continuousAutoExposure)
        }
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        // Let the session finish tearing down before reconfiguring.
        sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            DispatchQueue.main.async { self?.start() }
        }
    }

    // MARK: - Session setup

    private func configureAndRun() {
        guard let device = resolveDevice() else {
            emitFailure(.noCameraAvailable)
            return
        }

        guard Self.supportsExposureLock(device) else {
            emitFailure(.exposureLockUnsupported(device.localizedName))
            return
        }

        self.device = device
        activeCameraName = device.localizedName

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for existing in session.outputs { session.removeOutput(existing) }

        // Lowest resolution available: a light meter needs no detail, and this keeps
        // CPU and USB bandwidth negligible.
        if session.canSetSessionPreset(.low) {
            session.sessionPreset = .low
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                emitFailure(.cameraInUse(device.localizedName))
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            emitFailure(.cameraInUse(device.localizedName))
            return
        }

        // BGRA rather than a YpCbCr format: always available, and it allows
        // luminance to be computed from linearised RGB with Rec. 709 weights
        // instead of from a gamma-encoded luma channel.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            emitFailure(.configurationFailed("could not attach video output"))
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        resetMeasurementState()
        setExposureMode(.continuousAutoExposure)
        session.startRunning()
        Log.ambient.info("Metering with \(device.localizedName)")
    }

    private func resetMeasurementState() {
        frameQueue.sync {
            phase = .settling
            firstFrameAt = nil
            aeTargetLuminance = nil
            gainFactor = 1.0
            smoothedRaw = nil
            lastEmit = .distantPast
        }
    }

    private func resolveDevice() -> AVCaptureDevice? {
        let cameras = Self.availableCameras()
        if let preferredDeviceID, let match = cameras.first(where: { $0.uniqueID == preferredDeviceID }) {
            return match
        }
        // Exposure lock is mandatory, so prefer a camera that has it. Then prefer
        // external: in clamshell the built-in camera is behind a closed lid.
        if let best = cameras.first(where: { Self.supportsExposureLock($0) && $0.deviceType == .external }) {
            return best
        }
        if let lockable = cameras.first(where: { Self.supportsExposureLock($0) }) {
            return lockable
        }
        return cameras.first { $0.deviceType == .external } ?? cameras.first
    }

    // MARK: - Exposure

    private func setExposureMode(_ target: AVCaptureDevice.ExposureMode) {
        guard let device, device.isExposureModeSupported(target) else { return }
        do {
            try device.lockForConfiguration()
            device.exposureMode = target
            let readBack = device.exposureMode
            device.unlockForConfiguration()

            // A UVC driver may accept .locked and keep running autoexposure in
            // firmware regardless. Reading the property back at least catches the
            // case where the assignment did not stick at all.
            exposureIsLocked = (readBack == .locked)
            if readBack != target {
                Log.ambient.warning(
                    "Exposure mode did not stick: asked for \(target.rawValue), device reports \(readBack.rawValue)"
                )
            }
        } catch {
            Log.ambient.warning("Could not set exposure mode: \(error.localizedDescription)")
        }
    }

    /// Diagnostics only: forces autoexposure back on so a control condition can be
    /// compared against the locked state.
    func overrideExposureAuto() {
        sessionQueue.async { [weak self] in self?.setExposureMode(.continuousAutoExposure) }
    }

    private func emitFailure(_ error: AmbientSensorError) {
        isRunning = false
        Log.ambient.error(error.description)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.ambientSensor(self, didFail: error)
        }
    }
}

// MARK: - Frame processing

extension AmbientLightSensor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = LumaExtractor.extract(from: pixelBuffer)
        else { return }

        let now = Date()
        if firstFrameAt == nil { firstFrameAt = now }
        instantaneousLuminance = frame.luminance
        updateSmoothed(frame.luminance)

        switch phase {
        case .settling:
            guard let start = firstFrameAt,
                  now.timeIntervalSince(start) >= Self.settleDuration
            else { return }
            lockAndAnchor()

        case .measuring:
            evaluate(frame)

        case let .reranging(lumaBefore):
            guard let current = smoothedRaw else { return }
            let elapsed = now.timeIntervalSince(rerangeStartedAt)

            // Autoexposure needs a moment to even begin reacting.
            guard elapsed >= Self.settleDuration else { return }

            // Converged once luminance stops moving. A fixed delay is not enough: a
            // large gain change takes seconds, and sampling mid-ramp yields a
            // meaningless gain ratio.
            let settled = luminanceHasSettled(current, now: now,
                                              window: Self.rerangeStableWindow,
                                              tolerance: Self.rerangeStableTolerance)
            if settled || elapsed >= Self.rerangeTimeout {
                completeRerange(lumaBefore: lumaBefore, lumaAfter: current)
            }

        case .reanchoring:
            guard let current = smoothedRaw else { return }
            let elapsed = now.timeIntervalSince(reanchorStartedAt)
            guard elapsed >= Self.settleDuration else { return }

            let settled = luminanceHasSettled(current, now: now,
                                              window: Self.rerangeStableWindow,
                                              tolerance: Self.rerangeStableTolerance)
            if settled || elapsed >= Self.rerangeTimeout {
                settleProbe = nil
                lockAndAnchor()
            }
        }
    }

    /// Freezes exposure and records autoexposure's target as the reference
    /// luminance, defining `relativeLight == 1.0` at this instant.
    private func lockAndAnchor() {
        guard let settled = smoothedRaw, settled > 0 else { return }

        aeTargetLuminance = settled
        gainFactor = 1.0
        setExposureMode(.locked)
        phase = .measuring

        Log.ambient.info(String(
            format: "Exposure locked. AE target luminance = %.5f (this is now relativeLight 1.0)",
            settled
        ))
    }

    /// True once smoothed luminance has held within `tolerance` for `window`.
    ///
    /// Call once per frame while waiting. Resets its own reference whenever the
    /// value moves, so a slow continuous drift never counts as settled.
    private func luminanceHasSettled(
        _ current: Double,
        now: Date,
        window: TimeInterval,
        tolerance: Double
    ) -> Bool {
        guard let probe = settleProbe else {
            settleProbe = (now, current)
            return false
        }
        guard now.timeIntervalSince(probe.at) >= window else { return false }

        let drift = abs(current - probe.luma) / max(probe.luma, 1e-6)
        if drift <= tolerance { return true }
        settleProbe = (now, current)
        return false
    }

    private func evaluate(_ frame: FrameLuma) {
        guard let raw = smoothedRaw, let target = aeTargetLuminance, target > 0 else { return }

        let inBand = raw <= Self.rerangeHigh && raw >= Self.rerangeLow

        let now = Date()

        if inBand {
            settleProbe = nil

            // While saturated the true gain was changing unobservably: at the sensor
            // floor both sides of the ratio read the same value, so the change was
            // never recorded. Carrying that bookkeeping forward is what drifted
            // gainFactor by 170x and left a normally lit room reading +7 stops. The
            // only honest recovery is to discard the reference and build a new one.
            if isOutOfRange {
                beginReanchor()
                return
            }
            rerangeFailures = 0
        } else if exposureIsLocked, !isOutOfRange,
                  now.timeIntervalSince(lastRerangeEndedAt) >= Self.rerangeCooldown {
            // Re-range before the signal actually clips, not after -- but only once
            // the light has stopped moving, so the measured ratio is gain and not
            // the scene changing underneath it.
            if luminanceHasSettled(raw, now: now,
                                   window: Self.preRerangeStableWindow,
                                   tolerance: Self.preRerangeStableTolerance) {
                settleProbe = nil
                beginRerange(lumaBefore: raw)
                return
            }
        }
        // Otherwise fall through and keep publishing. An out-of-band reading is
        // still directionally useful, and it is flagged unreliable so the control
        // loop can hold rather than chase a value the camera cannot resolve.

        guard Date().timeIntervalSince(lastEmit) >= updateInterval else { return }
        lastEmit = Date()

        let reliable = inBand
            && frame.clippedHigh <= Self.clipHighTolerance
            && frame.clippedLow <= Self.clipLowTolerance

        publish(AmbientReading(
            timestamp: Date(),
            relativeLight: raw / (target * gainFactor),
            rawLuminance: raw,
            gainFactor: gainFactor,
            clippedHigh: frame.clippedHigh,
            clippedLow: frame.clippedLow,
            exposureLocked: exposureIsLocked,
            isReliable: reliable
        ))
    }

    private func beginRerange(lumaBefore: Double) {
        Log.ambient.info(String(format: "Re-ranging: raw luminance %.4f left the usable band", lumaBefore))
        rerangeStartedAt = Date()
        settleProbe = nil
        phase = .reranging(lumaBefore: lumaBefore)
        setExposureMode(.continuousAutoExposure)
    }

    /// Discards the reference and rebuilds it from autoexposure's own target.
    ///
    /// `relativeLight` deliberately jumps here. Continuity would be a lie: the gain
    /// changes that happened while saturated were never observable, so the old scale
    /// no longer relates to the new one. The cost is that the reference light level
    /// shifts, so calibrations recorded before the excursion no longer describe the
    /// same conditions.
    private func beginReanchor() {
        Log.ambient.info("""
        Re-anchoring after an out-of-range excursion: gain changed unobservably while \
        saturated, so the old reference is discarded rather than carried forward.
        """)

        isOutOfRange = false
        rerangeFailures = 0
        gainFactor = 1.0
        aeTargetLuminance = nil
        settleProbe = nil
        reanchorStartedAt = Date()
        phase = .reanchoring
        setExposureMode(.continuousAutoExposure)
    }

    /// Records a failed re-range, and gives up once attempts are exhausted.
    private func noteRerangeFailure(_ reason: String) {
        rerangeFailures += 1
        if rerangeFailures >= Self.maxRerangeAttempts {
            isOutOfRange = true
            Log.ambient.info("""
            Giving up re-ranging (\(reason)). The scene is outside the camera's \
            dynamic range, so readings continue but are flagged out of range until \
            the signal recovers.
            """)
        } else {
            Log.ambient.info("Re-range attempt \(self.rerangeFailures) failed (\(reason))")
        }
    }

    /// Folds the measured gain ratio into the cumulative gain factor.
    ///
    /// The scene is unchanged across the switch, so `lumaAfter / lumaBefore` is
    /// exactly the ratio of new gain to old gain. Applying it keeps `relativeLight`
    /// continuous across a re-range even though gain itself is never observable.
    private func completeRerange(lumaBefore: Double, lumaAfter: Double) {
        defer {
            setExposureMode(.locked)
            phase = .measuring
            lastRerangeEndedAt = Date()
            settleProbe = nil
        }

        guard lumaBefore > 0, lumaAfter > 0, let target = aeTargetLuminance else {
            noteRerangeFailure("no usable luminance")
            return
        }

        // Reject a ratio that cannot be a real gain change. Folding one in would
        // permanently corrupt the relativeLight scale, so keep the previous factor.
        let ratio = lumaAfter / lumaBefore
        guard ratio.isFinite, ratio <= Self.maxGainRatio, ratio >= 1 / Self.maxGainRatio else {
            noteRerangeFailure(String(format: "implausible gain ratio %.1f×", ratio))
            return
        }

        let before = lumaBefore / (target * gainFactor)
        gainFactor = max(gainFactor * ratio, 1e-9)
        let after = lumaAfter / (target * gainFactor)

        Log.ambient.info(String(
            format: "Re-ranged: gainFactor=%.5f relativeLight %.4f -> %.4f (should match)",
            gainFactor, before, after
        ))

        // Did it actually achieve anything? If the signal is still out of band the
        // camera is at the end of its range and retrying is pointless.
        if lumaAfter > Self.rerangeHigh || lumaAfter < Self.rerangeLow {
            noteRerangeFailure(String(format: "luminance still out of band at %.4f", lumaAfter))
        } else {
            rerangeFailures = 0
        }
    }

    /// Exponential moving average, to reject the frame-to-frame noise a cheap
    /// sensor produces in low light.
    private func updateSmoothed(_ value: Double) {
        let alpha = 0.25
        smoothedRaw = smoothedRaw.map { $0 + alpha * (value - $0) } ?? value
    }

    private func publish(_ reading: AmbientReading) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.ambientSensor(self, didProduce: reading)
        }
    }
}
