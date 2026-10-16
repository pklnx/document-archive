import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import DocumentArchive

extension GlobalStateTests {
    /// The importer side of drag and drop. A drop hands the app `NSItemProvider`s, the same as
    /// these tests; dragging from Files, Photos or Finder itself is on the manual check list.
    @Suite @MainActor struct DropImportTests {
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

        private func load(_ provider: NSItemProvider) async throws -> ImportedFile {
            try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: ImportedFile.self) { continuation.resume(with: $0) }
            }
        }

        /// iPadOS (Files, Photos) and Finder offer the file itself.
        @Test func fileRepresentationsAreCopiedWithTheirName() async throws {
            let pdf = try writePDF("Rechnung.pdf")
            let png = try writePNG("Foto.png")

            for original in [pdf, png] {
                let provider = try #require(NSItemProvider(contentsOf: original))
                // Finder, Files and Photos name the dragged item; without a name, the system
                // calls the received file after its type ("PDF document.pdf").
                provider.suggestedName = original.deletingPathExtension().lastPathComponent
                let file = try await load(provider)
                #expect(file.url.lastPathComponent == original.lastPathComponent)
                #expect(file.url.standardizedFileURL.path().hasPrefix(ImportedFile.temporaryFolder.standardizedFileURL.path()))
                #expect(file.url != original)
                #expect(try Data(contentsOf: file.url) == Data(contentsOf: original))
                file.remove()
            }
        }

        @Test func otherFilesAreRejected() async throws {
            let text = directory.appending(path: "Notiz.txt")
            try Data("Hallo".utf8).write(to: text)

            await #expect(throws: (any Error).self) {
                _ = try await load(try #require(NSItemProvider(contentsOf: text)))
            }
        }

        @Test func droppedFilesAreImportedAndTheCopiesRemoved() async throws {
            let pdf = try writePDF("Rechnung.pdf")
            let png = try writePNG("Foto.png")
            let files = [try ImportedFile(copying: pdf), try ImportedFile(copying: png)]

            let result = await DocumentImporter.importDropped(files, into: context)
            try await TestSupport.waitUntilProcessed(result.imported)

            #expect(result.errors.isEmpty)
            #expect(result.imported.map(\.title) == ["Rechnung", "Foto"])
            #expect(result.imported.map(\.source) == [.file, .image])
            #expect(result.imported.map(\.originalFileName) == ["Rechnung.pdf", "Foto.png"])
            for file in files {
                #expect(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path()))
            }
            #expect(FileManager.default.fileExists(atPath: pdf.path()), "the original stays where it was")
        }

        @Test func droppedDuplicateIsReportedAndItsCopyRemoved() async throws {
            let pdf = try writePDF("Rechnung.pdf", lines: ["Rechnung 4711"])
            let first = await DocumentImporter.importFiles([pdf], into: context)
            try await TestSupport.waitUntilProcessed(first.imported)

            let copy = try ImportedFile(copying: pdf)
            let result = await DocumentImporter.importDropped([copy], into: context)

            #expect(result.imported.isEmpty)
            #expect(result.duplicates.map(\.fileName) == ["Rechnung.pdf"])
            #expect(result.duplicates.first?.existing.id == first.imported.first?.id)
            #expect(!FileManager.default.fileExists(atPath: copy.url.path()))
        }
    }
}
