import Foundation

/// Everything the import and analysis pipeline reads from outside: the Mistral configuration and
/// the `URLSession` for its requests, the settings, and the test hooks. The app uses `live`; a
/// test runs its body in `ProcessingEnvironment.$current.withValue(…) { … }`, so tests running
/// in parallel each see their own stub and settings. This is the only seam type: no other
/// global state is replaced by tests.
///
/// `current` is a task-local: `Task {}` inherits it, `Task.detached` does not. Code that leaves
/// the task with `Task.detached` captures `ProcessingEnvironment.current` before detaching and
/// passes it on (`DocumentImporter.processAndWait` → `DocumentProcessor.analyze`).
struct ProcessingEnvironment: Sendable {
    /// The Mistral configuration; `nil` when no API key is stored.
    var mistralConfig: @Sendable () -> MistralConfig?
    /// The session for all Mistral requests.
    var session: URLSession
    /// The `UserDefaults` suite of the per-device settings (auto-assignment); `nil` is
    /// `UserDefaults.standard`. A name and not the object, because `UserDefaults` is not `Sendable`.
    var defaultsSuite: String?
    /// The setting "Add a text layer to scans".
    var textLayerEnabled: @Sendable () -> Bool
    /// The photo cleanup settings (#20).
    var cleanupMode: @Sendable () -> CleanupMode
    var cleanupFilter: @Sendable () -> PageFilter
    /// Test hook: changes a rewritten PDF before it is verified, so tests can force a rewrite that
    /// fails the check. It receives the analyzed and the rewritten data, so a test changes only
    /// its own document. `nil` in the app.
    var rewriteHook: TextLayer.RewriteHook?
    /// Test hook: receives the PDF data before `MistralClient.ocr` encodes it. `nil` in the app.
    var encodeHook: (@Sendable (Data) -> Void)?

    /// The app's environment. Unit and UI test runs never use the stored Mistral key, never reach
    /// the network (`offlineSession`) and never read the real text layer and cleanup settings
    /// (on, Off and Color).
    static let live = ProcessingEnvironment(
        mistralConfig: { TestEnvironment.isIsolated ? nil : MistralConfig.live() },
        session: TestEnvironment.isIsolated ? offlineSession : .shared,
        defaultsSuite: nil,
        textLayerEnabled: { TestEnvironment.isRunningTests ? true : TextLayer.isEnabled(in: .standard) },
        cleanupMode: { TestEnvironment.isRunningTests ? CleanupMode.defaultSetting : CleanupMode.setting(in: .standard) },
        cleanupFilter: { TestEnvironment.isRunningTests ? CleanupMode.defaultFilter : CleanupMode.defaultFilter(in: .standard) },
        rewriteHook: nil,
        encodeHook: nil
    )

    /// The per-device settings.
    var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    @TaskLocal static var current: ProcessingEnvironment = .live

    /// The session of `live` in unit and UI test runs: every request fails at once with
    /// `URLError(.notConnectedToInternet)` and never reaches the network. A second line of
    /// defence: `live` has no Mistral configuration in these runs, so no client should be built
    /// with it; tests use `MistralStub`'s sessions.
    static let offlineSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Replaces the system's protocols, so no request can fall through to HTTP.
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }()
}

/// Fails every request without sending it (`ProcessingEnvironment.offlineSession`).
final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Should never happen: a request that would have gone to the network in a test run.
        Log.mistral.fault("Request blocked in a test run: \(self.request.url?.host() ?? "", privacy: .private)")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
