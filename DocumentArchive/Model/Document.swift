import Foundation
import SwiftData

/// Ein gespeichertes Dokument (angelehnt an paperless-ngx). Die PDF-Daten liegen als externe Datei
/// neben der Datenbank und werden von SwiftData automatisch als CloudKit-Asset über iCloud synchronisiert.
///
/// Hinweis zu CloudKit: Alle Eigenschaften brauchen einen Standardwert oder müssen optional sein,
/// Beziehungen müssen optional sein und `@Attribute(.unique)` ist nicht erlaubt.
@Model
final class Document {
    var id: UUID = UUID()
    var title: String = ""
    /// Hinzugefügt am
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    /// Ausstellungsdatum des Dokuments (z. B. Rechnungsdatum). Wird beim Import aus dem Text erkannt.
    var documentDate: Date = Date()
    var notes: String = ""
    var isFavorite: Bool = false
    /// Neue Dokumente landen im Posteingang, bis sie geprüft wurden.
    var isInbox: Bool = true
    /// Archiv-Seriennummer (ASN) – praktisch, wenn das Papieroriginal aufbewahrt wird.
    var archiveSerialNumber: Int?
    var pageCount: Int = 0
    var fileSize: Int = 0
    /// Volltext (aus dem PDF oder per Texterkennung), wird für Suche und automatische Zuordnung verwendet.
    var extractedText: String = ""
    /// `true`, solange Vorschaubild und Text noch erzeugt werden.
    var isProcessing: Bool = false
    var source: DocumentSource = DocumentSource.file
    var originalFileName: String = ""
    /// Womit der Text gewonnen wurde (z. B. „Mistral OCR“, „Apple Vision“, „PDF-Text“).
    var textSource: String = ""
    /// Hinweis aus der letzten Verarbeitung, z. B. wenn Mistral nicht erreichbar war.
    var processingNote: String = ""
    /// SHA-256 der Originaldatei – erkennt identische Dateien beim erneuten Import.
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

    /// `false` für gelöschte Dokumente. Auf Eigenschaften gelöschter Objekte darf nicht mehr
    /// zugegriffen werden (SwiftData bricht sonst ab), Views können aber kurz noch alte Referenzen halten.
    var isAlive: Bool { !isDeleted && modelContext != nil }

    /// `true`, solange der Titel noch automatisch vergeben ist (Dateiname oder „Scan …“) –
    /// dann darf die automatische Zuordnung einen besseren Titel setzen.
    var hasAutomaticTitle: Bool {
        let fileStem = (originalFileName as NSString).deletingPathExtension
        return title.isEmpty || (!fileStem.isEmpty && title == fileStem)
            || ["Scan ", "Foto ", "Dokument "].contains { title.hasPrefix($0) }
    }

    var sortedTags: [Tag] {
        (tags ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    /// Volltextsuche über Titel, Notizen, erkannten Text, Korrespondent, Typ, Tags und ASN.
    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = [
            title, notes, extractedText, originalFileName,
            correspondent?.name ?? "", documentType?.name ?? "",
            (tags ?? []).map(\.name).joined(separator: " "),
            archiveSerialNumber.map { "ASN\($0) \($0)" } ?? "",
        ].joined(separator: "\n")
        return terms.allSatisfy { haystack.localizedStandardContains($0) }
    }

    /// Dateiname für Export und Teilen, z. B. „2026-10-15 Stadtwerke – Rechnung.pdf“.
    var exportFileName: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let date = documentDate.formatted(.iso8601.year().month().day())
        var parts = [date]
        if let correspondent, !title.localizedCaseInsensitiveContains(correspondent.name) {
            parts.append(correspondent.name)
        }
        parts.append(title.isEmpty ? "Dokument" : title)
        let name = parts.joined(separator: " ").components(separatedBy: invalid).joined(separator: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines) + ".pdf"
    }
}

enum DocumentSource: String, Codable, CaseIterable {
    case file
    case scan
    case image

    var label: String {
        switch self {
        case .file: "PDF-Import"
        case .scan: "Kamera-Scan"
        case .image: "Bild-Import"
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
