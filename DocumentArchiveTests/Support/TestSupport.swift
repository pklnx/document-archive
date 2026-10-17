import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import PDFKit
import SwiftData
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import DocumentArchive

/// The archive's tag model; plain `Tag` would clash with Swift Testing's `Tag`.
typealias ArchiveTag = DocumentArchive.Tag

enum TestSupport {
    /// A fresh in-memory archive, never synced. It lives until the end of the test run
    /// (`ContainerKeeper`).
    static func makeContainer() throws -> ModelContainer {
        let schema = DocumentArchiveApp.schema
        return try keepAlive(ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ))
    }

    /// A fresh archive in a temporary folder, never synced. Only for tests of store change
    /// notifications: in-memory stores all report `/dev/null` as their URL, so the saves of tests
    /// running in parallel would count as changes of every in-memory store.
    static func makeContainerOnDisk() throws -> ModelContainer {
        try makeContainerOnDisk(at: makeTemporaryDirectory().appending(path: "Test.store"))
    }

    /// The archive in the store file at `url` (created if missing), never synced. For tests that
    /// open the same store file again. It lives until the end of the test run (`ContainerKeeper`).
    static func makeContainerOnDisk(at url: URL) throws -> ModelContainer {
        let schema = DocumentArchiveApp.schema
        return try keepAlive(ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, url: url, cloudKitDatabase: .none)))
    }

    /// Keeps a container that a test got from elsewhere (`ArchiveStore.makeContainer`) alive until
    /// the end of the test run, like the ones from `makeContainer()`.
    @discardableResult
    static func keepAlive(_ container: ModelContainer) -> ModelContainer {
        ContainerKeeper.shared.keep(container)
        return container
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

    /// A scanned document with one page per entry, built like the app's camera scans.
    static func scanPDF(pages: [[String]]) -> Data {
        PDFBuilder.makePDF(from: pages.map { renderPage(lines: $0) })!
    }

    /// A one-page scan whose image lies on its side and whose page is rotated by 90° so it shows
    /// upright, like a page turned in Preview or by a scanner.
    static func rotatedScanPDF(lines: [String]) -> Data {
        let upright = renderPage(lines: lines)
        let context = CGContext(
            data: nil, width: upright.height, height: upright.width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // Turned counterclockwise; the page's /Rotate 90 turns it clockwise again when shown.
        context.translateBy(x: CGFloat(upright.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        let sideways = PDFBuilder.makePDF(from: [context.makeImage()!])!
        return modifiedPDF(sideways) { $0.page(at: 0)?.rotation = 90 }
    }

    /// A PDF with real (selectable) text on every page, as exported by office software.
    static func textPDF(_ texts: String...) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for text in texts {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            context.textPosition = CGPoint(x: 40, y: 780)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Changes a PDF with PDFKit (rotation, crop box, annotations, …) and writes it again.
    static func modifiedPDF(_ data: Data, options: [PDFDocumentWriteOption: Any] = [:],
                            _ change: (PDFDocument) -> Void) -> Data {
        let pdf = PDFDocument(data: data)!
        change(pdf)
        return pdf.dataRepresentation(options: options)!
    }

    /// A hand-written one-page PDF (200 × 200 pt) whose page draws one image XObject, for the
    /// skip rules that PDFKit cannot produce (image filters, catalog entries).
    /// - Parameters:
    ///   - imageFilter: The image's `/Filter` value, e.g. `/JBIG2Decode`; `nil` for none.
    ///   - nestedInForm: Draws the image through a Form XObject.
    ///   - catalogExtra: Extra entries for the catalog dictionary, e.g. `/AcroForm << … >>`.
    ///   - xmp: XMP metadata, written as the catalog's `/Metadata` stream.
    static func rawImagePDF(imageFilter: String? = nil, nestedInForm: Bool = false, catalogExtra: String = "",
                            xmp: String? = nil) -> Data {
        let filter = imageFilter.map { " /Filter \($0)" } ?? ""
        let image = "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8\(filter) /Length 1 >>\nstream\n\u{80}\nendstream"
        let draw = "q 200 0 0 200 0 0 cm /Im1 Do Q"
        var objects = [
            "", // the catalog, filled in below
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        ]
        if nestedInForm {
            let formContent = "/Im1 Do"
            objects += [
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Fm1 4 0 R >> >> /Contents 5 0 R >>",
                "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /Im1 6 0 R >> >> /Length \(formContent.utf8.count) >>\nstream\n\(formContent)\nendstream",
                "<< /Length 30 >>\nstream\nq 200 0 0 200 0 0 cm /Fm1 Do Q\nendstream",
                image,
            ]
        } else {
            objects += [
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >>",
                image,
                "<< /Length \(draw.utf8.count) >>\nstream\n\(draw)\nendstream",
            ]
        }
        var catalog = "<< /Type /Catalog /Pages 2 0 R \(catalogExtra)"
        if let xmp {
            objects.append("<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream")
            catalog += " /Metadata \(objects.count) 0 R"
        }
        objects[0] = catalog + " >>"
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object.data(using: .isoLatin1)!)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(trailer.utf8))
        return pdf
    }

    /// Where `photographedPage` puts the page by default: a mild perspective, as when a letter on
    /// a desk is photographed from slightly off-center (normalized, origin lower-left).
    static let photoCorners = PageQuad(topLeft: CGPoint(x: 0.12, y: 0.90), topRight: CGPoint(x: 0.86, y: 0.93),
                                       bottomRight: CGPoint(x: 0.90, y: 0.07), bottomLeft: CGPoint(x: 0.08, y: 0.10))

    /// A photo of a rendered page (`renderPage`) lying with the given corners on a dark, textured
    /// desk. The corners are known exactly, so detection and correction can be checked.
    static func photographedPage(lines: [String], corners: PageQuad = photoCorners,
                                 width: Int = 1500, height: Int = 2000) -> CGImage {
        let size = CGSize(width: width, height: height)
        let page = CIImage(cgImage: renderPage(lines: lines))
        let transform = CIFilter(name: "CIPerspectiveTransform")!
        transform.setValue(page, forKey: kCIInputImageKey)
        func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x * size.width, y: point.y * size.height) }
        transform.setValue(vector(corners.topLeft), forKey: "inputTopLeft")
        transform.setValue(vector(corners.topRight), forKey: "inputTopRight")
        transform.setValue(vector(corners.bottomRight), forKey: "inputBottomRight")
        transform.setValue(vector(corners.bottomLeft), forKey: "inputBottomLeft")
        let photo = transform.outputImage!.composited(over: CIImage(cgImage: desk(width: width, height: height)))
        return ImageCleanup.sharedContext.createCGImage(photo, from: CGRect(origin: .zero, size: size))!
    }

    /// A dark wooden-looking surface with a fixed random pattern.
    static func desk(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.22, green: 0.16, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SeededGenerator(seed: 20)
        for _ in 0..<400 {
            let shade = Double.random(in: 0.1...0.3, using: &generator)
            context.setFillColor(CGColor(red: shade + 0.05, green: shade, blue: shade - 0.04, alpha: 1))
            context.fill(CGRect(x: Double.random(in: 0...Double(width), using: &generator),
                                y: Double.random(in: 0...Double(height), using: &generator),
                                width: Double.random(in: 20...200, using: &generator),
                                height: Double.random(in: 2...8, using: &generator)))
        }
        return context.makeImage()!
    }

    /// An image encoded as PNG, or as JPEG with an EXIF orientation.
    static func encoded(_ image: CGImage, type: UTType = .png, orientation: Int? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The image's pixels as RGBA bytes (sRGB), row 0 at the top.
    static func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The factor every test wait multiplies its timeout by: the environment variable
    /// `DA_TEST_TIMEOUT_SCALE`, 1 when it is missing or not a positive number. The nightly
    /// "Thread Sanitizer" configuration (`TestPlans/Nightly.xctestplan`) sets it to 5, because the
    /// sanitizer slows text recognition down several times.
    static let timeoutScale = timeoutScale(from: ProcessInfo.processInfo.environment)

    static func timeoutScale(from environment: [String: String]) -> Double {
        guard let value = environment["DA_TEST_TIMEOUT_SCALE"].flatMap(Double.init),
              value.isFinite, value > 0 else { return 1 }
        return value
    }

    /// A wait's timeout, scaled by `timeoutScale`. Every wait for something asynchronous uses it.
    static func scaled(_ timeout: Duration) -> Duration {
        timeout * timeoutScale
    }

    /// Waits until background processing (thumbnail, OCR, auto-assignment) has finished.
    /// The timeout is generous because text recognition on the hosted CI runners is slow; it
    /// only matters when processing really hangs. It is scaled by `timeoutScale`.
    @MainActor
    static func waitUntilProcessed(_ documents: [Document], timeout: Duration = .seconds(180)) async throws {
        let timeout = scaled(timeout)
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

/// Holds every test container until the end of the test run (#59). A main context with unsaved
/// changes has an autosave timer on the main run loop; when the container went away with the test
/// that made it, the timer fired later, during another test, and SwiftData trapped (the crash of
/// the test host under parallel tests). In the app the container lives as long as the process;
/// here it does too. Entries stay for the whole run, like `MistralStub.routes`: one store per
/// test, most of them empty or holding a few small PDFs. Tests never read it.
final class ContainerKeeper: Sendable {
    static let shared = ContainerKeeper()

    private let containers = Mutex<[ModelContainer]>([])

    func keep(_ container: ModelContainer) {
        containers.withLock { $0.append(container) }
    }
}

/// Collects values from `@Sendable` closures (stub handlers, environment hooks), which cannot
/// change a test's local variables.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
}

/// Counts the Apple Vision requests in flight through `ProcessingEnvironment.visionHook` (#60).
/// Several environments may share one probe, to check that `VisionGate` is process-wide.
final class VisionProbe: Sendable {
    struct State {
        var inFlight = 0
        var maxInFlight = 0
        var began: [VisionGate.Request] = []
        var ended = 0
        /// Requests that began on the main thread; the gate must never be entered there.
        var onMainThread = 0
    }

    private let state = Mutex(State())

    var snapshot: State { state.withLock { $0 } }

    /// `base` with a hook that reports to this probe.
    func environment(_ base: ProcessingEnvironment = .live) -> ProcessingEnvironment {
        var environment = base
        environment.visionHook = { [self] event in record(event) }
        return environment
    }

    private func record(_ event: VisionGate.Event) {
        let isMainThread = Thread.isMainThread
        state.withLock { state in
            switch event {
            case .began(let request):
                state.inFlight += 1
                state.maxInFlight = max(state.maxInFlight, state.inFlight)
                state.began.append(request)
                if isMainThread { state.onMainThread += 1 }
            case .ended:
                state.inFlight -= 1
                state.ended += 1
            }
        }
    }
}

/// A deterministic random number generator (SplitMix64), so generated images are the same in every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Answers requests to api.mistral.ai locally; no request leaves the machine.
///
/// Every `install` creates its own stub session: a fake API key (`stub-<uuid>`) in the returned
/// `config`, its own `URLSession` with this protocol, and its own handler and recorded requests.
/// A request is routed by its `Authorization: Bearer <key>` header, so stub sessions used by
/// tests running in parallel never see each other's requests. A test runs its body in
/// `ProcessingEnvironment.$current.withValue(stub.environment) { … }` or passes
/// `stub.environment` to `MistralClient` / `DocumentProcessor.analyze`.
final class MistralStub: URLProtocol {
    struct Response: Sendable {
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

    typealias Handler = @Sendable (URLRequest, Data) -> Response

    struct RecordedRequest: Sendable {
        var request: URLRequest
        var body: Data
    }

    /// The handler and the recorded requests of one stub session.
    final class Route: Sendable {
        struct State {
            var requests: [RecordedRequest] = []
            var delay: TimeInterval = 0
        }

        let handler: Handler
        let state = Mutex(State())

        init(handler: @escaping Handler) { self.handler = handler }
    }

    /// One installed stub: its configuration, its environment and what it received.
    final class Session: Sendable {
        /// The configuration passed to `install`, with this session's fake API key.
        let config: MistralConfig
        /// `.live` with this session's `URLSession` and `config`; tests change other fields as needed.
        let environment: ProcessingEnvironment
        let route: Route

        fileprivate init(config: MistralConfig, route: Route) {
            self.config = config
            self.route = route
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MistralStub.self]
            var environment = ProcessingEnvironment.live
            environment.session = URLSession(configuration: configuration)
            environment.mistralConfig = { config }
            self.environment = environment
        }

        var requests: [RecordedRequest] { route.state.withLock { $0.requests } }

        /// Seconds to wait before each answer.
        var delay: TimeInterval {
            get { route.state.withLock { $0.delay } }
            set { route.state.withLock { $0.delay = newValue } }
        }
    }

    /// Stub sessions by their fake API key. Entries stay for the whole test run (a few hundred
    /// small objects), so a request can never outlive its route.
    static let routes = Mutex<[String: Route]>([:])

    /// A new stub session answering with `handler`. `config` gives the models and switches; its
    /// API key is replaced with a unique fake one.
    static func install(config: MistralConfig = MistralStub.config(), handler: @escaping Handler) -> Session {
        var config = config
        config.apiKey = "stub-\(UUID().uuidString)"
        let route = Route(handler: handler)
        routes.withLock { $0[config.apiKey] = route }
        return Session(config: config, route: route)
    }

    /// A configuration template for `install`; its API key is never sent.
    static func config(useOCR: Bool = true, useLLM: Bool = true) -> MistralConfig {
        MistralConfig(apiKey: "template-key", ocrModel: MistralConfig.defaultOCRModel,
                      chatModel: MistralConfig.defaultChatModel, useOCR: useOCR, useLLM: useLLM)
    }

    /// The JSON body of a recorded request.
    static func json(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// The stub session a request belongs to, by its `Authorization: Bearer <key>` header.
    static func route(for request: URLRequest) -> Route? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ") else { return nil }
        let key = String(authorization.dropFirst("Bearer ".count))
        return routes.withLock { $0[key] }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.mistral.ai" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        guard let route = Self.route(for: request) else {
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            // Outside the test's task, so Swift Testing reports it without a test name; the
            // error below fails the request in the test itself.
            Issue.record("Mistral request without a known stub key (Authorization: \(authorization == nil ? "missing" : "unknown"))")
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let delay = route.state.withLock { state in
            state.requests.append(RecordedRequest(request: request, body: body))
            return state.delay
        }
        let response = route.handler(request, body)
        // `URLProtocol` and its client are not `Sendable`, but the client may be called from any
        // thread, and nothing else uses this protocol instance after `startLoading`.
        nonisolated(unsafe) let respond = { [request = self.request, client = self.client] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status,
                                                                  httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { respond() }
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
