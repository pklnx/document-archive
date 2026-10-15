import Foundation
import SwiftData

/// Merges duplicate correspondents, document types and tags.
/// Duplicates appear when several documents are processed at the same time,
/// or when two devices create the same entry before iCloud has synced.
@MainActor
enum MetadataMaintenance {
    /// - Returns: The number of duplicates removed.
    @discardableResult
    static func mergeDuplicates(in context: ModelContext) -> Int {
        var removed = 0

        let correspondents = (try? context.fetch(FetchDescriptor<Correspondent>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for group in duplicates(correspondents, key: { normalized(SenderDetector.coreName($0.name)) }) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                for document in duplicate.documents ?? [] { document.correspondent = keeper }
                context.delete(duplicate)
                removed += 1
            }
        }

        let types = (try? context.fetch(FetchDescriptor<DocumentType>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for group in duplicates(types, key: { normalized($0.name) }) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                for document in duplicate.documents ?? [] { document.documentType = keeper }
                context.delete(duplicate)
                removed += 1
            }
        }

        let tags = (try? context.fetch(FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for group in duplicates(tags, key: { normalized($0.name) }) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                for document in duplicate.documents ?? [] {
                    document.tags?.removeAll { $0.id == duplicate.id }
                    if !document.hasTag(keeper) { document.toggleTag(keeper) }
                }
                context.delete(duplicate)
                removed += 1
            }
        }

        if removed > 0 { try? context.save() }
        return removed
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
        guard let documents = try? context.fetch(FetchDescriptor<Document>()) else { return 0 }
        var removed = 0
        for group in duplicateDocumentGroups(documents) {
            let keeper = group[0]
            for duplicate in group.dropFirst() {
                if keeper.correspondent == nil { keeper.correspondent = duplicate.correspondent }
                if keeper.documentType == nil { keeper.documentType = duplicate.documentType }
                if keeper.archiveSerialNumber == nil { keeper.archiveSerialNumber = duplicate.archiveSerialNumber }
                if keeper.notes.isEmpty { keeper.notes = duplicate.notes }
                if duplicate.isFavorite { keeper.isFavorite = true }
                for tag in duplicate.tags ?? [] where !keeper.hasTag(tag) { keeper.toggleTag(tag) }
                context.delete(duplicate)
                removed += 1
            }
        }
        if removed > 0 { try? context.save() }
        return removed
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
