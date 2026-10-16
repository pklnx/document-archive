import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Bulk actions on a selection of documents, and the selection rules (`DocumentSelection`).
@Suite @MainActor struct BulkEditorTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Before every change, so a new `modifiedAt` is easy to tell apart.
    let oldDate = Date(timeIntervalSinceReferenceDate: 0)

    init() throws {
        container = try TestSupport.makeContainer()
    }

    /// Already processed documents, newest first in the list ("added" order).
    private func makeDocuments(_ titles: [String]) throws -> [Document] {
        let documents = titles.enumerated().map { index, title in
            let document = Document(title: title, pdfData: TestSupport.samplePDF(lines: [title]), source: .file)
            document.isProcessing = false
            document.createdAt = Date(timeIntervalSinceReferenceDate: 1_000_000 - Double(index) * 1000)
            document.modifiedAt = oldDate
            context.insert(document)
            return document
        }
        try context.save()
        return documents
    }

    private func allDocuments() throws -> [Document] {
        try context.fetch(FetchDescriptor<Document>())
    }

    // MARK: Tags

    @Test func addTagAddsItOnceAndTouchesOnlyChangedDocuments() throws {
        let documents = try makeDocuments(["A", "B", "C"])
        let tag = ArchiveTag(name: "Tax")
        context.insert(tag)
        documents[1].tags = [tag]
        try context.save()

        BulkEditor.addTag(tag, to: documents, in: context)

        #expect(documents.allSatisfy { ($0.tags ?? []).filter { $0.id == tag.id }.count == 1 })
        #expect(documents.map { $0.modifiedAt != oldDate } == [true, false, true])
        #expect(!context.hasChanges, "saved")
    }

    @Test func removeTagKeepsUntouchedDocuments() throws {
        let documents = try makeDocuments(["A", "B", "C"])
        let tag = ArchiveTag(name: "Tax")
        let other = ArchiveTag(name: "Home")
        context.insert(tag)
        context.insert(other)
        documents[0].tags = [tag, other]
        documents[2].tags = [tag]
        try context.save()

        BulkEditor.removeTag(tag, from: documents, in: context)

        #expect(documents.allSatisfy { !$0.hasTag(tag) })
        #expect(documents[0].hasTag(other))
        #expect(documents.map { $0.modifiedAt != oldDate } == [true, false, true])
    }

    @Test func tagStateIsAllSomeOrNone() throws {
        let documents = try makeDocuments(["A", "B"])
        let tag = ArchiveTag(name: "Tax")
        context.insert(tag)

        #expect(BulkEditor.tagState(tag, in: documents) == .none)
        documents[0].tags = [tag]
        #expect(BulkEditor.tagState(tag, in: documents) == .some)
        documents[1].tags = [tag]
        #expect(BulkEditor.tagState(tag, in: documents) == .all)
    }

    // MARK: Correspondent and type

    @Test func setCorrespondentWithAValueAndWithNil() throws {
        let documents = try makeDocuments(["A", "B"])
        let bank = Correspondent(name: "Musterbank")
        context.insert(bank)
        documents[1].correspondent = bank
        try context.save()

        BulkEditor.setCorrespondent(bank, for: documents, in: context)
        #expect(documents.allSatisfy { $0.correspondent?.id == bank.id })
        #expect(documents.map { $0.modifiedAt != oldDate } == [true, false])

        documents.forEach { $0.modifiedAt = oldDate }
        BulkEditor.setCorrespondent(nil, for: documents, in: context)
        #expect(documents.allSatisfy { $0.correspondent == nil })
        #expect(documents.allSatisfy { $0.modifiedAt != oldDate })
        #expect(try context.fetch(FetchDescriptor<Correspondent>()).count == 1, "the correspondent itself stays")
    }

    @Test func setDocumentTypeWithAValueAndWithNil() throws {
        let documents = try makeDocuments(["A", "B"])
        let invoice = DocumentType(name: "Invoice", symbol: "doc.text")
        context.insert(invoice)
        documents[0].documentType = invoice
        try context.save()

        BulkEditor.setDocumentType(invoice, for: documents, in: context)
        #expect(documents.allSatisfy { $0.documentType?.id == invoice.id })
        #expect(documents.map { $0.modifiedAt != oldDate } == [false, true])

        documents.forEach { $0.modifiedAt = oldDate }
        BulkEditor.setDocumentType(nil, for: documents, in: context)
        #expect(documents.allSatisfy { $0.documentType == nil })
        #expect(documents.allSatisfy { $0.modifiedAt != oldDate })
    }

    // MARK: Inbox and favorites

    @Test func setInboxAndFavoriteOnAMixedSelection() throws {
        let documents = try makeDocuments(["A", "B", "C"])
        documents[1].isInbox = false
        documents[2].isFavorite = true
        try context.save()

        BulkEditor.setInbox(false, for: documents, in: context)
        #expect(documents.allSatisfy { !$0.isInbox })
        #expect(documents.map { $0.modifiedAt != oldDate } == [true, false, true])

        documents.forEach { $0.modifiedAt = oldDate }
        BulkEditor.setFavorite(true, for: documents, in: context)
        #expect(documents.allSatisfy { $0.isFavorite })
        #expect(documents.map { $0.modifiedAt != oldDate } == [true, true, false])
    }

    // MARK: Delete

    @Test func deleteRemovesExactlyTheSelectedDocuments() throws {
        let documents = try makeDocuments(["A", "B", "C"])
        let tag = ArchiveTag(name: "Tax")
        let bank = Correspondent(name: "Musterbank")
        context.insert(tag)
        context.insert(bank)
        documents.forEach { $0.tags = [tag]; $0.correspondent = bank }
        try context.save()

        DocumentDeletion.delete([documents[0], documents[2]], in: context)

        #expect(try allDocuments().map(\.title) == ["B"])
        #expect(try context.fetch(FetchDescriptor<ArchiveTag>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Correspondent>()).count == 1)
    }

    // MARK: Selection

    /// Review finding: select 3, narrow the search so 1 is hidden, delete → only the 2 visible
    /// ones are deleted.
    @Test func hiddenDocumentsAreNeitherResolvedNorDeleted() throws {
        let documents = try makeDocuments(["Electricity bill", "Water bill", "Account statement"])
        let selection = Set(documents.map(\.id))

        let visible = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "bill", sort: .added)
        let resolved = DocumentSelection.resolve(selection, in: visible)
        #expect(resolved.map(\.title) == ["Electricity bill", "Water bill"])
        #expect(DocumentSelection.pruned(selection, to: visible) == Set(resolved.map(\.id)))

        DocumentDeletion.delete(resolved, in: context)
        #expect(try allDocuments().map(\.title) == ["Account statement"])
    }

    @Test func resolutionDropsDeletedIDsAndFollowsListOrder() throws {
        let documents = try makeDocuments(["Charlie", "Alpha", "Bravo"])
        let deleted = documents[0]
        let selection: Set<Document.ID> = [documents[2].id, deleted.id, documents[1].id, UUID()]
        context.delete(deleted)
        try context.save()

        let byTitle = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "", sort: .title)
        #expect(DocumentSelection.resolve(selection, in: byTitle).map(\.title) == ["Alpha", "Bravo"])
        let byAdded = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "", sort: .added)
        #expect(DocumentSelection.resolve(selection, in: byAdded).map(\.title) == ["Alpha", "Bravo"])
        #expect(DocumentSelection.pruned(selection, to: byTitle) == [documents[1].id, documents[2].id])
        #expect(DocumentSelection.resolve([], in: byTitle).isEmpty)
    }

    // MARK: The open document

    /// What `ContentView` does when the visible list changes through an edit (outside edit mode).
    private func prunedAfterEdit(_ selection: Set<Document.ID>, filter: SidebarItem,
                                 searchText: String) throws -> Set<Document.ID> {
        let all = try allDocuments()
        let visible = filter.visibleDocuments(in: all, searchText: searchText, sort: .added)
        return DocumentSelection.pruned(selection, to: visible,
                                        keepingOpen: DocumentSelection.openDocument(selection, in: all))
    }

    /// Review finding: the document matched the search only through its correspondent;
    /// changing the correspondent in the inspector closed it.
    @Test func openDocumentFoundThroughItsCorrespondentStaysOpenWhenItIsChanged() throws {
        let document = try makeDocuments(["Electricity bill"])[0]
        let stadtwerke = Correspondent(name: "Stadtwerke")
        let bank = Correspondent(name: "Musterbank")
        context.insert(stadtwerke)
        context.insert(bank)
        document.correspondent = stadtwerke
        let selection: Set<Document.ID> = [document.id]

        document.correspondent = bank
        #expect(try prunedAfterEdit(selection, filter: .all, searchText: "Stadtwerke") == selection)
        #expect(DocumentSelection.openDocument(selection, in: try allDocuments())?.id == document.id)

        // A new search that hides it closes it.
        let visible = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "Stadtwerk", sort: .added)
        #expect(DocumentSelection.pruned(selection, to: visible).isEmpty)
    }

    /// Review finding: editing the title so that it no longer matches the search closed the
    /// document after the first keystroke.
    @Test func openDocumentStaysOpenWhileItsTitleIsEdited() throws {
        let document = try makeDocuments(["Electricity bill"])[0]
        let selection: Set<Document.ID> = [document.id]
        document.title = "Electricity"
        #expect(try prunedAfterEdit(selection, filter: .all, searchText: "bill") == selection)
    }

    /// Review finding: with a sidebar filter on a type, changing the type closed the document.
    @Test func openDocumentStaysOpenWhenTheFilteredFieldChanges() throws {
        let document = try makeDocuments(["Electricity bill"])[0]
        let invoice = DocumentType(name: "Invoice", symbol: "doc.text")
        let letter = DocumentType(name: "Letter", symbol: "envelope")
        context.insert(invoice)
        context.insert(letter)
        document.documentType = invoice
        let selection: Set<Document.ID> = [document.id]

        document.documentType = letter
        #expect(try prunedAfterEdit(selection, filter: .documentType(invoice), searchText: "") == selection)
    }

    @Test func deletedOpenDocumentIsDropped() throws {
        let documents = try makeDocuments(["A", "B"])
        let selection: Set<Document.ID> = [documents[0].id]
        DocumentDeletion.delete([documents[0]], in: context)
        #expect(DocumentSelection.openDocument(selection, in: try allDocuments()) == nil)
        #expect(try prunedAfterEdit(selection, filter: .all, searchText: "").isEmpty)
    }

    /// The exception is only for one open document: a bulk selection is still pruned.
    @Test func bulkSelectionIsStillPrunedAfterAnEdit() throws {
        let documents = try makeDocuments(["A", "B", "C"])
        let selection = Set(documents.prefix(2).map(\.id))
        BulkEditor.setInbox(false, for: [documents[0]], in: context)
        #expect(try prunedAfterEdit(selection, filter: .inbox, searchText: "") == [documents[1].id])
    }

    /// Review finding (#31): a hidden open document stayed in the selection when the user added
    /// rows (iOS edit mode, ⌘-click) and joined the bulk selection once the search was cleared.
    @Test func hiddenOpenDocumentDoesNotJoinABulkSelection() throws {
        let documents = try makeDocuments(["Electricity bill", "Water bill", "Tax return"])
        let open = documents[0]
        var selection: Set<Document.ID> = [open.id]
        // An edit hides the open document from the search "bill"; it stays open.
        open.title = "Electricity"
        selection = try prunedAfterEdit(selection, filter: .all, searchText: "bill")
        #expect(selection == [open.id])
        let visible = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "bill", sort: .added)

        // One ID from the list (re-selecting the open one) is kept as it is.
        #expect(DocumentSelection.fromList([open.id], visible: visible) == [open.id])
        // The user adds "Water bill": the hidden document is dropped.
        selection = DocumentSelection.fromList(selection.union([documents[1].id]), visible: visible)
        #expect(selection == [documents[1].id])

        // Clearing the search does not bring it back into the selection.
        let all = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "", sort: .added)
        #expect(DocumentSelection.resolve(selection, in: all).map(\.id) == [documents[1].id])
    }

    @Test func enteringEditModeDropsAHiddenOpenDocument() throws {
        let documents = try makeDocuments(["Electricity bill", "Water bill"])
        documents[0].title = "Electricity"
        let visible = SidebarItem.all.visibleDocuments(in: try allDocuments(), searchText: "bill", sort: .added)
        #expect(DocumentSelection.enteringEditMode([documents[0].id], visible: visible).isEmpty)
        #expect(DocumentSelection.enteringEditMode([documents[1].id], visible: visible) == [documents[1].id])
    }

    /// An action that moves documents out of the current list (done in the inbox) ends their
    /// selection.
    @Test func markingAsDoneInTheInboxEndsTheSelection() throws {
        let documents = try makeDocuments(["A", "B"])
        let selection = Set(documents.map(\.id))
        BulkEditor.setInbox(false, for: documents, in: context)
        let visible = SidebarItem.inbox.visibleDocuments(in: try allDocuments(), searchText: "", sort: .added)
        #expect(DocumentSelection.pruned(selection, to: visible).isEmpty)
    }
}

