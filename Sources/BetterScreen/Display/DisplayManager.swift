import AppKit
import CoreGraphics
import Foundation

/// Owns the set of controllable displays and keeps it in sync with the hardware.
///
/// `IOAVService` handles go stale on hotplug and across sleep/wake, so the whole
/// match is rebuilt on every reconfiguration rather than patched incrementally.
@MainActor
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [ManagedDisplay] = []

    /// Fired after `displays` changes, on the main actor.
    var onDisplaysChanged: (() -> Void)?

    /// Monotonic generation counter. A debounced rescan that finds its generation
    /// stale simply drops itself, which discards the burst of callbacks macOS
    /// emits during a single physical reconfiguration.
    private var generation = 0

    /// While true, all brightness writes are suppressed: the AV services may be
    /// pointing at ports that no longer exist.
    private(set) var isReconfiguring = false

    /// macOS fires several reconfiguration callbacks per physical change.
    private let debounceInterval: TimeInterval = 1.0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // Ignore purely cosmetic notifications; anything topology-related counts.
            let interesting: CGDisplayChangeSummaryFlags = [
                .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
                .movedFlag, .setModeFlag, .desktopShapeChangedFlag,
            ]
            guard !flags.intersection(interesting).isEmpty else { return }
            Task { @MainActor in DisplayManager.shared.scheduleRescan() }
        }, nil)

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in DisplayManager.shared.scheduleRescan() }
        }

        rescan()
    }

    func shutdown() {
        for display in displays { display.restoreSystemState() }
    }

    // MARK: - Scanning

    private func scheduleRescan() {
        generation += 1
        let scheduled = generation
        isReconfiguring = true

        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            self.rescan()
        }
    }

    func rescan() {
        let online = DisplayInfo.onlineDisplays()
        Log.display.info("Rescanning: \(online.count) online display(s)")

        // Classify first, so we only pay for the IORegistry walk if some display
        // actually needs DDC.
        var kinds: [CGDirectDisplayID: DisplayKind] = [:]
        for id in online { kinds[id] = ManagedDisplay.classify(id) }

        let ddcDisplays = online.filter { kinds[$0] == .ddc }
        let services = ddcDisplays.isEmpty ? [:] : AVServiceLocator.match(displays: ddcDisplays)

        // Preserve state for displays that are still present, so we do not reset
        // brightness or lose the saved ALC state on an unrelated reconfiguration.
        let existingByKey = Dictionary(displays.map { ($0.persistentKey, $0) }, uniquingKeysWith: { first, _ in first })
        var rebuilt: [ManagedDisplay] = []

        for id in online {
            let kind = kinds[id] ?? .unsupported
            let display = ManagedDisplay(displayID: id, kind: kind, avService: services[id])

            guard display.isControllable else {
                Log.display.notice("Skipping \(display.name): no control mechanism available")
                continue
            }

            if let previous = existingByKey[display.persistentKey], previous.displayID == id {
                // Same physical panel on the same port: keep its cached state and
                // avoid a redundant hardware read.
                rebuilt.append(previous)
            } else {
                display.prepare()
                Log.display.info("Managing \(display.name) [\(kind.displayName)] brightness=\(display.currentBrightness)")
                seedCurveIfNeeded(for: display)
                rebuilt.append(display)
            }
        }

        // Release anything that disappeared.
        let survivingKeys = Set(rebuilt.map(\.persistentKey))
        for display in displays where !survivingKeys.contains(display.persistentKey) {
            Log.display.info("Releasing \(display.name)")
            display.restoreSystemState()
        }

        displays = rebuilt
        isReconfiguring = false
        onDisplaysChanged?()
    }

    /// Anchors a newly seen display's curve to the brightness it is already set to.
    ///
    /// Without this the curve keeps its built-in default anchor, so the first
    /// reading yanks the display to roughly 55% no matter what the user had chosen.
    /// The reference light level should mean "the brightness you were already
    /// happy with", which makes the first adjustment a no-op and lets calibration
    /// refine from there.
    private func seedCurveIfNeeded(for display: ManagedDisplay) {
        let key = display.persistentKey
        guard SettingsStore.shared.settings.displays[key] == nil else { return }

        let observed = Double(display.currentBrightness)
        guard observed >= 0 else {
            // Unreadable brightness, so there is nothing trustworthy to anchor to.
            // Leave the default rather than inventing a reference point.
            Log.display.debug("\(display.name): brightness unreadable, keeping default curve anchor")
            return
        }

        var settings = DisplaySettings()
        settings.curve.anchorBrightness = min(max(observed, 0), 1)
        settings.lastKnownName = display.name

        SettingsStore.shared.update { $0.displays[key] = settings }
        Log.display.info(String(format: "%@: anchoring curve at its current %.0f%%",
                                display.name, observed * 100))
    }

    // MARK: - Lookup

    func display(forKey key: String) -> ManagedDisplay? {
        displays.first { $0.persistentKey == key }
    }
}
