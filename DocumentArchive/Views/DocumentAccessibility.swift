import Foundation

/// What VoiceOver reads for a document row: one sentence instead of every part of the row.
@MainActor
enum DocumentAccessibility {
    /// Title, issue date, correspondent, type, tags and state, e.g.
    /// "Electricity bill, 9 May 2026, Stadtwerke, Invoice, tags: Tax and Home, favorite, in inbox".
    /// Empty parts are left out.
    static func label(for document: Document, locale: Locale = .current) -> String {
        var parts: [String] = []
        parts.append(document.title.isEmpty ? String(localized: "Untitled document") : document.title)
        parts.append(document.documentDate.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(locale)))
        if let correspondent = document.correspondent, !correspondent.name.isEmpty {
            parts.append(correspondent.name)
        }
        if let type = document.documentType, !type.name.isEmpty {
            parts.append(type.name)
        }
        if let tags = tagList(document.sortedTags.map(TagHierarchy.displayPath), locale: locale) {
            parts.append(String(localized: "tags: \(tags)"))
        }
        if document.isFavorite { parts.append(String(localized: "favorite")) }
        if document.isInbox { parts.append(String(localized: "in inbox")) }
        if document.isProcessing { parts.append(String(localized: "text recognition running")) }
        return parts.joined(separator: ", ")
    }

    /// "Tax and Home", localized; `nil` without tags.
    static func tagList(_ names: [String], locale: Locale = .current) -> String? {
        let names = names.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return names.formatted(.list(type: .and).locale(locale))
    }

    /// "1 document" / "3 documents", for sidebar rows.
    static func documentCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 document") : String(localized: "\(count) documents")
    }
}
