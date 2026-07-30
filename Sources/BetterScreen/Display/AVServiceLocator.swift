import CDisplayBridge
import CoreGraphics
import Foundation
import IOKit

/// One external display port, as seen in the IORegistry.
struct AVServicePort {
    /// IOService path of the framebuffer, e.g.
    /// `IOService:/AppleARMPE/arm-io@10F00000/AppleH15IO/dispext0@C0000000/IOMobileFramebufferShim`
    ///
    /// This is the authoritative pairing key: it is unique per physical port, so
    /// two identical monitors are disambiguated with no heuristics at all.
    let framebufferPath: String
    let index: Int

    var edidUUID: String?
    var productName: String?
    var vendorID: Int?
    var productID: Int?
    var serialNumber: Int?

    /// nil when the port has no external `DCPAVServiceProxy` -- which is the case
    /// for the built-in panel.
    var service: IOAVService?
}

/// Maps `CGDirectDisplayID`s to `IOAVService`s by walking the IOService plane.
///
/// The tree on Apple Silicon looks like:
///
///     dispext0@C0000000                     <- external port
///       IOMobileFramebufferShim             <- framebuffer  (was AppleCLCD2 on macOS 11/12)
///         dispext0:dcpav-service-epic:0
///           DCPAVServiceProxy               <- Location == "External"; this is the one
///     disp0@7C000000                        <- built-in panel
///       IOMobileFramebufferShim
///         (no DCPAVServiceProxy anywhere beneath)
///
/// The built-in display is therefore excluded structurally, and additionally by
/// the `Location != "External"` check for Macs that do expose an embedded proxy.
enum AVServiceLocator {
    /// Framebuffer class names across macOS versions. Matching only `AppleCLCD2`
    /// silently finds nothing on macOS 13+; matching only the newer name breaks
    /// on Big Sur/Monterey.
    private static let framebufferNames = ["AppleCLCD2", "IOMobileFramebufferShim"]
    private static let proxyName = "DCPAVServiceProxy"

    // MARK: - Enumeration

    /// Single recursive walk of the IOService plane, grouping each framebuffer
    /// with the AV service proxy that follows it in depth-first order.
    static func enumeratePorts() -> [AVServicePort] {
        var ports: [AVServicePort] = []

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != MACH_PORT_NULL else { return ports }
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return ports }
        defer { IOObjectRelease(iterator) }

        var index = 0
        while case let entry = IOIteratorNext(iterator), entry != MACH_PORT_NULL {
            defer { IOObjectRelease(entry) }
            guard let name = entryName(entry) else { continue }

            if framebufferNames.contains(name) {
                index += 1
                guard let path = entryPath(entry) else { continue }
                var port = AVServicePort(framebufferPath: path, index: index)
                readFramebufferProperties(entry, into: &port)
                ports.append(port)
            } else if name == proxyName, !ports.isEmpty {
                // Depth-first order guarantees this proxy belongs to the most
                // recently seen framebuffer.
                attachService(entry, to: &ports[ports.count - 1])
            }
        }

        return ports
    }

    /// Resolves an `IOAVService` for each supplied display ID.
    ///
    /// Primary signal is an exact `IODisplayLocation` path match. EDID/product
    /// attributes are only used as a fallback, and a zero-scoring candidate is
    /// never matched -- failing is better than driving the wrong panel.
    static func match(displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: IOAVService] {
        let ports = enumeratePorts().filter { $0.service != nil }
        guard !ports.isEmpty else { return [:] }

        var result: [CGDirectDisplayID: IOAVService] = [:]
        var claimedPortIndices = Set<Int>()
        var unmatched: [CGDirectDisplayID] = []

        // Pass 1: exact IOService path match.
        for display in displays {
            guard let location = DisplayInfo.ioDisplayLocation(for: display) else {
                unmatched.append(display)
                continue
            }
            if let port = ports.first(where: { $0.framebufferPath == location && !claimedPortIndices.contains($0.index) }) {
                result[display] = port.service
                claimedPortIndices.insert(port.index)
                Log.display.debug("Matched display \(display) to \(port.framebufferPath) by IODisplayLocation")
            } else {
                unmatched.append(display)
            }
        }

        // Pass 2: score remaining candidates on EDID/product attributes, then
        // assign greedily best-first with mutual exclusion.
        guard !unmatched.isEmpty else { return result }

        var candidates: [(score: Int, display: CGDirectDisplayID, portIndex: Int, service: IOAVService)] = []
        for display in unmatched {
            for port in ports where !claimedPortIndices.contains(port.index) {
                let score = matchScore(display: display, port: port)
                if score > 0, let service = port.service {
                    candidates.append((score, display, port.index, service))
                }
            }
        }

        var claimedDisplays = Set<CGDirectDisplayID>()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard !claimedDisplays.contains(candidate.display),
                  !claimedPortIndices.contains(candidate.portIndex) else { continue }
            result[candidate.display] = candidate.service
            claimedDisplays.insert(candidate.display)
            claimedPortIndices.insert(candidate.portIndex)
            Log.display.debug("Matched display \(candidate.display) to port \(candidate.portIndex) by attributes (score \(candidate.score))")
        }

        for display in unmatched where result[display] == nil {
            Log.display.warning("No IOAVService found for display \(display); DDC unavailable")
        }

        return result
    }

    private static func matchScore(display: CGDirectDisplayID, port: AVServicePort) -> Int {
        var score = 0
        if let vendor = port.vendorID, vendor != 0, vendor == Int(CGDisplayVendorNumber(display)) { score += 1 }
        if let product = port.productID, product != 0, product == Int(CGDisplayModelNumber(display)) { score += 1 }
        if let serial = port.serialNumber, serial != 0, serial == Int(CGDisplaySerialNumber(display)) { score += 1 }
        if let name = port.productName, let displayName = DisplayInfo.productName(for: display),
           name.caseInsensitiveCompare(displayName) == .orderedSame { score += 1 }
        return score
    }

    // MARK: - IORegistry helpers

    private static func attachService(_ entry: io_service_t, to port: inout AVServicePort) {
        // "Location" distinguishes "External" from "Embedded" (the internal panel
        // on Macs that expose a proxy for it). Searched recursively because the
        // property can live on a child.
        guard let location = stringProperty(entry, "Location"), location == "External" else { return }

        // Create Rule: IOAVServiceCreateWithService returns +1, so takeRetainedValue.
        guard let unmanaged = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { return }
        port.service = unmanaged.takeRetainedValue()
    }

    private static func readFramebufferProperties(_ entry: io_service_t, into port: inout AVServicePort) {
        port.edidUUID = stringProperty(entry, "EDID UUID") ?? stringProperty(entry, "IOMFBUUID")

        guard let attributes = dictionaryProperty(entry, "DisplayAttributes"),
              let product = attributes["ProductAttributes"] as? [String: Any] else { return }

        port.productName = product["ProductName"] as? String
        port.productID = product["ProductID"] as? Int
        port.serialNumber = product["SerialNumber"] as? Int
        port.vendorID = (product["LegacyManufacturerID"] as? Int) ?? (product["ManufacturerID"] as? Int)
    }

    private static func entryName(_ entry: io_service_t) -> String? {
        // io_name_t is a fixed 128-byte buffer.
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }

    private static func entryPath(_ entry: io_service_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { return nil }
        return String(cString: path)
    }

    private static func stringProperty(_ entry: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else { return nil }
        return value as? String
    }

    private static func dictionaryProperty(_ entry: io_service_t, _ key: String) -> [String: Any]? {
        guard let value = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else { return nil }
        return value as? [String: Any]
    }
}