extension GlobalStateTests {
    /// Bulk "Analyze again": one document after another, cancellable.
    @Suite @MainActor struct BulkReanalysisTests {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }

        init() throws {
            container = try TestSupport.makeContainer()
        }

        private func makeDocuments(_ count: Int) throws -> [Document] {
            let documents = (1...count).map { index in
                let document = Document(title: "Letter \(index)", pdfData: TestSupport.samplePDF(lines: ["Letter \(index)"]),
                                        source: .file)
                document.isProcessing = false
                context.insert(document)
                return document
            }
            try context.save()
            return documents
        }

        /// Which document an OCR request was for (its PDF is in the request body).
        private func documentIndex(of body: Data, among documents: [Document]) -> Int? {
            let json = MistralStub.json(body)
            let url = (json["document"] as? [String: Any])?["document_url"] as? String ?? ""
            return documents.firstIndex { url.contains($0.pdfData!.base64EncodedString()) }
        }

        @Test func analyzesOneDocumentAfterAnother() async throws {
            MistralStub.install(config: MistralStub.config(useOCR: true, useLLM: false)) { _, _ in
                .json(["pages": [["index": 0, "markdown": "Text from Mistral"]]])
            }
            defer { MistralStub.reset() }
            MistralStub.delay = 0.2
            let documents = try makeDocuments(3)

            // Watch how many documents are processed at the same time.
            var maxProcessing = 0
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    maxProcessing = max(maxProcessing, documents.filter(\.isProcessing).count)
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            var reported: [Int] = []
            await BulkEditor.reanalyze(documents, context: context) { done, total in
                #expect(total == 3)
                reported.append(done)
            }
            watcher.cancel()

            #expect(maxProcessing == 1)
            #expect(reported == [1, 2, 3])
            #expect(MistralStub.requests.map { documentIndex(of: $0.body, among: documents) } == [0, 1, 2])
            #expect(documents.allSatisfy { $0.extractedText == "Text from Mistral" && !$0.isProcessing })
        }

