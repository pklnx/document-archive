import Foundation

/// Runs Apple Vision requests one at a time, process-wide (#60).
///
/// Vision's text recognition crashed (SIGSEGV) when several requests ran at once: each loads and
/// unloads the shared recognizer models, and one thread unloaded the detector while another used
/// it. Imports start one processing task per document and `resumePendingProcessing` restarts all
/// unfinished documents at launch, so several recognitions overlapped. Every Vision `perform` in
/// the app goes through `run`: `TextLayer.recognize` (the document text and the text layer, so
/// every import path) and `ImageCleanup.detectPage`. Mistral OCR is a network request and does
/// not need the gate.
///
/// The gate holds one request (one page), not a whole document, so documents processed at the
/// same time take turns page by page, in the order they asked (`AsyncSemaphore` is FIFO).
/// Waiting is an `await` on the processing task, which runs detached; nothing blocks the main
/// actor.
enum VisionGate {
    /// The kinds of Vision requests the app makes.
    enum Request: String, Sendable {
        case recognizeText
        case detectDocumentSegmentation
        case detectRectangles
    }

    /// What `ProcessingEnvironment.visionHook` receives, both while the request holds the gate.
    enum Event: Equatable, Sendable {
        case began(Request)
        case ended(Request)
    }

    typealias Hook = @Sendable (Event) -> Void

    /// One slot for the whole process.
    static let semaphore = AsyncSemaphore(limit: 1)

    /// Runs `body`, which performs one Vision request, once no other request runs.
    /// - Parameter environment: The caller's environment; its `visionHook` (tests) sees the request.
    /// - Throws: `CancellationError` when the task is cancelled while it waits (then `body` does
    ///   not run), or what `body` throws.
    static func run<T>(_ request: Request, environment: ProcessingEnvironment,
                       isolation: isolated (any Actor)? = #isolation,
                       _ body: () async throws -> T) async throws -> T {
        try await semaphore.withPermit(isolation: isolation) {
            environment.visionHook?(.began(request))
            defer { environment.visionHook?(.ended(request)) }
            return try await body()
        }
    }
}
