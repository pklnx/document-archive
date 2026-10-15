import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Analyzes a PDF: page count, thumbnail and full text.
/// If the PDF has no embedded text (e.g. scans), the text is read with Vision text recognition.
enum DocumentProcessor {
    struct Result: Sendable {
        var pageCount: Int
        var thumbnail: Data?
        var text: String
        var textSource: String
        var note: String = ""
    }

    /// At most this many pages are read with OCR, so very long scans do not take forever.
    private static let maxOCRPages = 40

    /// - Parameter mistral: When set and Mistral OCR is on, the text is read through Mistral.
    ///   On errors, the embedded PDF text or local Apple text recognition is used instead.
    static func analyze(_ pdfData: Data, mistral: MistralConfig? = nil) async -> Result {
        guard let pdf = PDFDocument(data: pdfData) else {
            return Result(pageCount: 0, thumbnail: nil, text: "", textSource: "", note: String(localized: "The PDF could not be read."))
        }
        let pageCount = pdf.pageCount
        let thumbnail = pdf.page(at: 0)
            .flatMap { render($0, maxPixelSize: 480) }
            .flatMap { ImageCoding.jpegData(from: $0, quality: 0.75) }

        var note = ""
        if let mistral, mistral.useOCR {
            do {
                let text = try await MistralClient(config: mistral).ocr(pdfData: pdfData)
                if !text.isEmpty {
                    return Result(pageCount: pageCount, thumbnail: thumbnail, text: text, textSource: "Mistral OCR")
                }
            } catch {
                note = String(localized: "\(error.localizedDescription) Local text recognition was used instead.")
            }
        }

        var text = (pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var source = "PDF-Text"
        let hasUsableText = text.count >= max(20, pageCount * 15)
        if !hasUsableText {
            let recognized = await recognizeText(in: pdf)
            if recognized.count > text.count {
                text = recognized
                source = "Apple Vision"
            }
        }
        return Result(pageCount: pageCount, thumbnail: thumbnail, text: text, textSource: source, note: note)
    }

    private static func recognizeText(in pdf: PDFDocument) async -> String {
        var pages: [String] = []
        for index in 0..<min(pdf.pageCount, maxOCRPages) {
            guard let page = pdf.page(at: index), let image = render(page, maxPixelSize: 2600) else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
            do {
                let observations = try await request.perform(on: image)
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                pages.append(lines.joined(separator: "\n"))
            } catch {
                print("Texterkennung fehlgeschlagen (Seite \(index + 1)): \(error)")
            }
        }
        return pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
