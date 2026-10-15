import Foundation
import CoreText
import PDFKit
import Testing
@testable import DocumentArchive

@Suite struct PDFBuilderTests {
    @Test func onePagePerImage() throws {
        let images = (1...3).map { TestSupport.renderPage(lines: ["Seite \($0)"]) }
        let pdf = try #require(PDFBuilder.makePDF(from: images))
        #expect(PDFDocument(data: pdf)?.pageCount == 3)
    }

    @Test func noImagesNoPDF() {
        #expect(PDFBuilder.makePDF(from: []) == nil)
    }

    @Test func scansStaySmall() throws {
        let pdf = try #require(PDFBuilder.makePDF(from: [TestSupport.renderPage(lines: ["Rechnung"])]))
        #expect(pdf.count < 500_000, "images are embedded as compressed JPEG")
    }
}

extension GlobalStateTests {
    @Suite final class DocumentProcessorTests {
        deinit { MistralStub.reset() }

        static let letter = ["Stadtwerke Beispielstadt GmbH", "Rechnung Nr. 4711", "Rechnungsdatum: 03.09.2026"]

        @Test func readsScannedTextWithVision() async throws {
            MistralStub.reset()
            let result = await DocumentProcessor.analyze(TestSupport.samplePDF(lines: Self.letter), mistral: nil)

            #expect(result.pageCount == 1)
            #expect(result.thumbnail != nil)
            #expect(result.textSource == "Apple Vision")
            #expect(result.text.contains("Rechnung"))
            #expect(result.text.contains("03.09.2026"))
            #expect(result.note.isEmpty)
        }

        @Test func usesEmbeddedTextWhenThePDFHasEnough() async throws {
            let pdf = try #require(Self.textPDF("Dies ist ein PDF mit eingebettetem Text, lang genug für die Erkennung."))
            let result = await DocumentProcessor.analyze(pdf, mistral: nil)
            #expect(result.textSource == "PDF-Text")
            #expect(result.text.contains("eingebettetem Text"))
        }

        @Test func usesMistralOCRWhenConfigured() async throws {
            MistralStub.install(config: MistralStub.config()) { _, _ in .json(["pages": [["index": 0, "markdown": "Von Mistral"]]]) }
            let result = await DocumentProcessor.analyze(TestSupport.samplePDF(lines: Self.letter), mistral: MistralStub.config())
            #expect(result.textSource == "Mistral OCR")
            #expect(result.text == "Von Mistral")
            #expect(result.thumbnail != nil)
        }

        @Test func fallsBackToVisionWhenMistralFails() async throws {
            MistralStub.install(config: MistralStub.config()) { _, _ in .json(["message": "Unauthorized"], status: 401) }
            let result = await DocumentProcessor.analyze(TestSupport.samplePDF(lines: Self.letter), mistral: MistralStub.config())
            #expect(result.textSource == "Apple Vision")
            #expect(result.text.contains("Rechnung"))
            #expect(result.note.contains("401"))
        }

        @Test func skipsMistralOCRWhenTurnedOff() async throws {
            MistralStub.install(config: MistralStub.config(useOCR: false)) { _, _ in .json([:]) }
            _ = await DocumentProcessor.analyze(TestSupport.samplePDF(lines: Self.letter), mistral: MistralStub.config(useOCR: false))
            #expect(MistralStub.requests.isEmpty)
        }

        @Test func unreadableDataGivesAnEmptyResult() async {
            let result = await DocumentProcessor.analyze(Data("not a pdf".utf8), mistral: nil)
            #expect(result.pageCount == 0)
            #expect(result.text.isEmpty)
            #expect(!result.note.isEmpty)
        }

        /// A one-page PDF with real (selectable) text, as exported by office software.
        private static func textPDF(_ text: String) -> Data? {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            context.textPosition = CGPoint(x: 40, y: 780)
            CTLineDraw(line, context)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
    }
}
