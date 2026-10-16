import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

@Suite struct DocumentModelTests {
    private func document(title: String, originalFileName: String = "", source: DocumentSource = .file) -> Document {
        Document(title: title, pdfData: Data(), source: source, originalFileName: originalFileName)
    }

    @Test func titleFromFileNameOrScanIsAutomatic() {
        #expect(document(title: "Invoice-0014", originalFileName: "Invoice-0014.pdf").hasAutomaticTitle)
        #expect(document(title: "Scan 15.10.2026, 14:30", source: .scan).hasAutomaticTitle)
        #expect(document(title: "Foto 15.10.2026, 14:30", source: .image).hasAutomaticTitle)
        #expect(document(title: "").hasAutomaticTitle)
    }

    @Test func editedTitleIsNotAutomatic() {
        #expect(!document(title: "Stromrechnung September", originalFileName: "Invoice-0014.pdf").hasAutomaticTitle)
    }

    @Test func searchNeedsEveryTerm() {
        let doc = document(title: "Rechnung")
        doc.extractedText = "Kundennummer 123456"
        doc.archiveSerialNumber = 42
        #expect(doc.matches("rechnung 123456"))
        #expect(doc.matches("ASN42"))
        #expect(doc.matches("  "))
        #expect(!doc.matches("rechnung vodafone"))
    }

    @Test func exportFileNameHasDateAndCorrespondentOnce() {
        let doc = document(title: "Rechnung: September/Oktober")
        doc.documentDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!
        doc.correspondent = Correspondent(name: "Stadtwerke")
        #expect(doc.exportFileName == "2026-09-03 Stadtwerke Rechnung- September-Oktober.pdf")

        doc.title = "Stadtwerke Abschlag"
        #expect(doc.exportFileName == "2026-09-03 Stadtwerke Abschlag.pdf")
    }

    @Test @MainActor func toggleTagAddsAndRemoves() throws {
        let container = try TestSupport.makeContainer()
        let doc = document(title: "A")
        let tag = ArchiveTag(name: "Steuer")
        container.mainContext.insert(doc)
        container.mainContext.insert(tag)
        doc.toggleTag(tag)
        #expect(doc.hasTag(tag))
        doc.toggleTag(tag)
        #expect(!doc.hasTag(tag))
    }

    /// #13: new tags are roots with the default symbol; older tags get the same defaults.
    @Test @MainActor func newTagDefaults() throws {
        let container = try TestSupport.makeContainer()
        let tag = ArchiveTag(name: "Plain")
        container.mainContext.insert(tag)
        try container.mainContext.save()
        #expect(tag.parent == nil)
        #expect(tag.children?.isEmpty == true)
        #expect(tag.symbol == "tag.fill")
    }
}
