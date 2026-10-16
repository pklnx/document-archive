import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Analyzes a PDF: page count, thumbnail and full text.
/// If the PDF has no embedded text (e.g. scans), the text is read with Vision text recognition.
/// For qualifying scans and image-only PDFs it also builds a copy with an invisible text layer
/// (`TextLayer`); Vision runs once per page for both.
enum DocumentProcessor {
    struct Result: Sendable {
        var pageCount: Int
        var thumbnail: Data?
        var text: String
        var textSource: String
        var note: String = ""
        /// The PDF with a text layer, already verified; `nil` when no layer was added.
        var searchablePDF: Data?
    }

    /// At most this many pages are read with OCR, so very long scans do not take forever.
    static let maxOCRPages = 40

    /// `Document.textSource` of text read by Mistral OCR, which is Markdown.
    static let mistralTextSource = "Mistral OCR"

    /// - Parameter mistral: When set and Mistral OCR is on, the text is read through Mistral.
    ///   On errors, the embedded PDF text or local Apple text recognition is used instead.
    /// - Parameter textLayerSource: The document's source when a text layer should be added
    ///   (the setting is on); `nil` never rewrites the PDF. The layer always comes from Vision on
    ///   the device, also when the text comes from Mistral.
    /// - Parameter rewriteHook: Test seam (`TextLayer.rewriteHookForTesting`); `nil` in the app.
    static func analyze(_ pdfData: Data, mistral: MistralConfig? = nil,
                        textLayerSource: DocumentSource? = nil,
                        rewriteHook: TextLayer.RewriteHook? = nil) async -> Result {
        guard let pdf = PDFDocument(data: pdfData) else {
            return Result(pageCount: 0, thumbnail: nil, text: "", textSource: "", note: String(localized: "The PDF could not be read."))
        }
        let pageCount = pdf.pageCount
        let thumbnail = pdf.page(at: 0)
            .flatMap { render($0, maxPixelSize: 480) }
            .flatMap { ImageCoding.jpegData(from: $0, quality: 0.75) }

        var recognition = PageRecognition(pdf: pdf)
        var notes: [String] = []
        var text = ""
        var source = ""
        if let mistral, mistral.useOCR {
            do {
                let mistralText = try await MistralClient(config: mistral).ocr(pdfData: pdfData)
                if !mistralText.isEmpty {
                    text = mistralText
                    source = mistralTextSource
                }
            } catch {
                notes.append(String(localized: "\(error.localizedDescription) Local text recognition was used instead."))
            }
        }

        if source.isEmpty {
            text = (pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            source = "PDF-Text"
            let hasUsableText = text.count >= max(20, pageCount * 15)
            if !hasUsableText {
                var pages: [String] = []
                for index in 0..<min(pageCount, maxOCRPages) {
                    pages.append(await recognition.page(index).text)
                }
                let recognized = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if recognized.count > text.count {
                    text = recognized
                    source = "Apple Vision"
                }
            }
        }

        var searchablePDF: Data?
        if let textLayerSource {
            let layer = await textLayer(for: pdfData, pdf: pdf, source: textLayerSource,
                                        recognition: &recognition, rewriteHook: rewriteHook)
            searchablePDF = layer.data
            if let note = layer.note { notes.append(note) }
        }
        return Result(pageCount: pageCount, thumbnail: thumbnail, text: text, textSource: source,
                      note: notes.joined(separator: "\n"), searchablePDF: searchablePDF)
    }

    /// Builds and verifies the PDF with a text layer. `data` is `nil` when the PDF does not
    /// qualify, has no page that needs a layer, no words were found, or the check failed.
    private static func textLayer(for pdfData: Data, pdf: PDFDocument, source: DocumentSource,
                                  recognition: inout PageRecognition,
                                  rewriteHook: TextLayer.RewriteHook?) async -> (data: Data?, note: String?) {
        guard TextLayer.qualifies(pdf, source: source) else { return (nil, nil) }
        let pages = TextLayer.pagesNeedingLayer(in: pdf).filter { $0 < maxOCRPages }
        var words: [Int: [RecognizedWord]] = [:]
        for index in pages {
            let found = await recognition.page(index).words
            if !found.isEmpty { words[index] = found }
        }
        guard !words.isEmpty else { return (nil, nil) }
        guard var rewritten = TextLayer.addingTextLayer(to: pdfData, words: words) else {
            return (nil, String(localized: "Text layer skipped: the PDF could not be rewritten."))
        }
        if let rewriteHook { rewritten = rewriteHook(pdfData, rewritten) }
        switch TextLayer.check(original: pdfData, rewritten: rewritten) {
        case .passed:
            break
        case .tooLarge:
            return (nil, String(localized: "Text layer skipped: the result would be too large."))
        case .unreadable:
            return (nil, String(localized: "Text layer skipped: the PDF could not be rewritten."))
        case .pageCountChanged, .looksDifferent:
            return (nil, String(localized: "Text layer skipped: the result did not match the original."))
        }
        let note = pdf.pageCount > maxOCRPages
            ? String(localized: "Text layer added to the first \(maxOCRPages) pages only.")
            : nil
        return (rewritten, note)
    }

    /// Runs Vision at most once per page and keeps the result, so the document's text and the
    /// text layer share one recognition.
    private struct PageRecognition {
        let pdf: PDFDocument
        private var cache: [Int: RecognizedPage] = [:]

        init(pdf: PDFDocument) { self.pdf = pdf }

        mutating func page(_ index: Int) async -> RecognizedPage {
            if let cached = cache[index] { return cached }
            guard let page = pdf.page(at: index) else { return RecognizedPage() }
            let result = await TextLayer.recognize(page)
            cache[index] = result
            return result
        }
    }

    /// Renders a PDF page into a bitmap, the same way on every platform.
    static func render(_ page: PDFPage, maxPixelSize: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        // Rotated pages: swap width and height
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = maxPixelSize / max(pageSize.width, pageSize.height)
        let width = Int(pageSize.width * scale)
        let height = Int(pageSize.height * scale)

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }
}
