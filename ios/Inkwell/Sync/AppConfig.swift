import Foundation

enum AppConfig {
    /// Where the local backend lives. Overridable via environment variable
    /// (useful for the simulator/tests) rather than hardcoded - moving to a
    /// VPS is meant to be a config change, not a code change. 127.0.0.1
    /// reaches the Mac's own backend from the iOS Simulator directly.
    static var backendBaseURL: URL {
        let raw = ProcessInfo.processInfo.environment["INKWELL_BACKEND_URL"] ?? "http://127.0.0.1:8080"
        guard let url = URL(string: raw) else {
            fatalError("INKWELL_BACKEND_URL is not a valid URL: \(raw)")
        }
        return url
    }
}
