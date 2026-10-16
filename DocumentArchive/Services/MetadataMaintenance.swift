import Foundation
import SwiftData

/// Merges duplicate correspondents, document types and tags.
/// Duplicates appear when several documents are processed at the same time,
/// or when two devices create the same entry before iCloud has synced.
@MainActor
enum MetadataMaintenance {
    /// The oldest entry of a group of duplicates is kept; for equal `createdAt` the smallest `id`,
    /// so every device picks the same keeper. Removed duplicates are recorded with `mergedInto`
    /// (tombstones in the folder copy).
    /// - Returns: The number of duplicates removed.
    @discardableResult
    static func mergeDuplicates(in context: ModelContext) -> Int {
        mergeDuplicates(in: context, recorder: DocumentDeletion.recorder())
    }

    @discardableResult
    static func mergeDuplicates(in context: ModelContext, recorder: DeletionRecording?) -> Int {
        var removed = 0

        let correspondents = keeperOrder((try? context.fetch(FetchDescriptor<Correspondent>())) ?? [],
                                         createdAt: \.createdAt, id: \.id)
        for group in duplicates(correspondents, key: { normalized(SenderDetector.coreName($0.name)) }) {
            merge(Array(group.dropFirst()), into: group[0], in: context, recorder: recorder)
            removed += group.count - 1
        }

        let types = keeperOrder((try? context.fetch(FetchDescriptor<DocumentType>())) ?? [],
                                createdAt: \.createdAt, id: \.id)
        for group in duplicates(types, key: { normalized($0.name) }) {
            merge(Array(group.dropFirst()), into: group[0], in: context, recorder: recorder)
            removed += group.count - 1
        }

        removed += mergeDuplicateTags(in: context, recorder: recorder)
        // A merge can close a cycle that no single move created (A under B on one device, B under
        // A's duplicate on another); repair it in the same task.
        let repaired = TagHierarchy.breakCycles(in: context)

        if removed > 0 || repaired > 0 { try? context.save() }
        return removed
    }

