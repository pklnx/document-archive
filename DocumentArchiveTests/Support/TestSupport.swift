import CoreGraphics
import CoreText
import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Suites that change global state (Mistral stub, settings source) are nested here,
/// so they run one after another and never see each other's stubs.
@Suite(.serialized) struct GlobalStateTests {}

/// The archive's tag model; plain `Tag` would clash with Swift Testing's `Tag`.
typealias ArchiveTag = DocumentArchive.Tag

enum TestSupport {
    /// A fresh in-memory archive, never synced.
    static func makeContainer() throws -> ModelContainer {
        let schema = DocumentArchiveApp.schema
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    /// A throwaway settings suite; removed by `removeDefaults`.
    static func makeDefaults() -> (UserDefaults, String) {
        let name = "DocumentArchiveTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    static func removeDefaults(_ name: String) {
        UserDefaults().removePersistentDomain(forName: name)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DocumentArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A random string that looks like an API key; never a real credential.
    static func fakeKey(length: Int = 32) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    static func components(of date: Date?) -> DateComponents? {
        date.map { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) }
    }

    /// Renders lines of text onto a white A4-like page, like a scanned letter.
    static func renderPage(lines: [String], width: Int = 1240, height: Int = 1754) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 120, y: height - 200 - index * 70)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }

    static func samplePDF(lines: [String] = ["Test"]) -> Data {
        PDFBuilder.makePDF(from: [renderPage(lines: lines)])!
    }

    /// Waits until background processing (thumbnail, OCR, auto-assignment) has finished.
    @MainActor
    /// The timeout is generous because text recognition on the hosted CI runners is slow; it
    /// only matters when processing really hangs.
    static func waitUntilProcessed(_ documents: [Document], timeout: Duration = .seconds(180)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while documents.contains(where: { $0.isAlive && $0.isProcessing }) {
            guard clock.now < deadline else {
                Issue.record("Processing did not finish within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Answers requests to api.mistral.ai locally; no request leaves the machine.
final class MistralStub: URLProtocol {
    struct Response {
        var status: Int
        var body: Data

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }

        /// A chat completion whose message content is the given JSON object.
        static func chat(_ content: [String: Any]) -> Response {
            let text = String(data: try! JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
            return .json(["choices": [["message": ["content": text]]]])
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest, Data) -> Response)?
    nonisolated(unsafe) private static var _requests: [(request: URLRequest, body: Data)] = []
    nonisolated(unsafe) static var delay: TimeInterval = 0

    static var requests: [(request: URLRequest, body: Data)] { lock.withLock { _requests } }

    /// Routes `MistralClient` through this stub and makes `config` the current configuration.
    static func install(config: MistralConfig?, handler: @escaping (URLRequest, Data) -> Response) {
        lock.withLock {
            _handler = handler
            _requests = []
        }
        delay = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MistralStub.self]
        MistralClient.session = URLSession(configuration: configuration)
        MistralConfig.provider = { config }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
        }
        delay = 0
        MistralClient.session = .shared
        MistralConfig.provider = { nil }
    }

    static func config(useOCR: Bool = true, useLLM: Bool = true) -> MistralConfig {
        MistralConfig(apiKey: "test-key", ocrModel: MistralConfig.defaultOCRModel,
                      chatModel: MistralConfig.defaultChatModel, useOCR: useOCR, useLLM: useLLM)
    }

    /// The JSON body of a recorded request.
    static func json(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.mistral.ai" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        let handler = Self.lock.withLock { () -> ((URLRequest, Data) -> Response)? in
            Self._requests.append((request, body))
            return Self._handler
        }
        let response = handler?(request, body) ?? Response(status: 500, body: Data("no stub".utf8))
        let respond = { [request = self.request, client = self.client] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status,
                                                                  httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
