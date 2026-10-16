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
            let pdf = try #require(TestSupport.textPDF("Dies ist ein PDF mit eingebettetem Text, lang genug für die Erkennung."))
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

        /// The text comes from Mistral, the text layer from Vision on the device; Mistral receives
        /// exactly the one OCR request it received before.
        @Test func textLayerComesFromVisionWhenMistralReadsTheText() async throws {
            MistralStub.install(config: MistralStub.config()) { _, _ in .json(["pages": [["index": 0, "markdown": "Von Mistral"]]]) }
            let result = await DocumentProcessor.analyze(TestSupport.samplePDF(lines: Self.letter), mistral: MistralStub.config(),
                                                         textLayerSource: .scan)
            #expect(result.textSource == "Mistral OCR")
            #expect(result.text == "Von Mistral")
            let layered = try #require(result.searchablePDF.flatMap(PDFDocument.init(data:)))
            #expect(layered.page(at: 0)?.string?.contains("Rechnung") == true)
            #expect(MistralStub.requests.count == 1)
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
    }
}
