import AppKit

/// The status item and its menu.
///
/// Built on `NSStatusItem` rather than SwiftUI's `MenuBarExtra` because
/// `MenuBarExtra` exposes no handle on the underlying status item, which rules out
/// distinguishing clicks, attaching custom views, or restyling the button
/// imperatively. `MenuBarExtra` is an `NSStatusItem` internally anyway.
@MainActor
final class MenuBarController: NSObject {
    static var shared: MenuBarController?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var sliderRows: [String: BrightnessSliderRow] = [:]
    private var settingsWindowController: SettingsWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = Self.symbolImage(named: "sun.max")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "BetterScreen"

        menu.delegate = self
        statusItem.menu = menu
        MenuBarController.shared = self
        rebuildMenu()
    }

    private static func symbolImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "BetterScreen")
        return image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    // MARK: - Refresh

    /// Updates the parts of the menu that change continuously. Cheap enough to
    /// call on every ambient reading.
    func refresh() {
        updateStatusIcon()
        guard menu.numberOfItems > 0 else { return }
        updateStatusHeader()
        for display in DisplayManager.shared.displays {
            sliderRows[display.persistentKey]?.value = Double(display.currentBrightness)
        }
    }

    private func updateStatusIcon() {
        let controller = BrightnessController.shared
        let enabled = SettingsStore.shared.settings.isAutoBrightnessEnabled

        let symbol: String
        if !enabled {
            symbol = "sun.max.trianglebadge.exclamationmark"
        } else if controller.lastError != nil {
            symbol = "exclamationmark.triangle"
        } else if controller.isPaused {
            symbol = "pause.circle"
        } else if let reading = controller.latestReading {
            // Rough visual feedback relative to the anchor light level.
            symbol = reading.stops < -1.5 ? "sun.min" : (reading.stops < 1.5 ? "sun.max" : "sun.max.fill")
        } else {
            symbol = "sun.max"
        }

        statusItem.button?.image = Self.symbolImage(named: symbol)
        statusItem.button?.image?.isTemplate = true
    }

    private var statusHeaderItem: NSMenuItem?

    private func updateStatusHeader() {
        guard let item = statusHeaderItem else { return }
        item.title = statusDescription()
    }

    private func statusDescription() -> String {
        let controller = BrightnessController.shared

        if let error = controller.lastError {
            return error.description
        }
        if !SettingsStore.shared.settings.isAutoBrightnessEnabled {
            return "Auto brightness off"
        }
        if controller.isPaused {
            return "Paused — \(controller.pauseReason ?? "inactive")"
        }
        guard let reading = controller.latestReading else {
            return "Measuring ambient light…"
        }

        let description = Self.describeLightLevel(reading.stops)
        let suffix = reading.isReliable ? "" : " · out of range"
        return String(format: "%@ · %+.1f stops%@", description, reading.stops, suffix)
    }

    /// Human-readable description of light relative to the anchor level.
    ///
    /// The reading is relative, so the wording is comparative rather than absolute
    /// -- claiming "Daylight" from a relative measurement would be dishonest.
    static func describeLightLevel(_ stops: Double) -> String {
        switch stops {
        case ..<(-3): "Much darker than usual"
        case ..<(-1): "Darker than usual"
        case ..<(-0.35): "Slightly dimmer"
        case ..<0.35: "Usual light level"
        case ..<1: "Slightly brighter"
        case ..<3: "Brighter than usual"
        default: "Much brighter than usual"
        }
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        menu.removeAllItems()
        sliderRows.removeAll()

        let header = NSMenuItem(title: statusDescription(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusHeaderItem = header

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "Auto Brightness",
            action: #selector(toggleAutoBrightness),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = SettingsStore.shared.settings.isAutoBrightnessEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        let displays = DisplayManager.shared.displays
        if displays.isEmpty {
            let empty = NSMenuItem(title: "No controllable displays found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in displays {
                addDisplayRow(display)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit BetterScreen", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addDisplayRow(_ display: ManagedDisplay) {
        let settings = SettingsStore.shared.settings.displays[display.persistentKey] ?? DisplaySettings()

        let row = BrightnessSliderRow(
            displayKey: display.persistentKey,
            title: display.name,
            subtitle: display.kind.displayName,
            value: Double(display.currentBrightness)
        ) { [weak self] value, isFinal in
            self?.handleSliderChange(value, isFinal: isFinal, displayKey: display.persistentKey)
        }
        row.frame.size.width = 300
        row.isEnabled = settings.isManaged

        let item = NSMenuItem()
        item.view = row
        menu.addItem(item)
        sliderRows[display.persistentKey] = row
    }

    private func handleSliderChange(_ value: Double, isFinal: Bool, displayKey: String) {
        guard let display = DisplayManager.shared.display(forKey: displayKey) else { return }
        BrightnessController.shared.setBrightnessManually(value, for: display)

        // Learn only from the settled value, not from every frame of the drag.
        if isFinal {
            BrightnessController.shared.recordPreference(brightness: value, display: display)
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoBrightness() {
        let enabled = !SettingsStore.shared.settings.isAutoBrightnessEnabled
        BrightnessController.shared.setEnabled(enabled)
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // The display list can change while the menu is closed, so rebuild rather
        // than patch.
        rebuildMenu()
    }
}

private extension NSView {
    /// Dims a whole row when the display is excluded from management.
    var isEnabled: Bool {
        get { alphaValue > 0.9 }
        set { alphaValue = newValue ? 1.0 : 0.45 }
    }
}
