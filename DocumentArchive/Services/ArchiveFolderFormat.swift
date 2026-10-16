import CryptoKit
import Foundation

/// The archive as plain files in a folder the user chose (issue #8): one PDF and one JSON sidecar
/// per document, one JSON file per tag, correspondent and document type, and tombstones for
/// deletions. The live database never moves there; the folder is a copy (and, from #8 part 2, the
/// way devices exchange changes before CloudKit).
///
/// ```
/// Document Archive/
///   archive.json                  formatVersion, created by
///   Documents/<uuid>.pdf, <uuid>.json
///   Tags/<uuid>.json, Correspondents/<uuid>.json, DocumentTypes/<uuid>.json
///   Tombstones/<uuid>.json
///   Deleted/<uuid>.pdf, <uuid>.json   deleted documents, purged after 30 days
/// ```
///
/// **Rules for changes** (see docs/development/index.md, "Data model and iCloud sync"):
/// - Every change to `DocumentArchive/Model` extends these records and raises
///   `currentVersion.minor`, with the round-trip test in `ArchiveFolderFormatTests`.
/// - Every field is optional when decoding: a field missing from a file keeps the local value.
/// - Writers keep keys they do not know (`overlay`), so an older app version never removes data
///   written by a newer one.
/// - A newer **major** version means the folder can no longer be understood: the app then stops
///   reading and writing it.
enum ArchiveFolderFormat {
    /// 1.0: documents, tags, correspondents, document types, tombstones (#8 part 1).
    /// 1.1: tags have `parent` and `symbol` (#13).
    static let currentVersion = FormatVersion(major: 1, minor: 1)

    /// The subfolder the app creates inside the folder the user chose.
    static let rootFolderName = "Document Archive"

    // MARK: Encoding

    /// Stable bytes for a record: sorted keys, so equal records give equal bytes and hashes.
    static func encode<Record: Encodable>(_ record: Record) throws -> Data {
        try overlay(record, onto: nil)
    }

    /// Encodes `record` on top of the JSON object in `existing`: known keys are replaced, every
    /// other key of `existing` is kept (written by a newer app version).
    static func overlay<Record: Encodable>(_ record: Record, onto existing: Data?) throws -> Data {
        let encoded = try encoder.encode(record)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        if let existing, let old = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] {
            for (key, value) in old where object[key] == nil {
                object[key] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    static func decode<Record: Decodable>(_ type: Record.Type, from data: Data) throws -> Record {
        try decoder.decode(type, from: data)
    }

    /// Hex SHA-256, used for PDFs and for change detection of records.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Dates are written in UTC with milliseconds. Records always hold dates rounded to
    /// milliseconds, so a date read back from a file compares equal to the one written.
    static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds(date)) / 1000)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func string(from date: Date) -> String {
        let (quotient, remainder) = milliseconds(date).quotientAndRemainder(dividingBy: 1000)
        let seconds = remainder < 0 ? quotient - 1 : quotient
        let fraction = remainder < 0 ? remainder + 1000 : remainder
        // "2026-10-16T08:30:00Z" (UTC) → "2026-10-16T08:30:00.250Z"
        let base = Date(timeIntervalSince1970: Double(seconds)).formatted(Date.ISO8601FormatStyle())
        return String(base.dropLast()) + String(format: ".%03dZ", Int(fraction))
    }

    static func date(from string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return normalized(date)
        }
        return try? Date(string, strategy: Date.ISO8601FormatStyle())
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
            }
            return date
        }
        return decoder
    }()
}

