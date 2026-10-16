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
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                for document in duplicate.documents ?? [] { document.correspondent = keeper }
                MetadataDeletion.delete(duplicate, mergedInto: keeper, in: context, recorder: recorder)
                removed += 1
            }
        }

        let types = keeperOrder((try? context.fetch(FetchDescriptor<DocumentType>())) ?? [],
                                createdAt: \.createdAt, id: \.id)
        for group in duplicates(types, key: { normalized($0.name) }) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                for document in duplicate.documents ?? [] { document.documentType = keeper }
                MetadataDeletion.delete(duplicate, mergedInto: keeper, in: context, recorder: recorder)
                removed += 1
            }
        }

        let tags = keeperOrder((try? context.fetch(FetchDescriptor<Tag>())) ?? [], createdAt: \.createdAt, id: \.id)
        for group in duplicates(tags, key: { normalized($0.name) }) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                for document in duplicate.documents ?? [] {
                    document.tags?.removeAll { $0.id == duplicate.id }
                    if !document.hasTag(keeper) { document.toggleTag(keeper) }
                }
                MetadataDeletion.delete(duplicate, mergedInto: keeper, in: context, recorder: recorder)
                removed += 1
            }
        }

        if removed > 0 { try? context.save() }
        return removed
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

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
