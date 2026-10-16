import Foundation
import SwiftData

/// Changes several documents at once (bulk actions of the list selection, see `DocumentSelection`).
///
/// Every action saves once, and only documents that actually change get a new `modifiedAt`, so
/// sync and "Modified" only see real changes.
@MainActor
enum BulkEditor {
    /// Whether a tag is on all, some or none of the documents (tri-state menu items).
    enum TagState: Equatable {
        case all, some, none
    }

    static func tagState(_ tag: Tag, in documents: [Document]) -> TagState {
        let tagged = documents.filter { $0.hasTag(tag) }.count
        if tagged == 0 { return .none }
        return tagged == documents.count ? .all : .some
    }

    static func addTag(_ tag: Tag, to documents: [Document], in context: ModelContext) {
        apply(to: documents, in: context) { document in
            guard !document.hasTag(tag) else { return false }
            if document.tags == nil { document.tags = [] }
            document.tags?.append(tag)
            return true
        }
    }

    static func removeTag(_ tag: Tag, from documents: [Document], in context: ModelContext) {
        apply(to: documents, in: context) { document in
            guard document.hasTag(tag) else { return false }
            document.tags?.removeAll { $0.id == tag.id }
            return true
        }
    }

    /// `nil` removes the correspondent.
    static func setCorrespondent(_ correspondent: Correspondent?, for documents: [Document], in context: ModelContext) {
        apply(to: documents, in: context) { document in
            guard document.correspondent?.id != correspondent?.id else { return false }
            document.correspondent = correspondent
            return true
        }
    }

    /// `nil` removes the document type.
    static func setDocumentType(_ type: DocumentType?, for documents: [Document], in context: ModelContext) {
        apply(to: documents, in: context) { document in
            guard document.documentType?.id != type?.id else { return false }
            document.documentType = type
            return true
        }
    }

    static func setInbox(_ isInbox: Bool, for documents: [Document], in context: ModelContext) {
        apply(to: documents, in: context) { document in
            guard document.isInbox != isInbox else { return false }
            document.isInbox = isInbox
            return true
        }
    }

    static func setFavorite(_ isFavorite: Bool, for documents: [Document], in context: ModelContext) {
        apply(to: documents, in: context) { document in
            guard document.isFavorite != isFavorite else { return false }
            document.isFavorite = isFavorite
            return true
        }
    }

    /// Deletes the documents (on all devices). Tags, correspondents and types stay.
    static func delete(_ documents: [Document], in context: ModelContext) {
        for document in documents where document.isAlive {
            context.delete(document)
        }
        try? context.save()
    }

    /// Text recognition and auto-assignment again, **one document at a time**: Vision at full
    /// resolution and Mistral requests (when turned on in the settings) never run in parallel.
    ///
    /// Cancelling the calling task finishes the current document and skips the rest. Documents
    /// that are already being processed or have no PDF yet (still downloading) are skipped and
    /// count as done, so the total stays the number of documents. Each PDF is loaded only when
    /// its turn comes.
    /// - Parameter progress: Called after each document with the number done and the total.
    static func reanalyze(_ documents: [Document], context: ModelContext,
                          progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) async {
        for (index, document) in documents.enumerated() {
            guard !Task.isCancelled else { return }
            if document.isAlive, !document.isProcessing, document.pdfData != nil {
                // A separate task, so cancelling stops before the next document instead of
                // interrupting this one halfway (e.g. in the middle of a Mistral request).
                await Task { await DocumentImporter.processAndWait(document, context: context, classify: true) }.value
            }
            progress(index + 1, documents.count)
        }
    }

    /// Runs `change` on every document, touches those it changed and saves once.
    private static func apply(to documents: [Document], in context: ModelContext, _ change: (Document) -> Bool) {
        var changed = false
        for document in documents where document.isAlive {
            if change(document) {
                document.touch()
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