/// `major.minor`. An unknown minor is read normally; an unknown major stops the folder copy.
struct FormatVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    var major: Int
    var minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first, major >= 0 else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
    }

    var description: String { "\(major).\(minor)" }

    /// Whether this app version may read and write a folder or file with this version.
    var isSupported: Bool { major <= ArchiveFolderFormat.currentVersion.major }

    /// A missing or unreadable version counts as supported: files without one were written
    /// before versions existed or by hand. Only a known newer major stops the app.
    static func isSupported(_ string: String?) -> Bool {
        guard let string, let version = FormatVersion(string) else { return true }
        return version.isSupported
    }

    static func < (lhs: FormatVersion, rhs: FormatVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

/// What kind of object a file or tombstone belongs to; also the folder it lives in.
enum ArchiveObjectKind: String, Codable, CaseIterable, Sendable {
    case document
    case tag
    case correspondent
    case documentType

    var folderName: String {
        switch self {
        case .document: "Documents"
        case .tag: "Tags"
        case .correspondent: "Correspondents"
        case .documentType: "DocumentTypes"
        }
    }
}

// MARK: - Records

/// `archive.json`: which format the folder uses and which app created it.
struct ArchiveInfo: Codable, Equatable {
    var formatVersion: String?
    var createdBy: String?
    var createdAt: Date?
}

/// `Documents/<uuid>.json`. Relationships are stored by UUID, with the names for people reading
/// the files and for matching on another device. Recognized text is included (maintainer decision).
struct DocumentRecord: Codable, Equatable {
    var id: UUID?
    var title: String?
    var createdAt: Date?
    var modifiedAt: Date?
    var documentDate: Date?
    var notes: String?
    var isFavorite: Bool?
    var isInbox: Bool?
    var archiveSerialNumber: Int?
    var pageCount: Int?
    var fileSize: Int?
    var contentHash: String?
    /// SHA-256 of `<uuid>.pdf`; a reader only imports the pair when the PDF matches.
    var pdfSHA256: String?
    var extractedText: String?
    var textSource: String?
    var source: String?
    var originalFileName: String?
    var correspondentID: UUID?
    var correspondentName: String?
    var documentTypeID: UUID?
    var documentTypeName: String?
    var tagIDs: [UUID]?
    var tagNames: [String]?
    /// Device id of the writer; breaks ties between equal `modifiedAt`.
    var writtenBy: String?
    var formatVersion: String?

    /// Every key is written, `nil` as `null`: a cleared ASN, correspondent or type must reach the
    /// other devices, while a key that is missing (older writer) keeps their local value.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(documentDate, forKey: .documentDate)
        try container.encode(notes, forKey: .notes)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(isInbox, forKey: .isInbox)
        try container.encode(archiveSerialNumber, forKey: .archiveSerialNumber)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(pdfSHA256, forKey: .pdfSHA256)
        try container.encode(extractedText, forKey: .extractedText)
        try container.encode(textSource, forKey: .textSource)
        try container.encode(source, forKey: .source)
        try container.encode(originalFileName, forKey: .originalFileName)
        try container.encode(correspondentID, forKey: .correspondentID)
        try container.encode(correspondentName, forKey: .correspondentName)
        try container.encode(documentTypeID, forKey: .documentTypeID)
        try container.encode(documentTypeName, forKey: .documentTypeName)
        try container.encode(tagIDs, forKey: .tagIDs)
        try container.encode(tagNames, forKey: .tagNames)
        try container.encode(writtenBy, forKey: .writtenBy)
        try container.encode(formatVersion, forKey: .formatVersion)
    }

    /// The newer of two versions of the same document: later `modifiedAt`, then the larger
    /// `writtenBy`, so every device decides the same way. (Clock skew between devices is an
    /// accepted limit; devices use network time.)
    func isNewer(than other: DocumentRecord) -> Bool {
        let mine = modifiedAt ?? .distantPast
        let theirs = other.modifiedAt ?? .distantPast
        if mine != theirs { return mine > theirs }
        return (writtenBy ?? "") > (other.writtenBy ?? "")
    }
}

/// `Tags/<uuid>.json`, `Correspondents/<uuid>.json` and `DocumentTypes/<uuid>.json`. The models
/// have no `modifiedAt`; `changedAt` is this device's local change time (`ArchiveMirrorState`).
struct EntityRecord: Codable, Equatable {
    var id: UUID?
    var name: String?
    var matchText: String?
    var matchMode: String?
    var createdAt: Date?
    var changedAt: Date?
    /// Tags only.
    var colorHex: String?
    /// Document types and tags (tags from 1.1).
    var symbol: String?
    /// Tags (from 1.1): the parent tag's UUID, `null` for a root. Always written, also as `null`,
    /// so moving a tag to the top level reaches the other devices (`overlay` would otherwise keep
    /// the old parent). Correspondents and types write `null` (nesting for them comes later).
    var parent: UUID?
    var writtenBy: String?
    var formatVersion: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(matchText, forKey: .matchText)
        try container.encodeIfPresent(matchMode, forKey: .matchMode)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(changedAt, forKey: .changedAt)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encode(parent, forKey: .parent)
        try container.encodeIfPresent(writtenBy, forKey: .writtenBy)
        try container.encodeIfPresent(formatVersion, forKey: .formatVersion)
    }

    /// How a reader matches a tag from the folder that has no local tag with its UUID (#8 part 2):
    /// the same parent and the same normalized name, like `MetadataMaintenance` merges duplicates.
    static func tagMatchKey(parent: UUID?, name: String) -> String {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(parent?.uuidString ?? "root")/\(normalized)"
    }

    func isNewer(than other: EntityRecord) -> Bool {
        let mine = changedAt ?? .distantPast
        let theirs = other.changedAt ?? .distantPast
        if mine != theirs { return mine > theirs }
        return (writtenBy ?? "") > (other.writtenBy ?? "")
    }
}

/// `Tombstones/<uuid>.json`: an explicit deletion (never inferred from missing files). Kept for a
/// year; a device offline for longer can bring the object back, which is accepted.
struct Tombstone: Codable, Equatable {
    var id: UUID?
    var kind: ArchiveObjectKind?
    var deletedAt: Date?
    var deletedBy: String?
    /// For merged tags, correspondents and types: the object that took over the documents.
    var mergedInto: UUID?
    var formatVersion: String?
}

// MARK: - Building records from the model

