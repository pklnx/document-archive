import Foundation
import Testing
@testable import DocumentArchive

/// `Log.interval` wraps the pipeline steps in signposts without changing what they return or throw.
@Suite struct LogIntervalTests {
    private struct Failure: Error, Equatable {}

    @Test func returnsTheBodysValue() async {
        let value = await Log.interval("import") { 42 }
        #expect(value == 42)
    }

    @Test func returnsTheValueOfAnAsyncBody() async throws {
        let value = try await Log.interval("ocr") {
            try await Task.sleep(for: .milliseconds(10))
            return "done"
        }
        #expect(value == "done")
    }

    @Test func rethrowsTheBodysError() async {
        await #expect(throws: Failure()) {
            try await Log.interval("mirror") { () async throws -> Int in throw Failure() }
        }
    }

    /// The body runs in the caller's isolation, so main-actor code can be wrapped as it is.
    @Test @MainActor func runsTheBodyInTheCallersIsolation() async {
        let ran = await Log.interval("classify") { () -> Bool in
            MainActor.assertIsolated()
            return true
        }
        #expect(ran)
    }

    @Test func errorCodeHasDomainAndCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260,
                            userInfo: [NSLocalizedDescriptionKey: "“Secret.pdf” could not be opened."])
        #expect(Log.code(of: error) == "NSCocoaErrorDomain 260")
    }
}
