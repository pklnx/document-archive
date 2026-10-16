import Foundation
import SwiftData

/// An explicit deletion, recorded at the moment the user (or a merge) deletes something. The
/// folder copy writes tombstones only from these records, never by comparing what is missing:
/// an empty or replaced local store must not delete anything on other devices.
struct DeletionRecord: Codable, Equatable, Sendable {
    var id: UUID
    var kind: ArchiveObjectKind
    var deletedAt: Date
    /// For merged tags, correspondents and document types: the object that took over.
    var mergedInto: UUID?
}

/// Receives explicit deletions (`ArchiveMirrorStateStore` while the folder copy is on).
@MainActor
protocol DeletionRecording: AnyObject {
    func record(_ deletions: [DeletionRecord])
}

/// **The only way the app deletes documents.** Every delete action (list, detail view, bulk
/// delete, duplicate removal, and later features such as #10's "delete originals after
/// merging") goes through `delete(_:in:)`, so the deletion reaches the folder copy as a tombstone.
/// Deleting through `ModelContext.delete` directly would leave the document in the folder.
@MainActor
enum DocumentDeletion {
    /// Where deletions are recorded by default: the folder copy, when it is on; otherwise `nil`.
    static var recorder: () -> DeletionRecording? = { nil }

    /// Records the documents as explicit deletions, then deletes them and saves once.
    /// Tags, correspondents and document types stay.
    static func delete(_ documents: [Document], in context: ModelContext) {
        delete(documents, in: context, recorder: recorder())
    }

    /// - Parameter recorder: `nil` deletes without recording (no folder copy).
    static func delete(_ documents: [Document], in context: ModelContext,
                       recorder: DeletionRecording?, now: Date = Date()) {
        let alive = documents.filter(\.isAlive)
        guard !alive.isEmpty else { return }
        recorder?.record(alive.map { DeletionRecord(id: $0.id, kind: .document, deletedAt: now) })
        for document in alive {
            context.delete(document)
        }
        try? context.save()
    }
}

/// Deletes tags, correspondents, document types (sidebar, `MetadataMaintenance` merges) and saved
/// views, and records the deletion like `DocumentDeletion`, with `mergedInto` for merges.
@MainActor
enum MetadataDeletion {
    /// Deletes the object without saving; the caller saves (merges save once at the end).
    /// `recorder`: usually `DocumentDeletion.recorder()`.
    static func delete(_ tag: Tag, mergedInto keeper: Tag? = nil, in context: ModelContext,
                       recorder: DeletionRecording?, now: Date = Date()) {
        recorder?.record([DeletionRecord(id: tag.id, kind: .tag, deletedAt: now, mergedInto: keeper?.id)])
        context.delete(tag)
    }

    static func delete(_ correspondent: Correspondent, mergedInto keeper: Correspondent? = nil, in context: ModelContext,
                       recorder: DeletionRecording?, now: Date = Date()) {
        recorder?.record([DeletionRecord(id: correspondent.id, kind: .correspondent, deletedAt: now, mergedInto: keeper?.id)])
        context.delete(correspondent)
    }

    static func delete(_ type: DocumentType, mergedInto keeper: DocumentType? = nil, in context: ModelContext,
                       recorder: DeletionRecording?, now: Date = Date()) {
        recorder?.record([DeletionRecord(id: type.id, kind: .documentType, deletedAt: now, mergedInto: keeper?.id)])
        context.delete(type)
    }

    /// Saved views (#14): the folder copy writes a tombstone for the view's record.
    static func delete(_ view: SavedView, in context: ModelContext, recorder: DeletionRecording?, now: Date = Date()) {
        recorder?.record([DeletionRecord(id: view.id, kind: .savedView, deletedAt: now)])
        context.delete(view)
    }
}
