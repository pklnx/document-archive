import CoreGraphics
import CoreText
import Foundation
import PDFKit
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
