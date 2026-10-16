import Foundation
import SwiftData

/// A saved view (smart filter, #14): a named `DocumentFilter` shown in the sidebar.
///
/// CloudKit rules: every property has a default, no relationships, no `.unique`. Older app
/// versions ignore the model. The filter lives in `filterJSON` (maintainer decision), so newer
/// filter fields need no schema change; see `DocumentFilter` for how versions read each other's
/// filters. Equal `sortIndex` values (two devices adding a view) are ordered by `createdAt` and
/// `id`; the next reorder renumbers them.
@Model
final class SavedView {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "line.3.horizontal.decrease.circle"
    var sortIndex: Int = 0
    var createdAt: Date = Date()
    /// The `DocumentFilter` as JSON. Read and write it through `filter`.
    var filterJSON: String = "{}"

    init(name: String, symbol: String = "line.3.horizontal.decrease.circle", filter: DocumentFilter = DocumentFilter(),
         sortIndex: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.sortIndex = sortIndex
        self.filterJSON = DocumentFilter.json(filter, preserving: "{}")
    }

    /// Decoded once per `filterJSON` string (`DocumentFilterCache`). Setting it keeps unknown keys
    /// and values of newer versions the user did not change, and writes only when the JSON changes,
    /// so setting an equal filter leaves the record (and the synced data) untouched.
    var filter: DocumentFilter {
        get { DocumentFilterCache.shared.filter(for: filterJSON) }
        set {
            let json = DocumentFilter.json(newValue, preserving: filterJSON)
            if json != filterJSON { filterJSON = json }
        }
    }

    /// The sort menu of a saved view writes here (maintainer decision: a sort change is saved into
    /// the view). Only a different value is written.
    func setSort(_ sort: DocumentSort, ascending: Bool) {
        var filter = filter
        guard filter.sort != sort || filter.ascending != ascending else { return }
        filter.sort = sort
        filter.ascending = ascending
        self.filter = filter
    }
}
