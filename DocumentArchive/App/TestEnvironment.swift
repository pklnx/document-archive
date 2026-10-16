import Foundation

/// Detects a unit test run. The tests are hosted by the app, so the app starts with them;
/// in that case it must not open the real archive, run migrations or contact Mistral.
enum TestEnvironment {
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    /// A UI test run: the app was launched with `-UITestSeed` (DEBUG builds only). The launched
    /// app has none of the XCTest variables above, so it is detected by the launch argument.
    static let isUITestSeed = isUITestSeed(arguments: ProcessInfo.processInfo.arguments)

    static func isUITestSeed(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(StoreChoice.uiTestSeedArgument)
        #else
        false
        #endif
    }

    /// Unit or UI tests: never read the real Keychain item and never call Mistral. On a developer's
    /// Mac the ad-hoc signed UI test build would otherwise ask for access to the stored Mistral key
    /// (a system dialog that blocks the app) and show or remove it in Settings.
    static var isIsolated: Bool { isRunningTests || isUITestSeed }
}
