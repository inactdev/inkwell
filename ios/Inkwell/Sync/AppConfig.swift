import Foundation

enum AppConfig {
    /// Where the local backend lives. 127.0.0.1 reaches the Mac's own
    /// backend from the iOS Simulator directly - moving to a VPS is meant to
    /// be a config change, not a code change.
    ///
    /// `./dev.sh ios generate` bakes this worktree's own derived backend URL
    /// into Info.plist at build time (see docs/runtime-isolation.md), rather
    /// than passing it as a scheme environment variable: XCUIApplication()
    /// .launch() does not reliably inherit the scheme's environment
    /// variables, only the process that invokes it does, so a UI test's
    /// app-under-test would otherwise silently fall back to the hardcoded
    /// default below. An actual `INKWELL_BACKEND_URL` environment variable
    /// still overrides it, for pointing a running app at a different
    /// backend by hand.
    static var backendBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["INKWELL_BACKEND_URL"] {
            guard let url = URL(string: raw), url.scheme != nil else {
                fatalError("INKWELL_BACKEND_URL is not a valid URL: \(raw)")
            }
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "INKWELL_BACKEND_URL") as? String,
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "http://127.0.0.1:8080")!
    }
}
