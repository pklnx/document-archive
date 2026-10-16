import Foundation
import SwiftData

/// Keeps saved views (#14) consistent: references after merges, order, deletion.
@MainActor
enum SavedViewMaintenance {
    /// Rewrites every reference to `oldID` to the keeper (id, name and key). Registered in the merge
    /// hook (`MetadataMaintenance.didMerge`), so it covers the automatic `mergeDuplicates` at launch
    /// and every later merge. A view that already referred to the keeper keeps one reference.
    /// Writes only the views that change; does not save.
    static func replace(_ kind: ArchiveObjectKind, oldID: UUID, with keeper: DocumentFilter.Ref,
                        in context: ModelContext) {
        guard let views = try? context.fetch(FetchDescriptor<SavedView>()) else { return }
        for view in views where !view.isDeleted {
            var filter = view.filter
            switch kind {
            case .tag:
                filter.tags = replaced(filter.tags, oldID: oldID, with: keeper)
                filter.excludedTags = replaced(filter.excludedTags, oldID: oldID, with: keeper)
            case .correspondent:
                filter.correspondents = replaced(filter.correspondents, oldID: oldID, with: keeper)
            case .documentType:
                filter.documentTypes = replaced(filter.documentTypes, oldID: oldID, with: keeper)
            case .document, .savedView:
                return
            }
            view.filter = filter
        }
    }

    private static func replaced(_ refs: [DocumentFilter.Ref], oldID: UUID,
                                 with keeper: DocumentFilter.Ref) -> [DocumentFilter.Ref] {
        guard refs.contains(where: { $0.id == oldID }) else { return refs }
        var result: [DocumentFilter.Ref] = []
        for ref in refs {
            let new = ref.id == oldID ? keeper : ref
            if !result.contains(where: { $0.id == new.id }) { result.append(new) }
        }
        return result
    }

    // MARK: Order

    /// The sidebar order: `sortIndex`, then `createdAt`, then `id`, the same on every device.
    static func sorted(_ views: [SavedView]) -> [SavedView] {
        views.filter { !$0.isDeleted }.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Moves views like `List.onMove` and renumbers all of them 0…n (only changed indexes are
    /// written). Does not save.
    static func move(_ views: [SavedView], fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = sorted(views)
        let moving = source.sorted().filter { $0 < ordered.count }.map { ordered[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where index < ordered.count { ordered.remove(at: index) }
        ordered.insert(contentsOf: moving, at: min(max(insertAt, 0), ordered.count))
        for (index, view) in ordered.enumerated() where view.sortIndex != index {
            view.sortIndex = index
        }
    }

    /// The index for a new view: after the last one.
    static func nextSortIndex(after views: [SavedView]) -> Int {
        (views.filter { !$0.isDeleted }.map(\.sortIndex).max() ?? -1) + 1
    }

    // MARK: Sidebar

    /// "Duplicate": a copy with the same symbol and the exact stored filter (also keys and values
    /// of newer versions), placed after the last view. Does not save.
    @discardableResult
    static func duplicate(_ view: SavedView, among views: [SavedView], in context: ModelContext) -> SavedView {
        let copy = SavedView(name: copyName(of: view), symbol: view.symbol, sortIndex: nextSortIndex(after: views))
        copy.filterJSON = view.filterJSON
        context.insert(copy)
        return copy
    }

    static func copyName(of view: SavedView) -> String {
        String(localized: "\(view.name) Copy")
    }

    /// The sidebar counts: for each view, its documents among `documents` (the base list after the
    /// central exclusions). One filter decode and one `FilterContext` per view, one pass over the
    /// documents per view.
    static func counts(of views: [SavedView], documents: [Document], tags: [Tag], correspondents: [Correspondent],
                       documentTypes: [DocumentType], now: Date = Date()) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for view in views where !view.isDeleted {
            let filter = view.filter
            let context = FilterContext(filter: filter, tags: tags, correspondents: correspondents,
                                        documentTypes: documentTypes, now: now)
            counts[view.id] = documents.reduce(0) { $0 + (filter.matches($1, context: context) ? 1 : 0) }
        }
        return counts
    }
}
