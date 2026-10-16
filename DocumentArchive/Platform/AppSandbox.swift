import Foundation

/// Whether the app runs in the App Sandbox. iPhone and iPad apps always do. On the Mac, signed
/// builds are sandboxed (release builds, and IDE builds with a team in `Config/Local.xcconfig`);
/// unsigned development and CI builds (`CODE_SIGNING_ALLOWED=NO`) carry no entitlements and are
/// not. See docs/development/index.md, "Sandbox".
enum AppSandbox {
    static let isActive = isActive(environment: ProcessInfo.processInfo.environment)

    /// macOS sets `APP_SANDBOX_CONTAINER_ID` for every sandboxed process.
    static func isActive(environment: [String: String]) -> Bool {
        #if os(macOS)
        environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }
}