extension DocumentRecord {
    /// - Parameter pdfSHA256: hash of `pdfData`, computed by the caller only when needed.
    @MainActor
    init(_ document: Document, pdfSHA256: String, writtenBy: String) {
        let tags = document.sortedTags
        self.init(
            id: document.id,
            title: document.title,
            createdAt: ArchiveFolderFormat.normalized(document.createdAt),
            modifiedAt: ArchiveFolderFormat.normalized(document.modifiedAt),
            documentDate: ArchiveFolderFormat.normalized(document.documentDate),
            notes: document.notes,
            isFavorite: document.isFavorite,
            isInbox: document.isInbox,
            archiveSerialNumber: document.archiveSerialNumber,
            pageCount: document.pageCount,
            fileSize: document.fileSize,
            contentHash: document.contentHash,
            pdfSHA256: pdfSHA256,
            extractedText: document.extractedText,
            textSource: document.textSource,
            source: document.source.rawValue,
            originalFileName: document.originalFileName,
            correspondentID: document.correspondent?.id,
            correspondentName: document.correspondent?.name,
            documentTypeID: document.documentType?.id,
            documentTypeName: document.documentType?.name,
            tagIDs: tags.map(\.id),
            tagNames: tags.map(\.name),
            writtenBy: writtenBy,
            formatVersion: ArchiveFolderFormat.currentVersion.description
        )
    }
}

extension EntityRecord {
    /// `changedAt` stays `nil`; the mirror sets it when the content changed.
    @MainActor
    init(_ tag: Tag, writtenBy: String) {
        self.init(id: tag.id, name: tag.name, matchText: tag.matchText, matchMode: tag.matchMode.rawValue,
                  createdAt: ArchiveFolderFormat.normalized(tag.createdAt), colorHex: tag.colorHex,
                  symbol: tag.symbol, parent: tag.parent?.id, writtenBy: writtenBy, formatVersion: ArchiveFolderFormat.currentVersion.description)
    }

    @MainActor
    init(_ correspondent: Correspondent, writtenBy: String) {
        self.init(id: correspondent.id, name: correspondent.name, matchText: correspondent.matchText,
                  matchMode: correspondent.matchMode.rawValue,
                  createdAt: ArchiveFolderFormat.normalized(correspondent.createdAt),
                  writtenBy: writtenBy, formatVersion: ArchiveFolderFormat.currentVersion.description)
    }

    @MainActor
    init(_ type: DocumentType, writtenBy: String) {
        self.init(id: type.id, name: type.name, matchText: type.matchText, matchMode: type.matchMode.rawValue,
                  createdAt: ArchiveFolderFormat.normalized(type.createdAt), symbol: type.symbol,
                  writtenBy: writtenBy, formatVersion: ArchiveFolderFormat.currentVersion.description)
    }
}

// MARK: - Layout

/// Where each file lives inside `Document Archive/`.
struct ArchiveFolderLayout: Sendable {
    /// `<chosen folder>/Document Archive`
    let root: URL

    init(chosenFolder: URL) {
        root = chosenFolder.appending(path: ArchiveFolderFormat.rootFolderName, directoryHint: .isDirectory)
    }

    var archiveInfo: URL { root.appending(path: "archive.json") }
    var tombstones: URL { root.appending(path: "Tombstones", directoryHint: .isDirectory) }
    var deleted: URL { root.appending(path: "Deleted", directoryHint: .isDirectory) }

    func folder(_ kind: ArchiveObjectKind) -> URL {
        root.appending(path: kind.folderName, directoryHint: .isDirectory)
    }

    /// All folders the writer needs.
    var allFolders: [URL] { ArchiveObjectKind.allCases.map(folder) + [tombstones, deleted] }

    func pdf(_ id: UUID) -> URL { folder(.document).appending(path: "\(id.uuidString).pdf") }
    /// The JSON file of a document (sidecar) or of a tag, correspondent or type.
    func record(_ kind: ArchiveObjectKind, _ id: UUID) -> URL { folder(kind).appending(path: "\(id.uuidString).json") }
    func tombstone(_ id: UUID) -> URL { tombstones.appending(path: "\(id.uuidString).json") }
    func deletedPDF(_ id: UUID) -> URL { deleted.appending(path: "\(id.uuidString).pdf") }
    func deletedRecord(_ id: UUID) -> URL { deleted.appending(path: "\(id.uuidString).json") }

    /// UUIDs of the JSON files in a folder, including evicted ones (`.<uuid>.json.icloud`
    /// placeholders): an evicted file is still there.
    static func recordIDs(in folder: URL) -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var ids = Set<UUID>()
        for name in names {
            var stem = name
            if stem.hasPrefix("."), stem.hasSuffix(".icloud") {
                stem = String(stem.dropFirst().dropLast(".icloud".count))
            }
            guard stem.hasSuffix(".json"), let id = UUID(uuidString: String(stem.dropLast(".json".count))) else { continue }
            ids.insert(id)
        }
        return ids
    }
}
