import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

extension GlobalStateTests {
    /// Files opened from other apps ("Open with", the Dock icon, "Open in…"). Opening them from
    /// Finder, Files or Mail itself is on the manual check list; these tests hand the URLs to
    /// `ExternalImport` the way `OpenURLHandler` does.
    @Suite @MainActor struct ExternalImportTests {
        let container: ModelContainer
        let directory: URL
        let inbox: URL
        var context: ModelContext { container.mainContext }

        init() throws {
            MistralStub.reset()   // local processing only
            container = try TestSupport.makeContainer()
            directory = try TestSupport.makeTemporaryDirectory()
            inbox = directory.appending(path: "Documents/Inbox")
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }

        private func makeImport(withContext: Bool = true) -> ExternalImport {
            let externalImport = ExternalImport(inboxFolder: inbox)
            if withContext { externalImport.context = context }
            return externalImport
        }

        private func writePDF(_ name: String, in folder: URL? = nil, lines: [String] = ["Test"]) throws -> URL {
            let url = (folder ?? directory).appending(path: name)
            try TestSupport.samplePDF(lines: lines).write(to: url)
            return url
        }

        private func documents() throws -> [Document] {
            try context.fetch(FetchDescriptor<Document>())
        }

        /// Opened at launch: the URL arrives before a window has handed over the archive.
        @Test func filesReceivedBeforeTheArchiveIsReadyAreImportedOnceItIsSet() async throws {
            let externalImport = makeImport(withContext: false)
            externalImport.receive([try writePDF("Rechnung.pdf")], origin: .openWith)

            #expect(externalImport.queued.count == 1)
            #expect(externalImport.pendingResult == nil)
            #expect(try documents().isEmpty)

            externalImport.context = context

            #expect(externalImport.queued.isEmpty)
            await externalImport.waitForImports()
            let result = try #require(await externalImport.importedResult())
            try await TestSupport.waitUntilProcessed(result.imported)
            #expect(result.imported.map(\.title) == ["Rechnung"])
            #expect(result.imported.first?.originalFileName == "Rechnung.pdf")
            #expect(result.imported.first?.isInbox == true)
            #expect(try documents().count == 1, "imported once")

            externalImport.context = context
            await externalImport.waitForImports()
            #expect(externalImport.pendingResult == nil, "setting the archive again imports nothing twice")
            #expect(try documents().count == 1)
        }

        @Test func openingOneNewFileOpensItsDocument() async throws {
            let externalImport = makeImport()
            externalImport.receive([try writePDF("Rechnung.pdf")], origin: .openWith)

            let result = try #require(await externalImport.importedResult())
            try await TestSupport.waitUntilProcessed(result.imported)
            #expect(result.notice == nil)
            #expect(result.documentToOpen?.isNew == true)
            #expect(result.documentToOpen?.document.id == result.imported.first?.id)
            #expect(await externalImport.importedResult() == nil, "the result is shown once")
        }

        @Test func openingADuplicateShowsTheExistingDocument() async throws {
            let original = try writePDF("Rechnung.pdf", lines: ["Rechnung 4711"])
            let first = await DocumentImporter.importFiles([original], into: context)
            try await TestSupport.waitUntilProcessed(first.imported)
            let copy = directory.appending(path: "Kopie.pdf")
            try FileManager.default.copyItem(at: original, to: copy)

            let externalImport = makeImport()
            externalImport.receive([copy], origin: .openWith)

            let result = try #require(await externalImport.importedResult())
            #expect(result.imported.isEmpty)
            #expect(result.documentToOpen?.isNew == false)
            #expect(result.documentToOpen?.document.id == first.imported.first?.id)
            #expect(try #require(result.notice).message.contains("Kopie.pdf"))
            #expect(try documents().count == 1)
        }

        /// macOS sends one open event per file; the window shows them together.
        @Test func severalOpenEventsAreShownTogether() async throws {
            let externalImport = makeImport()
            externalImport.receive([try writePDF("Eins.pdf", lines: ["Eins"])], origin: .openWith)
            externalImport.receive([try writePDF("Zwei.pdf", lines: ["Zwei"])], origin: .openWith)

            let result = try #require(await externalImport.importedResult())
            try await TestSupport.waitUntilProcessed(result.imported)
            #expect(Set(result.imported.map(\.title)) == ["Eins", "Zwei"])
            #expect(result.documentToOpen == nil)
            #expect(result.notice == nil)
        }

        @Test func unsupportedFileIsReported() async throws {
            let text = directory.appending(path: "Notiz.txt")
            try Data("Hallo".utf8).write(to: text)
            let externalImport = makeImport()
            externalImport.receive([text], origin: .openWith)

            let result = try #require(await externalImport.importedResult())
            #expect(result.imported.isEmpty)
            #expect(result.errors.count == 1)
            #expect(try #require(result.notice).message.contains("Notiz.txt"))
            #expect(try documents().isEmpty)
        }

        #if os(iOS)
        /// iOS copies files from Mail and "Copy to …" into `Documents/Inbox`; the app owns these
        /// copies and removes them, also when the file was a duplicate. A file opened in place
        /// (Files) belongs to the user and stays.
        @Test func inboxCopiesAreRemovedAndFilesOpenedInPlaceKept() async throws {
            let inPlace = try writePDF("Vertrag.pdf", lines: ["Vertrag"])
            let inboxCopy = try writePDF("Rechnung.pdf", in: inbox, lines: ["Rechnung"])
            let inboxData = try Data(contentsOf: inboxCopy)
            let externalImport = makeImport()

            externalImport.receive([inPlace], origin: .openWith)
            externalImport.receive([inboxCopy], origin: .openWith)
            let result = try #require(await externalImport.importedResult())
            try await TestSupport.waitUntilProcessed(result.imported)

            #expect(result.imported.count == 2)
            #expect(FileManager.default.fileExists(atPath: inPlace.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: inboxCopy.path(percentEncoded: false)))

            let duplicateCopy = inbox.appending(path: "Rechnung 2.pdf")
            try inboxData.write(to: duplicateCopy)
            externalImport.receive([duplicateCopy], origin: .openWith)
            #expect(await externalImport.importedResult()?.duplicates.count == 1)
            #expect(!FileManager.default.fileExists(atPath: duplicateCopy.path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: inbox.path(percentEncoded: false)), "only the file is removed")
        }
        #else
        /// The Mac build is not sandboxed: `Documents/Inbox` is the user's own folder, so a file
        /// opened from there with "Open with" stays, also when it was a duplicate.
        @Test func filesInAnInboxFolderAreKeptOnTheMac() async throws {
            let opened = try writePDF("Rechnung.pdf", in: inbox, lines: ["Rechnung"])
            let data = try Data(contentsOf: opened)
            let externalImport = makeImport()

            externalImport.receive([opened], origin: .openWith)
            let result = try #require(await externalImport.importedResult())
            try await TestSupport.waitUntilProcessed(result.imported)
            #expect(result.imported.count == 1)
            #expect(FileManager.default.fileExists(atPath: opened.path(percentEncoded: false)))

            let duplicate = inbox.appending(path: "Rechnung 2.pdf")
            try data.write(to: duplicate)
            externalImport.receive([duplicate], origin: .openWith)
            #expect(await externalImport.importedResult()?.duplicates.count == 1)
            #expect(FileManager.default.fileExists(atPath: duplicate.path(percentEncoded: false)))
        }
        #endif
    }
}

extension ExternalImport {
    /// The result once every received file is imported (the window gets it through observation).
    func importedResult() async -> DocumentImporter.ImportResult? {
        await waitForImports()
        return takeResult()
    }
}
