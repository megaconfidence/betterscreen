import AppKit

/// Entry point.
///
/// `@main` on a type requires that the module contain no top-level statements
/// anywhere, so this file must hold nothing but the declaration.
@main
struct BetterScreenApp {
    static func main() {
        // Diagnostics are launched via `open`, so stdout is a file rather than a
        // terminal and therefore block-buffered. Without this, output only appears
        // when the 4KB buffer fills -- and is lost entirely on a crash.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)

        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }

        if CommandLine.arguments.contains("--test-ddc") {
            Diagnostics.testDisplayControl()
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--set-brightness") {
            let next = CommandLine.arguments.indices.contains(index + 1)
                ? Double(CommandLine.arguments[index + 1])
                : nil
            guard let percent = next else {
                print("Usage: --set-brightness <0-100>")
                return
            }
            Diagnostics.setBrightness(percent: percent)
            return
        }

        // The self-test needs the camera, so it must run inside the app bundle with
        // a live run loop rather than as a plain CLI invocation.
        if CommandLine.arguments.contains("--snapshot") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let snapshot = CameraSnapshot()
            DispatchQueue.main.async { snapshot.run() }
            app.run()
            return
        }

        if CommandLine.arguments.contains("--test-sensor") || CommandLine.arguments.contains("--watch-light") {
            let watching = CommandLine.arguments.contains("--watch-light")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let test = SensorSelfTest()
            DispatchQueue.main.async {
                if watching { test.watch() } else { test.run() }
            }
            app.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory rather than .regular: no Dock icon, no Cmd-Tab entry. Raised
        // to .regular temporarily while the settings window is open so it can take
        // keyboard focus.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("BetterScreen starting")

        DisplayManager.shared.start()
        menuBar = MenuBarController()
        BrightnessController.shared.start()

        if AmbientLightSensor.authorizationStatus == .notDetermined {
            Log.app.info("Requesting camera access")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("BetterScreen shutting down")
        BrightnessController.shared.stop()
        // Put back anything global we changed -- notably the system's own ambient
        // light compensation, which we disable while managing a display.
        DisplayManager.shared.shutdown()
        SettingsStore.shared.saveNow()
    }
}
