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
///   sidebar filter or the visible list changes (`pruned(_:to:keepingOpen:)`), and bulk actions
///   always work on `resolve(_:in:)` of the visible documents, so a hidden document is never
///   edited or deleted in bulk. A bulk action that moves documents out of the current list
///   (e.g. "Mark as Done" in the inbox) therefore ends their selection; that is intended.
/// - One exception: the **open document** (exactly one selected, outside edit mode) stays open
///   when an edit in it makes it drop out of the list (a new title, correspondent, type or tag
///   while a search or a filter is active). It is closed only when the search text or the
///   sidebar entry changes, or when it is deleted.
enum DocumentSelection {
    /// The selected documents among the visible ones, in list order. IDs of documents that are
    /// hidden or deleted are left out.
    static func resolve(_ selection: Set<Document.ID>, in visible: [Document]) -> [Document] {
        guard !selection.isEmpty else { return [] }
        return visible.filter { $0.isAlive && selection.contains($0.id) }
    }

    /// The one selected document, wherever it is (also when an edit hid it from the list);
    /// `nil` when none or several are selected, or when it was deleted.
    static func openDocument(_ selection: Set<Document.ID>, in allDocuments: [Document]) -> Document? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return allDocuments.first { $0.id == id && $0.isAlive }
    }

    /// The selection without IDs that are not visible any more.
    /// - Parameter open: The open document (`openDocument`, outside edit mode). It stays
    ///   selected although it is hidden, because the visible list changed through an edit of it.
    ///   Pass `nil` when the search text changed, so a hidden document is closed.
    static func pruned(_ selection: Set<Document.ID>, to visible: [Document],
                       keepingOpen open: Document? = nil) -> Set<Document.ID> {
        guard !selection.isEmpty else { return selection }
        if let open, open.isAlive, selection == [open.id] { return selection }
        return Set(resolve(selection, in: visible).map(\.id))
    }
}