    /// Tags are duplicates when they have the same parent and the same normalized name. Merged
    /// top-down: merging two roots moves their children under one keeper, where they become
    /// duplicates of each other, so the passes repeat until one merges nothing. Two identical
    /// trees created on two devices therefore become one tree in a single call.
    private static func mergeDuplicateTags(in context: ModelContext, recorder: DeletionRecording?) -> Int {
        var removed = 0
        while true {
            let tags = keeperOrder(((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter { !$0.isDeleted },
                                   createdAt: \.createdAt, id: \.id)
            let groups = duplicates(tags) { tag in
                let name = normalized(tag.name)
                return name.isEmpty ? "" : "\(tag.parent?.id.uuidString ?? "root")/\(name)"
            }
            guard !groups.isEmpty else { return removed }
            for group in groups {
                merge(Array(group.dropFirst()), into: group[0], in: context, recorder: recorder)
                removed += group.count - 1
            }
        }
    }

    // MARK: Merging (also used by the cleanup in #18)

    /// Moves the documents of `duplicates` to `keeper` and deletes the duplicates. Does not save.
    static func merge(_ duplicates: [Correspondent], into keeper: Correspondent, in context: ModelContext,
                      recorder: DeletionRecording?) {
        for duplicate in duplicates where duplicate.id != keeper.id {
            for document in duplicate.documents ?? [] { document.correspondent = keeper }
            didMerge(.correspondent, duplicate.id, into: DocumentFilter.Ref(keeper), in: context)
            MetadataDeletion.delete(duplicate, mergedInto: keeper, in: context, recorder: recorder)
        }
    }

    static func merge(_ duplicates: [DocumentType], into keeper: DocumentType, in context: ModelContext,
                      recorder: DeletionRecording?) {
        for duplicate in duplicates where duplicate.id != keeper.id {
            for document in duplicate.documents ?? [] { document.documentType = keeper }
            didMerge(.documentType, duplicate.id, into: DocumentFilter.Ref(keeper), in: context)
            MetadataDeletion.delete(duplicate, mergedInto: keeper, in: context, recorder: recorder)
        }
    }

    /// Also moves the duplicates' child tags under `keeper`. A child that is an ancestor of the
    /// keeper becomes a root instead, so the merge never creates a cycle.
    static func merge(_ duplicates: [Tag], into keeper: Tag, in context: ModelContext,
                      recorder: DeletionRecording?) {
        for duplicate in duplicates where duplicate.id != keeper.id {
            for document in duplicate.documents ?? [] {
                document.tags?.removeAll { $0.id == duplicate.id }
                if !document.hasTag(keeper) { document.toggleTag(keeper) }
            }
            for child in Array(duplicate.children ?? []) where child.id != keeper.id {
                child.parent = TagHierarchy.canMove(child, under: keeper) ? keeper : nil
            }
            if keeper.parent?.id == duplicate.id {
                // The keeper was nested in its own duplicate: it takes the duplicate's place.
                let parent = duplicate.parent
                keeper.parent = parent.flatMap { TagHierarchy.canMove(keeper, under: $0) ? $0 : nil }
            }
            didMerge(.tag, duplicate.id, into: DocumentFilter.Ref(keeper), in: context)
            MetadataDeletion.delete(duplicate, mergedInto: keeper, in: context, recorder: recorder)
        }
    }

    /// The merge hook: every merge of every kind passes here after the documents moved to the
    /// keeper and before the duplicate is deleted (which records the tombstone with `mergedInto`
    /// for the folder copy). Features that refer to tags, correspondents or types by id update
    /// their references here. `keeper` carries the keeper's id, name and merge key after the move
    /// (for tags: under its final parent).
    private static func didMerge(_ kind: ArchiveObjectKind, _ duplicate: UUID, into keeper: DocumentFilter.Ref,
                                 in context: ModelContext) {
        SavedViewMaintenance.replace(kind, oldID: duplicate, with: keeper, in: context)
    }

    /// Oldest `createdAt` first, then the smallest `id` – the same order on every device.
    static func keeperOrder<T>(_ items: [T], createdAt: (T) -> Date, id: (T) -> UUID) -> [T] {
        items.sorted { lhs, rhs in
            let (a, b) = (createdAt(lhs), createdAt(rhs))
            return a != b ? a < b : id(lhs).uuidString < id(rhs).uuidString
        }
    }

    // MARK: Duplicate documents

    /// Groups of documents with identical file content, oldest first.
    static func duplicateDocumentGroups(_ documents: [Document]) -> [[Document]] {
        duplicates(documents.filter(\.isAlive).sorted { $0.createdAt < $1.createdAt }, key: \.contentHash)
    }

    /// Removes duplicate documents. The oldest stays and takes over details it is missing
    /// (correspondent, type, tags, notes, favorite, ASN) from the duplicates.
    /// - Returns: The number of documents deleted.
    @discardableResult
    static func removeDuplicateDocuments(in context: ModelContext) -> Int {
        removeDuplicateDocuments(in: context, recorder: DocumentDeletion.recorder())
    }

    @discardableResult
    static func removeDuplicateDocuments(in context: ModelContext, recorder: DeletionRecording?) -> Int {
        guard let documents = try? context.fetch(FetchDescriptor<Document>()) else { return 0 }
        var removed: [Document] = []
        for group in duplicateDocumentGroups(documents) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                if keeper.correspondent == nil { keeper.correspondent = duplicate.correspondent }
                if keeper.documentType == nil { keeper.documentType = duplicate.documentType }
                if keeper.archiveSerialNumber == nil { keeper.archiveSerialNumber = duplicate.archiveSerialNumber }
                if keeper.notes.isEmpty { keeper.notes = duplicate.notes }
                if duplicate.isFavorite { keeper.isFavorite = true }
                for tag in duplicate.tags ?? [] where !keeper.hasTag(tag) { keeper.toggleTag(tag) }
                removed.append(duplicate)
            }
        }
        DocumentDeletion.delete(removed, in: context, recorder: recorder)
        return removed.count
    }

    /// Groups with more than one entry, each in input order (oldest first).
    private static func duplicates<T>(_ items: [T], key: (T) -> String) -> [[T]] {
        var groups: [String: [T]] = [:]
        var order: [String] = []
        for item in items {
            let k = key(item)
            guard !k.isEmpty else { continue }
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    /// Case, diacritics and width folded, trimmed: the name part of every merge key.
    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
