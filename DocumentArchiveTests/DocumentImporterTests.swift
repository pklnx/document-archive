import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import DocumentArchive

extension GlobalStateTests {
    @Suite @MainActor struct DocumentImporterTests {
        let container: ModelContainer
        let directory: URL
        var context: ModelContext { container.mainContext }

        init() throws {
            MistralStub.reset()   // local processing only
            container = try TestSupport.makeContainer()
            directory = try TestSupport.makeTemporaryDirectory()
        }

        private func writePDF(_ name: String, lines: [String] = ["Test"]) throws -> URL {
            let url = directory.appending(path: name)
            try TestSupport.samplePDF(lines: lines).write(to: url)
            return url
        }

        private func writePNG(_ name: String) throws -> URL {
            let url = directory.appending(path: name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, TestSupport.renderPage(lines: ["Foto"]), nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }

        @Test func importsPDFAndImage() async throws {
            let result = DocumentImporter.importFiles([try writePDF("Rechnung.pdf"), try writePNG("Foto.png")], into: context)
            try await TestSupport.waitUntilProcessed(result.imported)

            #expect(result.errors.isEmpty)
            #expect(result.imported.map(\.title) == ["Rechnung", "Foto"])
            #expect(result.imported.map(\.source) == [.file, .image])
            #expect(result.imported.allSatisfy { $0.pageCount == 1 && $0.thumbnailData != nil && $0.inInboxWithHash })
        }

        @Test func rejectsUnsupportedFiles() throws {
            let url = directory.appending(path: "notes.txt")
            try Data("hello".utf8).write(to: url)
            let result = DocumentImporter.importFiles([url], into: context)
            #expect(result.imported.isEmpty)
            #expect(result.errors.count == 1)
        }

        /// Regression: the same file imported twice ended up twice in the archive.
        @Test func skipsIdenticalFileInTheSameBatchAndLater() async throws {
            let original = try writePDF("Brief.pdf", lines: ["Deutsche Rentenversicherung"])
            let copy = directory.appending(path: "Kopie mit anderem Namen.pdf")
            try FileManager.default.copyItem(at: original, to: copy)

            let first = DocumentImporter.importFiles([original, copy], into: context)
            try await TestSupport.waitUntilProcessed(first.imported)
            #expect(first.imported.count == 1)
            #expect(first.duplicates.map(\.fileName) == ["Kopie mit anderem Namen.pdf"])
            #expect(first.duplicates.first?.existing.id == first.imported.first?.id)

            let later = DocumentImporter.importFiles([original], into: context)
            #expect(later.imported.isEmpty)
            #expect(later.duplicates.count == 1)
            #expect(try context.fetch(FetchDescriptor<Document>()).count == 1)
        }

        @Test func skipsPhotosThatWereAlreadyImported() async throws {
            let data = try Data(contentsOf: try writePNG("Foto.png"))
            let first = DocumentImporter.importImageData([data], into: context)
            let second = DocumentImporter.importImageData([data], into: context)
            try await TestSupport.waitUntilProcessed([first.document].compactMap { $0 })
            #expect(first.isDuplicate == false)
            #expect(second.isDuplicate)
            #expect(second.document?.id == first.document?.id)
        }

        @Test func backfillsMissingHashes() throws {
            let pdf = TestSupport.samplePDF()
            let doc = Document(title: "Alt", pdfData: pdf, source: .file)
            doc.isProcessing = false
            context.insert(doc)
            #expect(doc.contentHash.isEmpty)

            DocumentImporter.backfillHashes(in: context)

            #expect(doc.contentHash == DocumentImporter.sha256(pdf))
            #expect(DocumentImporter.existingDocument(withHash: doc.contentHash, in: context)?.id == doc.id)
        }

        /// `importFile(data:name:into:)` is the one pipeline behind `importFiles` and `ExternalImport`:
        /// the duplicate check runs on the original bytes before anything is inserted.
        @Test func importFileFromDataChecksDuplicatesOnTheOriginalBytes() async throws {
            let pngData = try Data(contentsOf: try writePNG("Foto.png"))

            let first = try DocumentImporter.importFile(data: pngData, name: "Foto.png", into: context)
            guard case .imported(let document) = first else { Issue.record("not imported: \(first)"); return }
            try await TestSupport.waitUntilProcessed([document])
            #expect(document.title == "Foto")
            #expect(document.source == .image)
            #expect(document.originalFileName == "Foto.png")
            #expect(document.contentHash == DocumentImporter.sha256(pngData), "the hash is the original's, not the PDF's")

            let again = try DocumentImporter.importFile(data: pngData, name: "Anderer Name.png", into: context)
            guard case .duplicate(let existing) = again else { Issue.record("not a duplicate: \(again)"); return }
            #expect(existing.id == document.id)

            // The file picker path ends in the same pipeline and sees the same duplicate.
            let picked = DocumentImporter.importFiles([directory.appending(path: "Foto.png")], into: context)
            #expect(picked.duplicates.first?.existing.id == document.id)
            #expect(try context.fetch(FetchDescriptor<Document>()).count == 1)
        }

        @Test func importFileRejectsUnsupportedAndUndecodableData() throws {
            #expect(throws: DocumentImporter.ImportError.self) {
                try DocumentImporter.importFile(data: Data("hello".utf8), name: "notes.txt", into: context)
            }
            #expect(throws: DocumentImporter.ImportError.self) {
                try DocumentImporter.importFile(data: Data("not an image".utf8), name: "Foto.png", into: context)
            }
            #expect(try context.fetch(FetchDescriptor<Document>()).isEmpty)
        }

