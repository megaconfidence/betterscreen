import AVFoundation
import ServiceManagement
import SwiftUI

/// Observable bridge between `SettingsStore` and SwiftUI.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var displays: [ManagedDisplay] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var reading: AmbientReading?
    @Published var sensorError: String?

    private var refreshTimer: Timer?

    init() {
        settings = SettingsStore.shared.settings
        reload()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveValues() }
        }
    }

    deinit { refreshTimer?.invalidate() }

    func reload() {
        displays = DisplayManager.shared.displays
        cameras = AmbientLightSensor.availableCameras()
        refreshLiveValues()
    }

    private func refreshLiveValues() {
        reading = BrightnessController.shared.latestReading
        sensorError = BrightnessController.shared.lastError?.description
        displays = DisplayManager.shared.displays
    }

    /// Writes a change through to the store and restarts the sensor if needed.
    func commit(restartSensor: Bool = false, _ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        let snapshot = settings
        SettingsStore.shared.update { $0 = snapshot }
        if restartSensor {
            BrightnessController.shared.applySettings()
        }
    }

    func commitDisplay(_ key: String, _ mutate: (inout DisplaySettings) -> Void) {
        var entry = settings.displays[key] ?? DisplaySettings()
        mutate(&entry)
        settings.displays[key] = entry
        let snapshot = settings
        SettingsStore.shared.update { $0 = snapshot }
        BrightnessController.shared.reapplyNow()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            commit { $0.launchAtLogin = enabled }
        } catch {
            Log.app.error("Launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            // Reflect reality rather than intent.
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            responseTab
                .tabItem { Label("Response", systemImage: "waveform.path") }
            displaysTab
                .tabItem { Label("Displays", systemImage: "display") }
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Enable auto brightness", isOn: Binding(
                    get: { model.settings.isAutoBrightnessEnabled },
                    set: { value in
                        model.commit { $0.isAutoBrightnessEnabled = value }
                        BrightnessController.shared.applySettings()
                    }
                ))

                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section("Camera") {
                Picker("Light sensor", selection: Binding(
                    get: { model.settings.cameraUniqueID ?? "" },
                    set: { value in
                        model.commit(restartSensor: true) { $0.cameraUniqueID = value.isEmpty ? nil : value }
                    }
                )) {
                    Text("Automatic").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { camera in
                        Text(camera.localizedName + (AmbientLightSensor.supportsExposureLock(camera) ? "" : " — unsupported"))
                            .tag(camera.uniqueID)
                    }
                }

                Toggle("Release camera when screen is locked or asleep", isOn: Binding(
                    get: { model.settings.pauseWhenScreenLocked },
                    set: { value in model.commit(restartSensor: true) { $0.pauseWhenScreenLocked = value } }
                ))

                Toggle("Release camera on battery power", isOn: Binding(
                    get: { model.settings.pauseOnBattery },
                    set: { value in model.commit(restartSensor: true) { $0.pauseOnBattery = value } }
                ))

                Text(cameraExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Current reading") {
                liveReadout
            }
        }
        .formStyle(.grouped)
    }

    private var cameraExplanation: String {
        """
        The camera runs at its lowest resolution and only the overall brightness of \
        each frame is measured — images are never stored or sent anywhere. Its \
        indicator light stays on while measuring, because macOS gives no way to read \
        exposure without holding the camera open.
        """
    }

    @ViewBuilder private var liveReadout: some View {
        if let error = model.sensorError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if AmbientLightSensor.authorizationStatus == .denied {
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else if let reading = model.reading {
            LabeledContent("Light level", value: MenuBarController.describeLightLevel(reading.stops))
            LabeledContent("Relative to anchor", value: String(format: "%.2f× (%+.2f stops)", reading.relativeLight, reading.stops))
            LabeledContent("Exposure", value: reading.exposureLocked
                ? String(format: "locked, gain ×%.3f", reading.gainFactor)
                : "settling…")
            if let camera = BrightnessController.shared.activeCameraName {
                LabeledContent("Camera", value: camera)
            }
            if !reading.isReliable {
                Label("Out of measuring range — not used for calibration", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Waiting for the first measurement…").foregroundStyle(.secondary)
        }
    }

    // MARK: - Response

    private var responseTab: some View {
        Form {
            Section {
                LabeledContent("Transition") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.settings.transitionDuration },
                            set: { value in model.commit { $0.transitionDuration = value } }
                        ), in: 0 ... 10, step: 0.5)
                        Text(String(format: "%.1fs", model.settings.transitionDuration))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("How long brightness takes to reach a new level. Slower is less distracting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Settle time") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.settings.stabilityDelay },
                            set: { value in model.commit { $0.stabilityDelay = value } }
                        ), in: 0 ... 30, step: 1)
                        Text(String(format: "%.0fs", model.settings.stabilityDelay))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("How long the light level must hold steady before brightness follows it. Higher values ignore someone walking past the camera.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Sensitivity") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.settings.changeThreshold },
                            set: { value in model.commit { $0.changeThreshold = value } }
                        ), in: 0.005 ... 0.15, step: 0.005)
                        Text(String(format: "%.0f%%", model.settings.changeThreshold * 100))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("Smallest brightness change worth making. Raise it if brightness feels restless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Displays

    private var displaysTab: some View {
        Form {
            if model.displays.isEmpty {
                Text("No controllable displays found.").foregroundStyle(.secondary)
            }

            ForEach(model.displays, id: \.persistentKey) { display in
                displaySection(display)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func displaySection(_ display: ManagedDisplay) -> some View {
        let settings = model.settings.displays[display.persistentKey] ?? DisplaySettings()

        Section {
            Toggle("Adjust automatically", isOn: Binding(
                get: { settings.isManaged },
                set: { value in model.commitDisplay(display.persistentKey) { $0.isManaged = value } }
            ))

            LabeledContent("Minimum") {
                HStack {
                    Slider(value: Binding(
                        get: { settings.curve.minBrightness },
                        set: { value in
                            model.commitDisplay(display.persistentKey) {
                                $0.curve.minBrightness = min(value, $0.curve.maxBrightness - 0.05)
                            }
                        }
                    ), in: 0 ... 1)
                    Text("\(Int(settings.curve.minBrightness * 100))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            LabeledContent("Maximum") {
                HStack {
                    Slider(value: Binding(
                        get: { settings.curve.maxBrightness },
                        set: { value in
                            model.commitDisplay(display.persistentKey) {
                                $0.curve.maxBrightness = max(value, $0.curve.minBrightness + 0.05)
                            }
                        }
                    ), in: 0 ... 1)
                    Text("\(Int(settings.curve.maxBrightness * 100))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            HStack {
                Text("Learned adjustments")
                Spacer()
                Text("\(settings.curve.calibrations.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Reset") {
                    model.commitDisplay(display.persistentKey) { $0.curve.resetCalibration() }
                }
                .disabled(settings.curve.calibrations.isEmpty)
            }

            Text("Drag a display's slider in the menu bar to teach it your preference for the current light level.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text(display.name)
                Text(display.kind.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

/// Hosts `SettingsView` in a plain window.
///
/// The app is `LSUIElement`, so it has no Dock icon and no menu bar of its own.
/// Activation policy is therefore raised to `.regular` while the window is open,
/// otherwise the window cannot take keyboard focus, and dropped again on close.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "BetterScreen Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        model.reload()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
