import CDisplayBridge
import CoreGraphics
import Foundation

/// Read-only metadata about a display, from CoreGraphics and CoreDisplay.
enum DisplayInfo {
    /// EDID PnP vendor ID for Apple.
    ///
    /// Note this is 0x0610 (1552) -- "APP" packed as three 5-bit letters -- and is
    /// *not* Apple's USB vendor ID 0x05AC. `CGDisplayVendorNumber` returns the
    /// EDID PnP ID. Apple's own override tree confirms it: the directory is
    /// `.../Overrides/DisplayVendorID-610`, and no `-5ac` directory exists.
    static let appleVendorID: UInt32 = 1552

    /// Full CoreDisplay info dictionary, or nil for virtual displays.
    static func infoDictionary(for display: CGDirectDisplayID) -> [String: Any]? {
        // Create Rule (+1) -- must takeRetainedValue or we leak on every poll.
        guard let unmanaged = CoreDisplay_DisplayCreateInfoDictionary(display) else { return nil }
        return unmanaged.takeRetainedValue() as? [String: Any]
    }

    /// IOService path of the display's framebuffer. The pairing key for DDC.
    static func ioDisplayLocation(for display: CGDirectDisplayID) -> String? {
        infoDictionary(for: display)?["IODisplayLocation"] as? String
    }

    /// Localised product name from EDID, e.g. "DELL P2723QE".
    static func productName(for display: CGDirectDisplayID) -> String? {
        guard let names = infoDictionary(for: display)?["DisplayProductName"] as? [String: String] else {
            return nil
        }
        // Prefer the user's locale, then en_US, then anything.
        for language in Locale.preferredLanguages {
            if let name = names[language] { return name }
        }
        return names["en_US"] ?? names.values.first
    }

    /// A stable identity for persisting per-display settings across reboots and
    /// reconnects. `CGDirectDisplayID` is not stable, so it must not be used.
    static func persistentKey(for display: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)

        // Serial is 0 on some panels; fall back to the EDID UUID, then to the
        // physical port path, which at least survives reboots for a fixed setup.
        if serial != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }
        if let info = infoDictionary(for: display), let uuid = info["kCGDisplayUUID"] as? String {
            return "\(vendor)-\(model)-\(uuid)"
        }
        if let location = ioDisplayLocation(for: display) {
            return "\(vendor)-\(model)-\(location.hashValue)"
        }
        return "\(vendor)-\(model)-\(display)"
    }

    /// Filters out AirPlay/Sidecar targets, virtual screens and HDMI dummy plugs.
    /// Dummy plugs in particular advertise DDC support and then hang.
    static func isVirtualOrDummy(_ display: CGDirectDisplayID) -> Bool {
        guard let info = infoDictionary(for: display) else {
            // No info dictionary at all is itself the signature of a virtual display.
            return true
        }
        if let virtual = info["kCGDisplayIsVirtualDevice"] as? Bool, virtual { return true }
        if let airplay = info["kCGDisplayIsAirPlay"] as? Bool, airplay { return true }
        if CGDisplayVendorNumber(display) == 0xF0F0 { return true }
        if let name = productName(for: display)?.lowercased(),
           name.contains("dummy") || name.contains("airplay") || name.contains("sidecar") {
            return true
        }
        return false
    }

    /// Resolves mirrored displays to the one that actually owns the panel.
    /// Without this we would set brightness on the wrong display in a mirror set.
    static func resolveEffectiveDisplayID(_ display: CGDirectDisplayID) -> CGDirectDisplayID {
        if CGDisplayIsInHWMirrorSet(display) != 0 || CGDisplayIsInMirrorSet(display) != 0 {
            let primary = CGDisplayMirrorsDisplay(display)
            if primary != 0 { return primary }
        }
        return display
    }

    /// All online displays worth considering, mirror-resolved and de-duplicated.
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        var seen = Set<CGDirectDisplayID>()
        var result: [CGDirectDisplayID] = []
        for id in ids.prefix(Int(count)) {
            let effective = resolveEffectiveDisplayID(id)
            guard CGDisplayIsOnline(effective) != 0, !isVirtualOrDummy(effective) else { continue }
            if seen.insert(effective).inserted { result.append(effective) }
        }
        return result
    }

    /// True when the display is in HDR mode and is not Apple's.
    ///
    /// macOS 15 added an "SDR peak brightness" remap for third-party HDR displays,
    /// and as a side effect DisplayServices now *succeeds* for them -- while
    /// driving that software remap rather than the backlight. Treating such a
    /// display as an Apple display would wrongly disable DDC, which is exactly the
    /// Sequoia regression MonitorControl had to patch.
    static func isThirdPartyHDRActive(_ display: CGDirectDisplayID) -> Bool {
        guard CGDisplayVendorNumber(display) != appleVendorID else { return false }
        return CoreGraphicsSPI.isHDRSupported(display) && CoreGraphicsSPI.isHDREnabled(display)
    }
}
