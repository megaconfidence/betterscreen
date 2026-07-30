import Foundation

/// Per-display configuration and learned calibration.
struct DisplaySettings: Codable, Equatable {
    var isManaged: Bool = true
    var curve = BrightnessCurve()
    /// Remembered for the UI; not authoritative.
    var lastKnownName: String = ""
}

/// Everything the app persists.
struct AppSettings: Codable, Equatable {
    var isAutoBrightnessEnabled = true

    // Camera
    var cameraUniqueID: String?
    /// Seconds between emitted readings. Frames arrive far faster and are dropped.
    var updateInterval: TimeInterval = 2.0
    /// Release the camera while the screen is locked or the display is asleep.
    /// The camera indicator goes dark whenever the app is not actually metering.
    var pauseWhenScreenLocked = true
    /// Release the camera on battery power, since continuous capture is the app's
    /// only meaningful energy cost.
    var pauseOnBattery = false

    // Control loop
    /// Seconds to ramp from the current brightness to a new target.
    var transitionDuration: TimeInterval = 2.0
    /// Minimum brightness change worth acting on, 0...1. Suppresses visible
    /// hunting when ambient light hovers between two levels.
    var changeThreshold: Double = 0.02
    /// Seconds of stable ambient light required before a new target is accepted.
    var stabilityDelay: TimeInterval = 3.0

    var launchAtLogin = false

    /// Keyed by `DisplayInfo.persistentKey`, so settings follow a physical panel
    /// across reconnects and reboots rather than a volatile CGDirectDisplayID.
    var displays: [String: DisplaySettings] = [:]

    mutating func settings(for key: String, name: String) -> DisplaySettings {
        if var existing = displays[key] {
            if existing.lastKnownName != name {
                existing.lastKnownName = name
                displays[key] = existing
            }
            return existing
        }
        var fresh = DisplaySettings()
        fresh.lastKnownName = name
        displays[key] = fresh
        return fresh
    }
}

/// Loads and saves `AppSettings` as JSON under Application Support.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var settings: AppSettings

    /// Fires after any mutation, on the main actor.
    var onChange: ((AppSettings) -> Void)?

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("BetterScreen", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.betterScreen.decode(AppSettings.self, from: data) {
            settings = decoded
            Log.app.info("Loaded settings from \(self.fileURL.path)")
        } else {
            settings = AppSettings()
            Log.app.info("Using default settings")
        }
    }

    /// Mutates settings and schedules a debounced save.
    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        onChange?(settings)
        scheduleSave()
    }

    /// Convenience for the common case of editing one display's settings.
    func updateDisplay(_ key: String, _ mutate: (inout DisplaySettings) -> Void) {
        update { settings in
            var entry = settings.displays[key] ?? DisplaySettings()
            mutate(&entry)
            settings.displays[key] = entry
        }
    }

    /// Calibration learning fires on every user adjustment, so writes are
    /// coalesced rather than hitting the disk each time.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            let data = try JSONEncoder.betterScreen.encode(settings)
            // Atomic, so a crash mid-write cannot leave a truncated file that
            // would silently reset every learned calibration.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Failed to save settings: \(error.localizedDescription)")
        }
    }
}

extension JSONEncoder {
    static var betterScreen: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var betterScreen: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
