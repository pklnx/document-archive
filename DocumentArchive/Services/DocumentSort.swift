import Foundation

/// How a document list is sorted. The sidebar lists and saved views (#14) sort through
/// `sort(_:ascending:)`, so they always agree.
///
/// Stored as its raw value in the settings (`documentSort`) and inside saved views' `filterJSON`.
/// A saved view written by a newer version may name a case this version does not know; the view
/// then falls back to `.added` and keeps the stored value (see `DocumentFilter`).
enum DocumentSort: String, Codable, CaseIterable, Identifiable {
    case added, documentDate, title, correspondent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .added: String(localized: "Added")
        case .documentDate: String(localized: "Issue date")
        case .title: String(localized: "Title")
        case .correspondent: String(localized: "Correspondent")
        }
    }

    /// The direction the sidebar lists use: newest first for dates, A–Z for text.
    var defaultAscending: Bool {
        switch self {
        case .added, .documentDate: false
        case .title, .correspondent: true
        }
    }

    /// Sorts the documents. Equal keys are ordered by `id`, so the order is the same on every
    /// call; descending is exactly the reverse of ascending.
    func sort(_ documents: [Document], ascending: Bool) -> [Document] {
        documents.sorted { lhs, rhs in
            ascending ? isOrderedBefore(lhs, rhs) : isOrderedBefore(rhs, lhs)
        }
    }

    /// Ascending order.
    private func isOrderedBefore(_ lhs: Document, _ rhs: Document) -> Bool {
        let order: ComparisonResult
        switch self {
        case .added:
            order = Self.compare(lhs.createdAt, rhs.createdAt)
        case .documentDate:
            order = Self.compare(lhs.documentDate, rhs.documentDate)
        case .title:
            order = lhs.title.localizedStandardCompare(rhs.title)
        case .correspondent:
            // Documents without a correspondent sort as "~".
            order = (lhs.correspondent?.name ?? "~").localizedStandardCompare(rhs.correspondent?.name ?? "~")
        }
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func compare(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
