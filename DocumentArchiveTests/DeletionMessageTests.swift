import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Delete confirmations stay open while the object can be deleted elsewhere (sync from another
/// device, a second iPad window); their text must not read a deleted model's properties.
@MainActor @Suite struct DeletionMessageTests {
    @Test func documentMessageNamesTheDocument() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let document = Document(title: "Stromrechnung März", pdfData: Data(), source: .file)
        context.insert(document)

        #expect(DocumentDetailView.deleteMessage(for: document).contains("Stromrechnung März"))
    }

    @Test func documentMessageWithoutTitleOnceDeleted() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let document = Document(title: "Stromrechnung März", pdfData: Data(), source: .file)
        context.insert(document)
        try context.save()
        context.delete(document)
        try context.save()

        #expect(!DocumentDetailView.deleteMessage(for: document).contains("Stromrechnung März"))
    }

    @Test func sidebarTitlesNameTheObject() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let tag = ArchiveTag(name: "Steuer")
        let correspondent = Correspondent(name: "Stadtwerke")
        let type = DocumentType(name: "Rechnung")
        context.insert(tag)
        context.insert(correspondent)
        context.insert(type)

        #expect(SidebarView.PendingDeletion.tag(tag).title.contains("Steuer"))
        #expect(SidebarView.PendingDeletion.correspondent(correspondent).title.contains("Stadtwerke"))
        #expect(SidebarView.PendingDeletion.documentType(type).title.contains("Rechnung"))
    }

    @Test func sidebarTitlesWithoutNameOnceDeleted() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let tag = ArchiveTag(name: "Steuer")
        let correspondent = Correspondent(name: "Stadtwerke")
        let type = DocumentType(name: "Rechnung")
        context.insert(tag)
        context.insert(correspondent)
        context.insert(type)
        try context.save()
        context.delete(tag)
        context.delete(correspondent)
        context.delete(type)
        try context.save()

        #expect(!SidebarView.PendingDeletion.tag(tag).title.contains("Steuer"))
        #expect(!SidebarView.PendingDeletion.correspondent(correspondent).title.contains("Stadtwerke"))
        #expect(!SidebarView.PendingDeletion.documentType(type).title.contains("Rechnung"))
    }
}