        /// The wording and the document to open are shared by every import path.
        @Test func resultNoticeAndDocumentToOpen() async throws {
            let pdf = try writePDF("Rechnung.pdf", lines: ["Rechnung 4711"])
            let single = DocumentImporter.importFiles([pdf], into: context)
            try await TestSupport.waitUntilProcessed(single.imported)
            #expect(single.notice == nil)
            #expect(single.documentToOpen?.isNew == true)
            #expect(single.documentToOpen?.document.id == single.imported.first?.id)

            let duplicate = DocumentImporter.importFiles([pdf], into: context)
            #expect(duplicate.documentToOpen?.isNew == false)
            #expect(duplicate.documentToOpen?.document.id == single.imported.first?.id)
            let notice = try #require(duplicate.notice)
            #expect(notice.message.contains("Rechnung.pdf"))
            #expect(notice.message.contains(single.imported[0].title))

            let text = directory.appending(path: "notes.txt")
            try Data("hello".utf8).write(to: text)
            var mixed = DocumentImporter.importFiles([text], into: context)
            mixed.merge(duplicate)
            #expect(mixed.documentToOpen?.document.id == single.imported.first?.id)
            #expect(try #require(mixed.notice).message.contains("notes.txt"))
            #expect(DocumentImporter.ImportResult().notice == nil)
            #expect(DocumentImporter.ImportResult().documentToOpen == nil)
        }

        // MARK: Text layer (#9)

        private static let letter = ["Stadtwerke Beispielstadt GmbH", "Rechnung Nr. 4711", "Rechnungsdatum: 03.09.2026"]

        private func pngData(lines: [String]) throws -> Data {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, TestSupport.renderPage(lines: lines), nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }

        private func imported(_ outcome: DocumentImporter.FileOutcome) throws -> Document {
            guard case .imported(let document) = outcome else { throw TestFailure("not imported: \(outcome)") }
            return document
        }

        private struct TestFailure: Error, CustomStringConvertible {
            var description: String
            init(_ description: String) { self.description = description }
        }

        // 10 and 12
        @Test func importedImageGetsATextLayerAndStaysADuplicate() async throws {
            let png = try pngData(lines: Self.letter)
            let document = try imported(try DocumentImporter.importFile(data: png, name: "Brief.png", into: context))
            let modifiedBefore = document.modifiedAt
            let pdfBefore = try #require(document.pdfData)
            try await TestSupport.waitUntilProcessed([document])

            let stored = try #require(document.pdfData)
            #expect(stored != pdfBefore, "the PDF was replaced")
            #expect(PDFDocument(data: stored)?.page(at: 0)?.string?.contains("Rechnung") == true)
            #expect(document.fileSize == stored.count)
            #expect(document.contentHash == DocumentImporter.sha256(png), "the hash stays the original file's")
            #expect(document.modifiedAt > modifiedBefore, "touched, so the folder copy writes the new PDF")

            // The same image again is a duplicate.
            let again = try DocumentImporter.importFile(data: png, name: "Brief Kopie.png", into: context)
            guard case .duplicate(let existing) = again else { Issue.record("not a duplicate: \(again)"); return }
            #expect(existing.id == document.id)

            // 12: the exported (layered) PDF imported again is found through size + hash.
            let export = directory.appending(path: document.exportFileName)
            try stored.write(to: export)
            let reimport = DocumentImporter.importFiles([export], into: context)
            #expect(reimport.imported.isEmpty)
            #expect(reimport.duplicates.first?.existing.id == document.id)
            #expect(try context.fetch(FetchDescriptor<Document>()).count == 1)
        }

