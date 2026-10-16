import Foundation

/// The documents selected in the list: a `Set<Document.ID>` (the documents' `UUID`).
///
/// This is the shared selection contract for every feature that acts on selected documents
/// (bulk actions here, later #13, #19, #20, #22):
///
/// - `ContentView` owns the set and passes it to `List(selection:)`. Rows are tagged with their
///   `Document.ID` by `ForEach`; there is no `NavigationLink(value:)`. The UUID is stable across
///   saves and devices, unlike a `PersistentIdentifier`, which is temporary until the first save.
/// - One selected document opens in the detail column; two or more show `BulkActionsView`.
/// - The set may only contain documents the user **sees**: it is pruned when the search, the
///   sidebar filter or the visible list changes (`pruned(_:to:)`), and actions always work on
///   `resolve(_:in:)` of the visible documents, so a hidden document is never edited or deleted.
///   An action that moves documents out of the current list (e.g. "Mark as Done" in the inbox)
///   therefore ends their selection; that is intended.
enum DocumentSelection {
    /// The selected documents among the visible ones, in list order. IDs of documents that are
    /// hidden or deleted are left out.
    static func resolve(_ selection: Set<Document.ID>, in visible: [Document]) -> [Document] {
        guard !selection.isEmpty else { return [] }
        return visible.filter { $0.isAlive && selection.contains($0.id) }
    }

    /// The selection without IDs that are not visible any more.
    static func pruned(_ selection: Set<Document.ID>, to visible: [Document]) -> Set<Document.ID> {
        guard !selection.isEmpty else { return selection }
        return Set(resolve(selection, in: visible).map(\.id))
    }
}
