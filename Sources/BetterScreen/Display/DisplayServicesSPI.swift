import CoreGraphics
import Foundation

/// Access to `DisplayServices.framework` (a private framework) for brightness
/// control of the built-in panel, Studio Display and Pro Display XDR.
///
/// Loaded with dlopen/dlsym rather than linked, for two reasons:
///
///  1. Linking a private framework needs `-F /System/Library/PrivateFrameworks`,
///     which in SwiftPM means `.unsafeFlags` -- and a package using unsafeFlags
///     can never be consumed as a dependency.
///  2. Symbols do get removed. `DisplayServicesBrightnessChanged` existed for
///     years and is gone in macOS 26. With dlsym that degrades to `nil`; with a
///     hard link it is a dyld abort at launch.
///
/// Accordingly, *every* symbol here is optional and every call site handles nil.
enum DisplayServicesSPI {
    // MARK: - Framework handles

    private static let displayServices: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY | RTLD_LOCAL
    )

    // MARK: - C function types
    //
    // @convention(c) is mandatory. A bare Swift function type is a *thick*
    // two-word value (pointer + context); unsafeBitCast'ing a dlsym address into
    // one produces a callee with a garbage context word.

    private typealias GetFloatFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFloatFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias PredicateFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias RangeFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Int32
    /// NOTE: returns IOReturn, *not* Bool, despite the name. Declaring it Bool
    /// yields different wrong answers in C and Swift from the same call.
    private typealias ALCEnabledFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias ALCEnableFn = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private static func sym<T>(_ name: String) -> T? {
        guard let handle = displayServices, let addr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(addr, to: T.self)
    }

    private static let getBrightnessFn: GetFloatFn? = sym("DisplayServicesGetBrightness")
    private static let setBrightnessFn: SetFloatFn? = sym("DisplayServicesSetBrightness")
    private static let canChangeBrightnessFn: PredicateFn? = sym("DisplayServicesCanChangeBrightness")
    private static let isSmartDisplayFn: PredicateFn? = sym("DisplayServicesIsSmartDisplay")
    private static let isBuiltInDisplayFn: PredicateFn? = sym("DisplayServicesIsBuiltInDisplay")
    private static let needsSmoothingFn: PredicateFn? = sym("DisplayServicesNeedsBrightnessSmoothing")
    private static let getLinearRangeFn: RangeFn? = sym("DisplayServicesGetLinearBrightnessUsableRange")
    private static let hasALCFn: PredicateFn? = sym("DisplayServicesHasAmbientLightCompensation")
    private static let alcEnabledFn: ALCEnabledFn? = sym("DisplayServicesAmbientLightCompensationEnabled")
    private static let enableALCFn: ALCEnableFn? = sym("DisplayServicesEnableAmbientLightCompensation")

    /// All writes are serialised. Rapid concurrent `SetBrightness` calls during a
    /// smooth ramp crashed MonitorControl on macOS 15 (issue #1570); the reporter
    /// confirmed disabling the soft transition avoided it.
    private static let writeQueue = DispatchQueue(label: "com.betterscreen.displayservices")

    /// True if the framework loaded and the core brightness pair resolved.
    static var isAvailable: Bool { getBrightnessFn != nil && setBrightnessFn != nil }

    // MARK: - Brightness

    /// Current brightness in the perceptual (slider) domain, 0...1.
    ///
    /// Returns nil when this display is not DisplayServices-driveable. A failure
    /// is reported as return code 1000 -- a DisplayServices-private code, not an
    /// IOReturn. Also returns nil for offline/asleep displays, which is why
    /// clamshell needs handling upstream.
    static func brightness(for display: CGDirectDisplayID) -> Float? {
        guard let fn = getBrightnessFn else { return nil }
        var value: Float = -1
        guard fn(display, &value) == 0, value >= 0 else { return nil }
        return value
    }

    /// Sets brightness in the perceptual (slider) domain, 0...1.
    ///
    /// The return value of the underlying call is useless as a success signal: it
    /// returns 0 even for displays it cannot drive at all (verified against a
    /// DDC-only monitor, where the gamma ramp confirmed a true no-op). This is
    /// the bug in Homebrew's `brightness` CLI. Callers must therefore establish
    /// capability with `brightness(for:) != nil` *first*.
    @discardableResult
    static func setBrightness(_ value: Float, for display: CGDirectDisplayID) -> Bool {
        guard let fn = setBrightnessFn else { return false }
        let clamped = min(max(value, 0), 1)
        return writeQueue.sync { fn(display, clamped) == 0 }
    }

    // MARK: - Capability probes

    /// The most trustworthy capability gate DisplayServices offers.
    static func canChangeBrightness(_ display: CGDirectDisplayID) -> Bool {
        canChangeBrightnessFn?(display) ?? false
    }

    /// True for Studio-Display-class panels whose brightness rides the
    /// USB/Thunderbolt control channel rather than the video link.
    static func isSmartDisplay(_ display: CGDirectDisplayID) -> Bool {
        isSmartDisplayFn?(display) ?? false
    }

    static func isBuiltInDisplay(_ display: CGDirectDisplayID) -> Bool {
        isBuiltInDisplayFn?(display) ?? false
    }

    static func needsBrightnessSmoothing(_ display: CGDirectDisplayID) -> Bool {
        needsSmoothingFn?(display) ?? false
    }

    static func linearBrightnessRange(for display: CGDirectDisplayID) -> (min: Float, max: Float)? {
        guard let fn = getLinearRangeFn else { return nil }
        var lo: Float = 0
        var hi: Float = 0
        guard fn(display, &lo, &hi) == 0 else { return nil }
        return (lo, hi)
    }

    // MARK: - Ambient light compensation
    //
    // macOS's own ALC runs in corebrightnessd and will re-drive brightness after
    // our write, on the built-in panel and on Studio Display (which has its own
    // ALS). Symptom: our value sticks for a second, then drifts back. We disable
    // it while managing a display, and restore the user's original setting on
    // teardown.

    static func hasAmbientLightCompensation(_ display: CGDirectDisplayID) -> Bool {
        hasALCFn?(display) ?? false
    }

    /// Current ALC state, or nil if unsupported / the query failed.
    static func ambientLightCompensationEnabled(_ display: CGDirectDisplayID) -> Bool? {
        guard hasAmbientLightCompensation(display), let fn = alcEnabledFn else { return nil }
        var enabled = false
        guard fn(display, &enabled) == 0 else { return nil }
        return enabled
    }

    @discardableResult
    static func setAmbientLightCompensation(_ enabled: Bool, for display: CGDirectDisplayID) -> Bool {
        guard hasAmbientLightCompensation(display), let fn = enableALCFn else { return false }
        return fn(display, enabled) == 0
    }
}
