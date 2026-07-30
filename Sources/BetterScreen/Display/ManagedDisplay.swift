import CDisplayBridge
import CoreGraphics
import Foundation

/// How a display's brightness is driven.
enum DisplayKind: String, Codable {
    /// Built-in MacBook / iMac panel, via DisplayServices.
    case builtIn
    /// Studio Display, Studio Display XDR, Pro Display XDR -- also DisplayServices,
    /// but over the USB/Thunderbolt control channel rather than the video link.
    case appleExternal
    /// Third-party monitor, via DDC/CI over I2C.
    case ddc
    /// Online but not controllable by any available mechanism.
    case unsupported

    var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .appleExternal: "Apple display"
        case .ddc: "DDC/CI"
        case .unsupported: "Unsupported"
        }
    }
}

/// A display the app can drive, plus its cached state.
final class ManagedDisplay {
    let displayID: CGDirectDisplayID
    let persistentKey: String
    let name: String
    let kind: DisplayKind

    /// Present only for `.ddc` displays.
    private let avService: IOAVService?

    /// VCP 0x10 maximum. Usually 100, but not guaranteed -- read once at startup
    /// where possible rather than hardcoded.
    private(set) var ddcMaxValue: UInt16 = 100

    /// The app's own view of brightness, 0...1.
    ///
    /// This is deliberately the source of truth. DDC reads succeed only ~88% of
    /// the time even with retries, and can return stale values that pass the
    /// checksum, so polling the panel would be worse than remembering.
    private(set) var currentBrightness: Float = -1

    /// The user's ALC setting before we touched it, so we can put it back.
    private var originalALCState: Bool?

    init(displayID: CGDirectDisplayID, kind: DisplayKind, avService: IOAVService?) {
        self.displayID = displayID
        self.kind = kind
        self.avService = avService
        persistentKey = DisplayInfo.persistentKey(for: displayID)
        name = DisplayInfo.productName(for: displayID) ?? "Display \(displayID)"
    }

    var isControllable: Bool {
        switch kind {
        case .builtIn, .appleExternal: true
        case .ddc: avService != nil
        case .unsupported: false
        }
    }

    // MARK: - Lifecycle

    /// Reads the panel's current brightness once, and suppresses macOS's own
    /// ambient light compensation so it does not fight our writes.
    func prepare() {
        if let existing = readBrightness() {
            currentBrightness = existing
        }

        if kind == .builtIn || kind == .appleExternal {
            // corebrightnessd's ALC will re-drive brightness a second after our
            // write, making the value appear to drift back.
            if let state = DisplayServicesSPI.ambientLightCompensationEnabled(displayID) {
                originalALCState = state
                if state {
                    DisplayServicesSPI.setAmbientLightCompensation(false, for: displayID)
                    Log.display.info("Disabled system ambient light compensation for \(self.name)")
                }
            }
        }
    }

    /// Restores anything we changed globally. Called on quit and when a display
    /// stops being managed.
    func restoreSystemState() {
        if let original = originalALCState, original {
            DisplayServicesSPI.setAmbientLightCompensation(true, for: displayID)
            originalALCState = nil
        }
    }

    // MARK: - Brightness

    /// Sets brightness, 0...1. Returns false if the write could not be issued.
    ///
    /// No-ops when the value is unchanged: coalescing matters for DDC, where each
    /// transaction costs ~3 ms of serialised I2C time.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        let clamped = min(max(value, 0), 1)

        switch kind {
        case .builtIn, .appleExternal:
            guard abs(clamped - currentBrightness) > 0.001 else { return true }
            let ok = DisplayServicesSPI.setBrightness(clamped, for: displayID)
            if ok { currentBrightness = clamped }
            return ok

        case .ddc:
            guard let service = avService else { return false }
            // Quantise to the panel's own step size before comparing, so we do not
            // emit a transaction for a change the monitor cannot represent.
            let raw = UInt16((clamped * Float(ddcMaxValue)).rounded())
            let currentRaw = currentBrightness < 0 ? UInt16.max : UInt16((currentBrightness * Float(ddcMaxValue)).rounded())
            guard raw != currentRaw else { return true }

            let ok = DDCTransport.shared.setVCP(.brightness, value: raw, service: service, displayID: displayID)
            if ok { currentBrightness = Float(raw) / Float(ddcMaxValue) }
            return ok

        case .unsupported:
            return false
        }
    }

    /// Reads brightness from the hardware. Expensive and unreliable for DDC;
    /// used at startup and on explicit user request only.
    func readBrightness() -> Float? {
        switch kind {
        case .builtIn, .appleExternal:
            return DisplayServicesSPI.brightness(for: displayID)

        case .ddc:
            guard let service = avService,
                  let reply = DDCTransport.shared.getVCP(.brightness, service: service, displayID: displayID)
            else { return nil }
            ddcMaxValue = reply.max
            return Float(reply.current) / Float(reply.max)

        case .unsupported:
            return nil
        }
    }

    // MARK: - Classification

    /// Decides how a display should be driven.
    ///
    /// Dispatch is on *capability*, never on brand. Since macOS 15 some
    /// third-party displays answer DisplayServices, so a vendor-ID check would be
    /// wrong; and hardcoding Apple product IDs breaks the day Apple ships new
    /// hardware (0xae42/0xae43 for the Studio Display XDR are the proof).
    static func classify(_ display: CGDirectDisplayID) -> DisplayKind {
        guard CGDisplayIsOnline(display) != 0 else { return .unsupported }

        let isBuiltIn = CGDisplayIsBuiltin(display) != 0

        // A sleeping panel makes DisplayServices report failure for reasons that
        // have nothing to do with capability, so do not let that poison the
        // classification -- trust the builtin flag instead.
        if CGDisplayIsAsleep(display) != 0 {
            return isBuiltIn ? .builtIn : .ddc
        }

        // macOS 15 SDR-peak guard: a third-party display in HDR mode answers
        // DisplayServices but only drives a software remap, not the backlight.
        if DisplayInfo.isThirdPartyHDRActive(display) {
            return isBuiltIn ? .builtIn : .ddc
        }

        // The real probe: does DisplayServices actually report a brightness?
        if DisplayServicesSPI.brightness(for: display) != nil {
            return isBuiltIn ? .builtIn : .appleExternal
        }

        return isBuiltIn ? .builtIn : .ddc
    }
}