        /// Documents still being processed are skipped but counted, so "x of n" never jumps.
        @Test func skippedDocumentsCountAsDone() async throws {
            MistralStub.install(config: MistralStub.config(useOCR: true, useLLM: false)) { _, _ in
                .json(["pages": [["index": 0, "markdown": "Text from Mistral"]]])
            }
            defer { MistralStub.reset() }
            let documents = try makeDocuments(3)
            documents[1].isProcessing = true

            var reported: [String] = []
            await BulkEditor.reanalyze(documents, context: context) { done, total in
                reported.append("\(done)/\(total)")
            }

            #expect(reported == ["1/3", "2/3", "3/3"])
            #expect(MistralStub.requests.map { documentIndex(of: $0.body, among: documents) } == [0, 2])
            #expect(documents[1].extractedText.isEmpty)
        }

        @Test func cancellingFinishesTheCurrentDocumentAndSkipsTheRest() async throws {
            MistralStub.install(config: MistralStub.config(useOCR: true, useLLM: false)) { _, _ in
                .json(["pages": [["index": 0, "markdown": "Text from Mistral"]]])
            }
            defer { MistralStub.reset() }
            let documents = try makeDocuments(3)
            let context = context

            let task = Task { @MainActor in
                await BulkEditor.reanalyze(documents, context: context) { done, _ in
                    if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            await task.value

            #expect(MistralStub.requests.count == 1)
            #expect(documents[0].extractedText == "Text from Mistral")
            #expect(documents[1...].allSatisfy { $0.extractedText.isEmpty && !$0.isProcessing })
        }
    }
}
