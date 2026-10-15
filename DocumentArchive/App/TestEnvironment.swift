import Foundation

/// Detects a unit test run. The tests are hosted by the app, so the app starts with them;
/// in that case it must not open the real archive, run migrations or contact Mistral.
enum TestEnvironment {
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()
}
