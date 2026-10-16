import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import DocumentArchive

/// The invisible text layer for scans and image-only PDFs (#9).
@Suite struct TextLayerTests {
    static let firstPage = ["Rechnung Nr. 4711", "Grüße aus Köln, Straße"]
    static let secondPage = ["Seite zwei Kontoauszug"]
    static let letter = ["Stadtwerke Beispielstadt GmbH", "Rechnung Nr. 4711", "Rechnungsdatum: 03.09.2026"]

    /// Runs the production path (recognition, rewrite, verification) and returns the new PDF.
    private func layered(_ data: Data, source: DocumentSource = .scan) async throws -> Data {
        let result = await DocumentProcessor.analyze(data, mistral: nil, textLayerSource: source)
        return try #require(result.searchablePDF, "no text layer: \(result.note)")
    }

    private func page(_ data: Data, _ index: Int = 0) throws -> PDFPage {
        try #require(PDFDocument(data: data)?.page(at: index))
    }

    /// The box of a recognized word on the original page, in displayed page coordinates.
    private func box(of word: String, on page: PDFPage) async throws -> CGRect {
        let words = await TextLayer.recognize(page).words
        return try #require(words.first { $0.text == word }?.box, "“\(word)” not recognized in \(words.map(\.text))")
    }

    private func selectedText(on page: PDFPage, in rect: CGRect) -> String {
        (page.selection(for: rect)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 1
    @Test func wordsLandOnTheRightPage() async throws {
        let scan = TestSupport.scanPDF(pages: [Self.firstPage, Self.secondPage])
        let pdf = try #require(PDFDocument(data: try await layered(scan)))
        let first = pdf.page(at: 0)?.string ?? ""
        let second = pdf.page(at: 1)?.string ?? ""
        #expect(first.contains("Rechnung"))
        #expect(first.contains("Rechnung Nr. 4711"), "words keep their spaces: \(first)")
        #expect(first.contains("Grüße aus Köln, Straße"), "umlauts survive (ToUnicode): \(first)")
        #expect(!first.contains("Kontoauszug"))
        #expect(second.contains("Kontoauszug"))
        #expect(!second.contains("Rechnung"))
    }

    // 1: umlauts and ß are written and extracted exactly, independent of what Vision reads.
    @Test func umlautsCanBeCopied() throws {
        let scan = TestSupport.scanPDF(pages: [["Test"]])
        let words = ["ä", "ö", "ü", "ß", "Grüße"].enumerated().map { index, text in
            RecognizedWord(text: text, box: CGRect(x: 60 + Double(index) * 60, y: 400, width: 30, height: 14), spaceAfter: index < 4)
        }
        let layered = try #require(TextLayer.addingTextLayer(to: scan, words: [0: words]))
        let text = try page(layered).string ?? ""
        #expect(text.contains("ä ö ü ß Grüße"), "\(text)")
    }

    /// Regression (macOS 26 CI): Core Text wrote each word with character spacing (`Tc`) and
    /// per-glyph `TJ` adjustments, which PDFKit on macOS 26 extracted as "G rü ß e". Each word is
    /// now one run at the font's own advances, scaled only through the text matrix.
    @Test func wordsAreWrittenWithoutCharacterSpacingOrGlyphGaps() throws {
        let scan = TestSupport.scanPDF(pages: [["Test"]])
        let words = ["Rechnung", "Grüße", "Straße"].enumerated().map { index, text in
            RecognizedWord(text: text, box: CGRect(x: 60 + Double(index) * 120, y: 400, width: 70 + Double(index) * 9, height: 14),
                           spaceAfter: index < 2)
        }
        let layered = try #require(TextLayer.addingTextLayer(to: scan, words: [0: words]))
        let content = try Self.contentStream(of: layered)

        let characterSpacing = try Regex(#"(-?[0-9.]+) Tc"#)
        for match in content.matches(of: characterSpacing) {
            #expect(Double(match.output[1].substring ?? "") == 0, "character spacing in \(content)")
        }
        // Inside TJ arrays, only rounding-sized adjustments (thousandths of an em) are allowed.
        let adjustment = try Regex(#"\)\s*(-?[0-9.]+)\s*\("#)
        for match in content.matches(of: adjustment) {
            let value = abs(Double(match.output[1].substring ?? "") ?? 0)
            #expect(value < 1, "glyph gap \(value) in \(content)")
        }
        let text = try page(layered).string ?? ""
        #expect(text.contains("Rechnung Grüße Straße"), "\(text)")
    }

    /// The decoded content stream(s) of the first page.
    private static func contentStream(of data: Data) throws -> String {
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let page = try #require(document.page(at: 1)?.dictionary)
        var streams: [CGPDFStreamRef] = []
        var single: CGPDFStreamRef?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetStream(page, "Contents", &single), let single {
            streams = [single]
        } else if CGPDFDictionaryGetArray(page, "Contents", &array), let array {
            for index in 0..<CGPDFArrayGetCount(array) {
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(array, index, &stream), let stream { streams.append(stream) }
            }
        }
        return streams.compactMap { stream in
            var format = CGPDFDataFormat.raw
            return (CGPDFStreamCopyData(stream, &format) as Data?).map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
    }

    // 2
    @Test func selectsASingleWordInTheMiddleOfALine() async throws {
        let scan = TestSupport.scanPDF(pages: [Self.letter])
        let box = try await box(of: "Nr.", on: try page(scan))
        let layeredPage = try page(try await layered(scan))

        let selected = selectedText(on: layeredPage, in: box.insetBy(dx: box.width * 0.2, dy: box.height * 0.2))
        #expect(selected.contains("Nr"))
        #expect(!selected.contains("Rechnung"))
        #expect(!selected.contains("4711"))

        let empty = CGRect(x: 20, y: 20, width: 100, height: 60)
        #expect(selectedText(on: layeredPage, in: empty).isEmpty)
    }

    // 3
    @Test func rotatedPageLooksTheSameAndSelectsTheWord() async throws {
        try await checkGeometry(of: TestSupport.rotatedScanPDF(lines: Self.letter))
    }

    // 3
    @Test func croppedPageLooksTheSameAndSelectsTheWord() async throws {
        let cropped = TestSupport.modifiedPDF(TestSupport.scanPDF(pages: [Self.letter])) {
            $0.page(at: 0)?.setBounds(CGRect(x: 40, y: 300, width: 500, height: 500), for: .cropBox)
        }
        try await checkGeometry(of: cropped)
    }

    private func checkGeometry(of original: Data) async throws {
        let originalPage = try page(original)
        let box = try await box(of: "Rechnung", on: originalPage)
        let layeredPage = try page(try await layered(original, source: .file))

        let difference = try #require(TextLayer.pixelDifference(originalPage, layeredPage))
        #expect(difference.mean < 1, "renders as before (mean difference \(difference.mean))")
        #expect(difference.maxTile < TextLayer.maxTilePixelDifference, "no tile changed (\(difference.maxTile))")
        #expect(TextLayer.displayedSize(of: layeredPage) == TextLayer.displayedSize(of: originalPage))
        let selected = selectedText(on: layeredPage, in: box)
        #expect(selected.contains("Rechnung"), "selected “\(selected)”")
        #expect(!selected.contains("4711"))
    }

    // 4 and 5
    @Test func looksTheSameAndStaysSmall() async throws {
        let scan = TestSupport.scanPDF(pages: [Self.letter, Self.secondPage])
        let rewritten = try await layered(scan)
        let before = try #require(PDFDocument(data: scan))
        let after = try #require(PDFDocument(data: rewritten))
        #expect(after.pageCount == before.pageCount)
        for index in 0..<before.pageCount {
            let old = try #require(before.page(at: index))
            let new = try #require(after.page(at: index))
            let difference = try #require(TextLayer.pixelDifference(old, new))
            #expect(difference.mean < 1, "page \(index + 1): mean difference \(difference.mean)")
            #expect(difference.maxTile < TextLayer.maxTilePixelDifference, "page \(index + 1): tile \(difference.maxTile)")
        }
        #expect(rewritten.count <= scan.count + scan.count / 10 + 20_000, "\(scan.count) → \(rewritten.count) bytes")
        #expect(TextLayer.verify(original: scan, rewritten: rewritten))
    }

    /// A small local change (a stamp on 2 % of the page) fails the check, although the mean over
    /// the whole page stays within its tolerance.
    @Test func localChangeFailsTheCheck() throws {
        let scan = TestSupport.scanPDF(pages: [Self.letter])
        let stamped = try Self.stamped(scan, fraction: 0.02)
        let difference = try #require(TextLayer.pixelDifference(try page(scan), try page(stamped)))
        #expect(difference.mean > 0 && difference.maxTile > TextLayer.maxTilePixelDifference)
        #expect(TextLayer.check(original: scan, rewritten: stamped) == .looksDifferent)
        #expect(TextLayer.check(original: scan, rewritten: scan) == .passed)
    }

    /// The first page redrawn with a black square covering `fraction` of its area.
    private static func stamped(_ data: Data, fraction: Double) throws -> Data {
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let pdfPage = try #require(document.page(at: 1))
        var box = pdfPage.getBoxRect(.mediaBox)
        let output = NSMutableData()
        let context = try #require(CGContext(consumer: CGDataConsumer(data: output as CFMutableData)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.drawPDFPage(pdfPage)
        let side = (box.width * box.height * fraction).squareRoot()
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: box.midX, y: box.minY + 40, width: side, height: side))
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    /// A rewrite beyond the size bound is skipped with its own note.
    @Test func tooLargeRewriteIsSkippedWithItsOwnNote() async throws {
        let scan = TestSupport.scanPDF(pages: [Self.letter])
        let padding = Data(repeating: 0x20, count: TextLayer.maxRewrittenSize(for: scan.count))
        let result = await DocumentProcessor.analyze(scan, mistral: nil, textLayerSource: .scan,
                                                     rewriteHook: { _, rewritten in rewritten + padding })
        #expect(result.searchablePDF == nil)
        #expect(result.note == String(localized: "Text layer skipped: the result would be too large."))
    }

    // 5: a full page of words (many text objects, a bigger font subset) also fits the bound.
    @Test func densePageStaysSmall() async throws {
        let words = ["Rechnung", "Betrag", "Zahlung", "Konto", "Vertrag", "Kündigung", "Frist", "Datum", "Summe", "Steuer",
                     "Versicherung", "Beitrag", "Monat", "Straße", "Größe", "Übersicht", "Leistung", "Gebühr"]
        let lines = (0..<20).map { row in
            (0..<5).map { words[(row * 5 + $0) % words.count] }.joined(separator: " ") + " \(1000 + row * 37)"
        }
        let scan = TestSupport.scanPDF(pages: [lines])
        let rewritten = try await layered(scan)
        #expect(rewritten.count <= TextLayer.maxRewrittenSize(for: scan.count), "\(scan.count) → \(rewritten.count) bytes")
    }

    // 6
    @Test func skipsPDFsThatMustNotBeRewritten() async throws {
        let scan = TestSupport.scanPDF(pages: [Self.letter])
        let text = try #require(TestSupport.textPDF("Dies ist ein PDF mit eingebettetem Text, lang genug für die Erkennung."))
        let mixed = TestSupport.modifiedPDF(scan) { pdf in
            pdf.insert(PDFDocument(data: text)!.page(at: 0)!, at: 0)
        }
        let encrypted = TestSupport.modifiedPDF(scan, options: [.userPasswordOption: "test", .ownerPasswordOption: "test"]) { _ in }
        let annotated = TestSupport.modifiedPDF(scan) { pdf in
            pdf.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil))
        }
        let signatureField = TestSupport.modifiedPDF(scan) { pdf in
            let widget = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 120, height: 40), forType: .widget, withProperties: nil)
            widget.widgetFieldType = .signature
            widget.fieldName = "Signature"
            pdf.page(at: 0)?.addAnnotation(widget)
        }
        let skipped: [(String, Data)] = [
            ("text", text), ("mixed", mixed), ("encrypted", encrypted), ("annotation", annotated),
            ("signature field", signatureField),
            // PDFKit does not write outlines, so the outline is hand-written.
            ("outline", TestSupport.rawImagePDF(catalogExtra: "/Outlines << /Type /Outlines /Count 0 >>")),
            ("signature flags", TestSupport.rawImagePDF(catalogExtra: "/AcroForm << /Fields [] /SigFlags 3 >>")),
            ("PDF/A", TestSupport.rawImagePDF(xmp: Self.xmp(conformance: "pdfaid:part=\"2\" pdfaid:conformance=\"B\""))),
            ("PDF/X", TestSupport.rawImagePDF(xmp: Self.xmp(conformance: "pdfxid:GTS_PDFXVersion=\"PDF/X-4\""))),
            ("embedded file", TestSupport.rawImagePDF(catalogExtra: "/Names << /EmbeddedFiles << /Names [] >> >>")),
            ("tagged PDF", TestSupport.rawImagePDF(catalogExtra: "/StructTreeRoot << /Type /StructTreeRoot >>")),
            ("optional content", TestSupport.rawImagePDF(catalogExtra: "/OCProperties << /OCGs [] /D << >> >>")),
            ("page labels", TestSupport.rawImagePDF(catalogExtra: "/PageLabels << /Nums [0 << /S /r >>] >>")),
            ("old PDF/X", TestSupport.rawImagePDF(xmp: Self.xmp(conformance: "xmlns:pdfx=\"http://ns.adobe.com/pdfx/1.3/\" pdfx:GTS_PDFXVersion=\"PDF/X-3:2002\""))),
            ("CCITT", TestSupport.rawImagePDF(imageFilter: "/CCITTFaxDecode")),
            ("JBIG2", TestSupport.rawImagePDF(imageFilter: "[/FlateDecode /JBIG2Decode]")),
            ("JPEG 2000 in a form", TestSupport.rawImagePDF(imageFilter: "/JPXDecode", nestedInForm: true)),
        ]
        for (name, data) in skipped {
            let pdf = PDFDocument(data: data)
            if let pdf {
                #expect(!TextLayer.qualifies(pdf, source: .file), "\(name) must not qualify")
            }
            let result = await DocumentProcessor.analyze(data, mistral: nil, textLayerSource: .file)
            #expect(result.searchablePDF == nil, "\(name) must stay unchanged")
        }

        // Controls: the same hand-written PDF without a risky filter (also inside a form, also
        // with plain XMP metadata), and the plain scan, qualify.
        for (name, data) in [("raw", TestSupport.rawImagePDF()),
                             ("raw in a form", TestSupport.rawImagePDF(imageFilter: "/FlateDecode", nestedInForm: true)),
                             ("raw with XMP", TestSupport.rawImagePDF(xmp: Self.xmp(conformance: "dc:format=\"application/pdf\""))),
                             // Adobe's custom-properties namespace is also called pdfx; it is no conformance.
                             ("raw with pdfx properties", TestSupport.rawImagePDF(xmp: Self.xmp(conformance: "xmlns:pdfx=\"http://ns.adobe.com/pdfx/1.3/\" pdfx:SourceModified=\"D:20260101\""))),
                             ("scan", scan)] {
            let pdf = try #require(PDFDocument(data: data), "\(name) opens")
            #expect(TextLayer.qualifies(pdf, source: .file), "\(name) qualifies")
        }
    }

    private static func xmp(conformance: String) -> String {
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description \(conformance)/></rdf:RDF></x:xmpmeta>"
    }

    // 7
    @Test func secondRunFindsNothingToDo() async throws {
        let scan = TestSupport.scanPDF(pages: [Self.letter])
        let once = try await layered(scan)
        let pdf = try #require(PDFDocument(data: once))
        #expect(TextLayer.pagesNeedingLayer(in: pdf).isEmpty)
        let again = await DocumentProcessor.analyze(once, mistral: nil, textLayerSource: .scan)
        #expect(again.searchablePDF == nil)
        let text = pdf.page(at: 0)?.string ?? ""
        #expect(text.components(separatedBy: "4711").count == 2, "the text appears once: \(text)")
    }

    @Test func settingIsOnByDefault() {
        let (defaults, name) = TestSupport.makeDefaults()
        defer { TestSupport.removeDefaults(name) }
        #expect(TextLayer.isEnabled(in: defaults))
        defaults.set(false, forKey: TextLayer.enabledKey)
        #expect(!TextLayer.isEnabled(in: defaults))
    }
}
