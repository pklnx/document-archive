import Foundation
import os

/// The app's loggers and its signposter (unified logging). Console and Instruments filter by the
/// subsystem; Settings → Diagnostics exports this launch's entries (`Diagnostics`).
///
/// **Privacy** (docs/development/index.md → Logging and diagnostics):
/// - `.public`: counts, durations, byte sizes, page counts, HTTP status, error domain and code,
///   enum states (store choice, text source, mirror outcome).
/// - `.private`: titles, file names, paths, folder names, recognized text, Mistral answers and the
///   `localizedDescription` of errors (it can contain a file name).
/// - **Never**: the API key, request headers or request bodies. `scripts/check-logging.py` fails
///   on a log call that interpolates `apiKey`, `key` or `Authorization`.
///
/// **Levels:**
/// - Everything the diagnostics export must contain is logged at `.notice` (`Logger.notice`, the
///   default level): import outcomes, text source and page counts, Mistral calls, folder copy
///   passes, the store choice and sync events.
/// - Failures are `.error`; `.fault` only for what should never happen.
/// - `.info` and `.debug` are for Console while developing only: unified logging keeps `.info`
///   only in memory and never stores `.debug`, so the export does not contain them.
enum Log {
    static let subsystem = "de.patrickklein.DocumentArchive"

    static let importing = Logger(subsystem: subsystem, category: "import")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let mistral = Logger(subsystem: subsystem, category: "mistral")
    static let mirror = Logger(subsystem: subsystem, category: "mirror")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let store = Logger(subsystem: subsystem, category: "store")

    /// Intervals for Instruments → Points of Interest: `import`, `ocr`, `classify`, `mirror`.
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// Runs `body` inside a signpost interval named `name` and returns its value; an error thrown
    /// by `body` ends the interval and is rethrown. `body` runs in the caller's isolation.
    static func interval<T>(_ name: StaticString, isolation: isolated (any Actor)? = #isolation,
                            _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// An error's domain and code, e.g. "NSCocoaErrorDomain 260": safe to log as `.public`. The
    /// `localizedDescription` is logged separately as `.private`.
    static func code(of error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// Milliseconds since `start`, for durations in log messages.
    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        return Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
