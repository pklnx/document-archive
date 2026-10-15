import CoreGraphics
import Foundation
import ImageIO
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

        @Test func sha256IsHexOfTheContent() {
            #expect(DocumentImporter.sha256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
    }
}

private extension Document {
    var inInboxWithHash: Bool { isInbox && !contentHash.isEmpty }
}