        /// The folder copy (#8) writes the PDF with the text layer after processing replaced it.
        @Test func folderCopyPicksUpTheReplacedPDF() async throws {
            let device = try MirrorFixture()
            let scan = TestSupport.samplePDF(lines: Self.letter)
            let document = device.insertDocument("Scan", pdf: scan)
            document.source = .scan
            try device.context.save()
            try await device.run()
            #expect(try Data(contentsOf: device.layout.pdf(document.id)) == scan)

            await DocumentImporter.processAndWait(document, context: device.context, classify: false)
            let layered = try #require(document.pdfData)
            #expect(layered != scan)

            let pass = try await device.run()
            #expect(pass.pdfsWritten == 1)
            #expect(try Data(contentsOf: device.layout.pdf(document.id)) == layered)
        }

        // 8
        @Test func rewriteThatFailsTheCheckKeepsTheOriginal() async throws {
            TextLayer.rewriteHookForTesting = { data in
                // Drops the last page, so the page count no longer matches.
                let pdf = PDFDocument(data: data)!
                pdf.removePage(at: pdf.pageCount - 1)
                return pdf.dataRepresentation()!
            }
            defer { TextLayer.rewriteHookForTesting = nil }
            let scan = TestSupport.scanPDF(pages: [Self.letter, ["Seite zwei Kontoauszug"]])
            let document = try imported(try DocumentImporter.importFile(data: scan, name: "Scan.pdf", into: context))
            try await TestSupport.waitUntilProcessed([document])

            #expect(document.pdfData == scan)
            #expect(document.processingNote.contains(String(localized: "Text layer skipped: the result did not match the original.")))
            #expect(document.textSource == "Apple Vision", "the text is still recognized")
        }

        // 11
        @Test func pdfChangedDuringTheAnalysisIsKept() async throws {
            MistralStub.install(config: MistralStub.config(useOCR: true, useLLM: false)) { _, _ in
                .json(["pages": [["index": 0, "markdown": "Von Mistral"]]])
            }
            defer { MistralStub.reset() }
            MistralStub.delay = 1
            let document = Document(title: "Scan", pdfData: TestSupport.samplePDF(lines: Self.letter), source: .scan)
            document.isProcessing = false
            context.insert(document)

            let processing = Task { await DocumentImporter.processAndWait(document, context: context, classify: false) }
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(30)
            while MistralStub.requests.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!MistralStub.requests.isEmpty, "the analysis is waiting for the stub")

            // Meanwhile another device (or a merge) replaces the PDF.
            let newer = TestSupport.samplePDF(lines: ["Neuere Fassung"])
            document.pdfData = newer
            await processing.value

            #expect(document.pdfData == newer)
            #expect(document.fileSize == newer.count)
            #expect(!document.isProcessing)
        }

        // 13
        @Test func settingOffLeavesThePDFUnchanged() async throws {
            TextLayer.isEnabledProvider = { false }
            defer { TextLayer.isEnabledProvider = { true } }
            let scan = TestSupport.samplePDF(lines: Self.letter)
            let document = try imported(try DocumentImporter.importFile(data: scan, name: "Scan.pdf", into: context))
            try await TestSupport.waitUntilProcessed([document])

            #expect(document.pdfData == scan)
            #expect(document.extractedText.contains("Rechnung"))
        }

        @Test func replacePDFNeedsTheAnalyzedBytes() throws {
            let original = TestSupport.samplePDF(lines: ["Eins"])
            let document = Document(title: "Scan", pdfData: original, source: .scan)
            context.insert(document)
            let layered = Data("layered".utf8)

            #expect(!DocumentImporter.replacePDF(of: document, analyzed: Data("other".utf8), with: layered))
            #expect(document.pdfData == original)

            #expect(DocumentImporter.replacePDF(of: document, analyzed: original, with: layered))
            #expect(document.pdfData == layered)
            #expect(document.fileSize == layered.count)
        }

        @Test func sha256IsHexOfTheContent() {
            #expect(DocumentImporter.sha256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
    }
}

private extension Document {
    var inInboxWithHash: Bool { isInbox && !contentHash.isEmpty }
}
