import Foundation
import OSLog

/// Logging subsystems.
///
/// Watch with:
///   /usr/bin/log stream --style compact --level debug --predicate 'subsystem == "com.betterscreen.app"'
///
/// Note `log` is a zsh builtin -- the absolute path is required. Interpolations
/// are marked `.public` because os_log redacts arguments by default, which would
/// render every diagnostic as `<private>`.
enum Log {
    private static let subsystem = "com.betterscreen.app"

    static let display = Logger(subsystem: subsystem, category: "display")
    static let ddc = Logger(subsystem: subsystem, category: "ddc")
    static let ambient = Logger(subsystem: subsystem, category: "ambient")
    static let control = Logger(subsystem: subsystem, category: "control")
    static let app = Logger(subsystem: subsystem, category: "app")
}

// Convenience wrappers so call sites do not have to repeat the privacy
// annotation on every interpolation.
extension Logger {
    func debug(_ message: String) { self.log(level: .debug, "\(message, privacy: .public)") }
    func info(_ message: String) { self.log(level: .info, "\(message, privacy: .public)") }
    func notice(_ message: String) { self.log(level: .default, "\(message, privacy: .public)") }
    func warning(_ message: String) { self.log(level: .error, "WARN \(message, privacy: .public)") }
    func error(_ message: String) { self.log(level: .error, "\(message, privacy: .public)") }
}
