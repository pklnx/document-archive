import Foundation
import PDFKit
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import DocumentArchive
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Print, Copy PDF / Copy Text and the shared PDF file (#19).
@MainActor @Suite struct DocumentActionsTests {
    private func makeDocument(in context: ModelContext, pdf: Data? = TestSupport.samplePDF(),
                              text: String = "", textSource: String = "PDF-Text") -> Document {
        let document = Document(title: "Stromrechnung", pdfData: pdf ?? Data(), source: .file)
        if pdf == nil { document.pdfData = nil }
        document.extractedText = text
        document.textSource = textSource
        document.documentDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!
        context.insert(document)
        return document
    }

    // MARK: ClipboardContent

    @Test func copyPDFGivesTheDataAndTheExportName() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let pdf = TestSupport.samplePDF()
        let document = makeDocument(in: context, pdf: pdf)

        #expect(ClipboardContent.canCopy(document, kind: .pdf))
        #expect(ClipboardContent.items(for: document, kind: .pdf) == [.pdf(pdf, fileName: "2026-09-03 Stromrechnung.pdf")])
    }

    @Test func copyTextGivesPlainText() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let vision = makeDocument(in: context, text: "  *Kein* Markdown\n| aus Vision |  ", textSource: "Apple Vision")
        let mistral = makeDocument(in: context, text: "# Rechnung\n| A | B |\n|---|---|\n| 1 | 2 |",
                                   textSource: DocumentProcessor.mistralTextSource)

        // Text from the PDF or Vision is copied as it is; Mistral's Markdown is converted.
        #expect(ClipboardContent.items(for: vision, kind: .text) == [.text("*Kein* Markdown\n| aus Vision |")])
        #expect(ClipboardContent.items(for: mistral, kind: .text) == [.text("Rechnung\nA\tB\n1\t2")])
    }

    @Test func nothingToCopyWithoutDataOrText() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let document = makeDocument(in: context, pdf: nil, text: " \n ")

        #expect(!ClipboardContent.canCopy(document, kind: .pdf))
        #expect(!ClipboardContent.canCopy(document, kind: .text))
        #expect(ClipboardContent.items(for: document, kind: .pdf).isEmpty)
        #expect(ClipboardContent.items(for: document, kind: .text).isEmpty)
    }

    @Test func nothingToCopyOnceDeleted() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let document = makeDocument(in: context, text: "Text")
        try context.save()
        context.delete(document)
        try context.save()

        #expect(!ClipboardContent.canCopy(document, kind: .pdf))
        #expect(ClipboardContent.items(for: document, kind: .text).isEmpty)
        #expect(DocumentActionRunner.actions(for: document) == nil)
        #expect(PrintJob(document: document) == nil)
    }

    // MARK: Pasteboard (a private one; the general pasteboard is never touched)

    #if os(macOS)
    @Test func copiedPDFIsDataAndAFileNamedLikeTheExport() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DocumentArchiveTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let folder = ExportFolder(root: try TestSupport.makeTemporaryDirectory())
        defer { folder.clear() }
        let generalChangeCount = NSPasteboard.general.changeCount
        let pdf = TestSupport.samplePDF()

        Clipboard.copy([.pdf(pdf, fileName: "2026-09-03 Stromrechnung.pdf")], to: pasteboard, folder: folder)

        #expect(pasteboard.data(forType: .pdf) == pdf)
        let url = try #require(pasteboard.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(url.lastPathComponent == "2026-09-03 Stromrechnung.pdf")
        #expect(url.path.hasPrefix(folder.root.path))
        #expect(try Data(contentsOf: url) == pdf)
        #expect(NSPasteboard.general.changeCount == generalChangeCount)
    }

    @Test func copiedTextIsAString() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DocumentArchiveTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        Clipboard.copy([.text("Rechnung\nA\tB")], to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "Rechnung\nA\tB")

        // Nothing to copy leaves the pasteboard as it was.
        Clipboard.copy([], to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "Rechnung\nA\tB")
    }
    #else
    @Test func copiedPDFAndTextReachTheNamedPasteboard() throws {
        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("DocumentArchiveTests.\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let pdf = TestSupport.samplePDF()

        Clipboard.copy([.pdf(pdf, fileName: "2026-09-03 Stromrechnung.pdf")], to: pasteboard)
        #expect(pasteboard.data(forPasteboardType: UTType.pdf.identifier) == pdf)

        Clipboard.copy([.text("Rechnung\nA\tB")], to: pasteboard)
        #expect(pasteboard.string == "Rechnung\nA\tB")
    }
    #endif

    // MARK: PDFTransfer

    @Test func fileRepresentationWritesTheNamedPDF() async throws {
        let folder = ExportFolder(root: try TestSupport.makeTemporaryDirectory())
        defer { folder.clear() }
        let pdf = TestSupport.samplePDF()
        let transfer = PDFTransfer(data: pdf, fileName: "Miete: Oktober", folder: folder)

        #expect(transfer.fileName == "Miete- Oktober.pdf")
        let url = try await transfer.writeFile()
        #expect(url.lastPathComponent == "Miete- Oktober.pdf")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == folder.root.standardizedFileURL.path)
        #expect(try Data(contentsOf: url) == pdf)

        // A second file with the same name goes into its own subfolder.
        let second = try await transfer.writeFile()
        #expect(second != url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        folder.clear()
        #expect(!FileManager.default.fileExists(atPath: folder.root.path))
    }

    @Test func transferLoadsTheDocumentsPDFOnlyWhenAsked() async throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let pdf = TestSupport.samplePDF()
        let document = makeDocument(in: context, pdf: pdf)
        let transfer = document.transfer(named: "Anderer Name")
        #expect(transfer.fileName == "Anderer Name.pdf")
        #expect(document.transfer?.fileName == "2026-09-03 Stromrechnung.pdf")

        // The data is read when the receiver asks, so a later edit is sent.
        let edited = TestSupport.samplePDF(lines: ["Neu"])
        document.pdfData = edited
        #expect(try await transfer.data() == edited)

        try context.save()
        context.delete(document)
        try context.save()
        await #expect(throws: PDFTransfer.TransferError.self) { try await transfer.data() }
    }

    @Test func noTransferWhileThePDFIsMissing() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let document = makeDocument(in: context, pdf: nil)
        #expect(document.transfer == nil)
    }

    // MARK: Print

    @Test func printJobHasTheTitleAndTheData() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let pdf = TestSupport.samplePDF()
        let document = makeDocument(in: context, pdf: pdf)

        let job = try #require(PrintJob(document: document))
        #expect(job.jobName == "Stromrechnung")
        #expect(job.data == pdf)
        #expect(job.pdf.pageCount == 1)
        #expect(DocumentActionRunner.actions(for: document)?.print != nil)
    }

    @Test func noPrintJobForUnreadableData() throws {
        #expect(PrintJob(data: Data("kein PDF".utf8), jobName: "A") == nil)
        #expect(PrintJob(data: Data(), jobName: "A") == nil)
        #expect(PrintJob(data: nil, jobName: "A") == nil)
        #expect(PrintJob(data: TestSupport.samplePDF(), jobName: "  ")?.jobName == String(localized: "Document"))

        let context = ModelContext(try TestSupport.makeContainer())
        let document = makeDocument(in: context, pdf: nil)
        #expect(PrintJob(document: document) == nil)
        // ⌘P stays disabled while the PDF is missing.
        #expect(DocumentActionRunner.actions(for: document)?.print == nil)
        #expect(DocumentActionRunner.actions(for: nil) == nil)
    }
}
