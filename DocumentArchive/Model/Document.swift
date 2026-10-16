import Foundation
import SwiftData

/// A stored document (modeled after paperless-ngx). The PDF data lives in an external file next to
/// the database, and SwiftData syncs it through iCloud as a CloudKit asset.
///
/// CloudKit rules: every property needs a default value or must be optional, relationships must be
/// optional, and `@Attribute(.unique)` is not allowed.
@Model
final class Document {
    var id: UUID = UUID()
    var title: String = ""
    /// When the document was added
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    /// Issue date of the document (e.g. the invoice date), detected from the text on import.
    var documentDate: Date = Date()
    var notes: String = ""
    var isFavorite: Bool = false
    /// New documents stay in the inbox until they have been checked.
    var isInbox: Bool = true
    /// Archive serial number (ASN), useful when the paper original is kept.
    var archiveSerialNumber: Int?
    var pageCount: Int = 0
    var fileSize: Int = 0
    /// Full text (from the PDF or from OCR), used for search and auto-assignment.
    var extractedText: String = ""
    /// `true` while the thumbnail and the text are still being created.
    var isProcessing: Bool = false
    var source: DocumentSource = DocumentSource.file
    var originalFileName: String = ""
    /// Where the text came from ("Mistral OCR", "Apple Vision" or "PDF-Text"); shown in the inspector.
    var textSource: String = ""
    /// Note from the last processing run, e.g. when Mistral could not be reached.
    var processingNote: String = ""
    /// SHA-256 of the original file; detects identical files on a later import.
    var contentHash: String = ""

    @Attribute(.externalStorage) var pdfData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?

    var correspondent: Correspondent?
    var documentType: DocumentType?
    @Relationship(inverse: \Tag.documents) var tags: [Tag]? = []

    init(title: String, pdfData: Data, source: DocumentSource, originalFileName: String = "") {
        self.title = title
        self.pdfData = pdfData
        self.fileSize = pdfData.count
        self.source = source
        self.originalFileName = originalFileName
        self.isProcessing = true
    }

    func touch() {
        modifiedAt = Date()
    }

    /// `false` for deleted documents. Properties of deleted objects must not be read (SwiftData
    /// traps), but views can hold on to old references for a moment.
    var isAlive: Bool { !isDeleted && modelContext != nil }

    /// `true` while the title is still the automatic one (file name or "Scan …"); only then may
    /// auto-assignment replace it with a better title.
    var hasAutomaticTitle: Bool {
        let fileStem = (originalFileName as NSString).deletingPathExtension
        return title.isEmpty || (!fileStem.isEmpty && title == fileStem)
            || Self.automaticTitlePrefixes.contains { title.hasPrefix($0) }
    }

    /// Prefixes of the default titles in English and German, so documents are recognized whatever
    /// language the app ran in when they were imported.
    static let automaticTitlePrefixes = ["Scan ", "Photo ", "Foto ", "Document ", "Dokument "]

    /// Sorted by display path ("Auto › Golf" before "Auto › Golf › Werkstatt" before "Bank").
    var sortedTags: [Tag] {
        TagHierarchy.sortedByPath(tags ?? [])
    }

    func hasTag(_ tag: Tag) -> Bool {
        tags?.contains { $0.id == tag.id } ?? false
    }

    func toggleTag(_ tag: Tag) {
        if hasTag(tag) {
            tags?.removeAll { $0.id == tag.id }
        } else {
            if tags == nil { tags = [] }
            tags?.append(tag)
        }
        touch()
    }

    /// Full-text search over title, notes, recognized text, correspondent, type, tags (with their
    /// parent tags) and ASN.
    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = [
            title, notes, extractedText, originalFileName,
            correspondent?.name ?? "", documentType?.name ?? "",
            // A document tagged "Werkstatt" is also found by "Auto" (its parent tags).
            (tags ?? []).flatMap(TagHierarchy.path(of:)).map(\.name).joined(separator: " "),
            archiveSerialNumber.map { "ASN\($0) \($0)" } ?? "",
        ].joined(separator: "\n")
        return terms.allSatisfy { haystack.localizedStandardContains($0) }
    }

    /// File name for export and sharing, e.g. "2026-10-15 Stadtwerke Rechnung.pdf"
    /// (rules in `FileNaming.sanitized`).
    var exportFileName: String {
        let date = documentDate.formatted(.iso8601.year().month().day())
        var parts = [date]
        if let correspondent, !title.localizedCaseInsensitiveContains(correspondent.name) {
            parts.append(correspondent.name)
        }
        parts.append(title.isEmpty ? String(localized: "Document") : title)
        return FileNaming.sanitized(parts.joined(separator: " "))
    }
}

/// **Frozen:** never add a case. It is stored in synced documents, and an older app version
/// cannot decode a value it does not know.
enum DocumentSource: String, Codable, CaseIterable {
    case file
    case scan
    case image

    var label: String {
        switch self {
        case .file: String(localized: "PDF import")
        case .scan: String(localized: "Camera scan")
        case .image: String(localized: "Image import")
        }
    }

    var systemImage: String {
        switch self {
        case .file: "doc.richtext"
        case .scan: "doc.viewfinder"
        case .image: "photo"
        }
    }
}
