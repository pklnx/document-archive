import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// The sample data the UI tests start with (`-UITestSeed`). Only in DEBUG builds, like the tests.
@Suite @MainActor struct UITestSeedTests {
    @Test func fillsTheStoreWithProcessedSampleDocuments() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext

        UITestSeed.fill(context)

        let documents = try context.fetch(FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        #expect(documents.map(\.title) == UITestSeed.documents.map(\.title))
        #expect(documents.allSatisfy { !$0.isProcessing && $0.pdfData != nil && $0.thumbnailData != nil })
        #expect(documents.allSatisfy { !$0.contentHash.isEmpty && $0.correspondent != nil && $0.documentType != nil })
        #expect(documents.filter(\.isInbox).count == UITestSeed.documents.filter(\.isInbox).count)
        #expect(documents.filter(\.isFavorite).map(\.title) == ["Medical invoice"])
        #expect(Set(documents.map(\.contentHash)).count == documents.count, "no sample is a duplicate of another")
        // Markdown notes (#19) on the first document only, rendered as heading, paragraph and tasks.
        #expect(documents.filter { !$0.notes.isEmpty }.map(\.title) == ["Electricity bill March"])
        #expect(MarkdownNotes.blocks(from: documents[0].notes).map(\.kind) == [
            .heading(level: 2), .paragraph, .task(isChecked: true, level: 0), .task(isChecked: false, level: 0),
        ])

        #expect(try context.fetchCount(FetchDescriptor<Correspondent>()) == UITestSeed.correspondents.count)
        #expect(try context.fetchCount(FetchDescriptor<DocumentType>()) == UITestSeed.documentTypes.count)
        let tags = try context.fetch(FetchDescriptor<ArchiveTag>(sortBy: [SortDescriptor(\.name)]))
        #expect(tags.map(\.name) == ["Auto", "Golf", "Important", "Tax"])
        #expect(tags.map(\.documentCount) == [1, 1, 2, 2])
        // Auto › Golf for the drill-down test; Auto's list shows both documents.
        let golf = try #require(tags.first { $0.name == "Golf" })
        #expect(TagHierarchy.displayPath(of: golf) == "Auto › Golf")
        let auto = try #require(golf.parent)
        #expect(Set(SidebarItem.tag(auto).visibleDocuments(in: documents, searchText: "", sort: .added).map(\.title))
                == ["Car insurance", "Golf inspection"])
        // A saved view (#14) for the UI test: the "Tax" documents, by title.
        let views = try context.fetch(FetchDescriptor<SavedView>())
        #expect(views.map(\.name) == [UITestSeed.savedViewName])
        let taxes = try #require(views.first)
        #expect(SidebarItem.savedView(taxes).visibleDocuments(in: documents, searchText: "", sort: .added).map(\.title)
                == ["Electricity bill March", "Medical invoice"])
    }

    @Test func seededChoiceFillsTheInMemoryStore() throws {
        let container = TestSupport.keepAlive(ArchiveStore.makeContainer(for: .inMemory(seed: true), migrate: {}).container)
        let count = try container.mainContext.fetchCount(FetchDescriptor<Document>())
        #expect(count == UITestSeed.documents.count)
        #expect(container.configurations.first?.isStoredInMemoryOnly == true)
    }

    @Test func unseededChoiceStaysEmpty() throws {
        let container = TestSupport.keepAlive(ArchiveStore.makeContainer(for: .inMemory(seed: false), migrate: {}).container)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Document>()) == 0)
    }
}
