import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// The folder format (`ArchiveFolderFormat`): records, versions, unknown and missing fields.
/// Every schema change after #8 part 1 extends `fullDocumentRecord` and the round trip below.
@Suite struct ArchiveFolderFormatTests {
    private let date = ArchiveFolderFormat.normalized(Date(timeIntervalSince1970: 1_790_000_000.25))

    private var fullDocumentRecord: DocumentRecord {
        DocumentRecord(
            id: UUID(), title: "Electricity bill", createdAt: date, modifiedAt: date.addingTimeInterval(60),
            documentDate: date.addingTimeInterval(-86_400), notes: "Paid", isFavorite: true, isInbox: false,
            archiveSerialNumber: 42, pageCount: 2, fileSize: 1234, contentHash: "abc", pdfSHA256: "def",
            extractedText: "Stadtwerke\nRechnung", textSource: "Apple Vision", source: "scan",
            originalFileName: "scan.pdf", correspondentID: UUID(), correspondentName: "Stadtwerke",
            documentTypeID: UUID(), documentTypeName: "Invoice", tagIDs: [UUID(), UUID()], tagNames: ["Home", "Tax"],
            writtenBy: "device-A", formatVersion: "1.0")
    }

    @Test func recordsSurviveARoundTripWithStableBytes() throws {
        let document = fullDocumentRecord
        let bytes = try ArchiveFolderFormat.encode(document)
        let decoded = try ArchiveFolderFormat.decode(DocumentRecord.self, from: bytes)
        #expect(decoded == document)
        #expect(try ArchiveFolderFormat.encode(decoded) == bytes)
        #expect(try ArchiveFolderFormat.encode(document) == bytes, "same record, same bytes")

        let tag = EntityRecord(id: UUID(), name: "Tax", matchText: "Steuer", matchMode: "any", createdAt: date,
                               changedAt: date, colorHex: "#EF4444", symbol: "car.fill", parent: UUID(),
                               writtenBy: "device-A", formatVersion: "1.1")
        #expect(try ArchiveFolderFormat.decode(EntityRecord.self, from: ArchiveFolderFormat.encode(tag)) == tag)
        var root = tag
        root.parent = nil
        #expect(try ArchiveFolderFormat.decode(EntityRecord.self, from: ArchiveFolderFormat.encode(root)) == root)

        let tombstone = Tombstone(id: UUID(), kind: .tag, deletedAt: date, deletedBy: "device-A",
                                  mergedInto: UUID(), formatVersion: "1.0")
        #expect(try ArchiveFolderFormat.decode(Tombstone.self, from: ArchiveFolderFormat.encode(tombstone)) == tombstone)

        let view = SavedViewRecord(id: UUID(), name: "Taxes 2026", symbol: "eurosign.circle", sortIndex: 3,
                                   createdAt: date, filterJSON: #"{"future":true,"query":"Steuer"}"#,
                                   changedAt: date, writtenBy: "device-A", formatVersion: "1.2")
        let viewBytes = try ArchiveFolderFormat.encode(view)
        #expect(try ArchiveFolderFormat.decode(SavedViewRecord.self, from: viewBytes) == view)
        #expect(try ArchiveFolderFormat.encode(ArchiveFolderFormat.decode(SavedViewRecord.self, from: viewBytes)) == viewBytes)
        let viewTombstone = Tombstone(id: UUID(), kind: .savedView, deletedAt: date, deletedBy: "device-A",
                                      formatVersion: "1.2")
        #expect(try ArchiveFolderFormat.decode(Tombstone.self, from: ArchiveFolderFormat.encode(viewTombstone)) == viewTombstone)
    }

    /// 1.2 (#14): a saved view's record carries the raw `filterJSON`, unknown keys included.
    @Test @MainActor func savedViewRecordKeepsTheRawFilter() throws {
        let container = try TestSupport.makeContainer()
        let view = SavedView(name: "Open insurance", symbol: "shield", sortIndex: 2)
        view.filterJSON = #"{"deadline":{"within":30},"inbox":true}"#
        container.mainContext.insert(view)

        let record = SavedViewRecord(view, writtenBy: "device-A")
        #expect(record.id == view.id)
        #expect(record.name == "Open insurance")
        #expect(record.symbol == "shield")
        #expect(record.sortIndex == 2)
        #expect(record.filterJSON == view.filterJSON)
        #expect(record.createdAt == ArchiveFolderFormat.normalized(view.createdAt))
        #expect(record.formatVersion == "1.2")
        #expect(ArchiveObjectKind.savedView.folderName == "SavedViews")
    }

    /// A tombstone of a kind a newer version added still decodes (its date is needed for the
    /// purge); only the kind is unknown.
    @Test func tombstoneOfAnUnknownKindStillDecodes() throws {
        let id = UUID()
        let data = Data(#"{"id":"\#(id.uuidString)","kind":"reminder","deletedAt":"2026-09-21T14:13:20.250Z"}"#.utf8)
        let tombstone = try ArchiveFolderFormat.decode(Tombstone.self, from: data)
        #expect(tombstone.id == id)
        #expect(tombstone.kind == nil)
        #expect(tombstone.deletedAt == date)
    }

    @Test @MainActor func recordFromADocumentHasEveryField() throws {
        let container = try TestSupport.makeContainer()
        let tag = ArchiveTag(name: "Tax")
        let correspondent = Correspondent(name: "Stadtwerke")
        let type = DocumentType(name: "Invoice")
        let document = Document(title: "Bill", pdfData: Data("pdf".utf8), source: .scan, originalFileName: "a.pdf")
        [tag].forEach(container.mainContext.insert)
        container.mainContext.insert(correspondent)
        container.mainContext.insert(type)
        container.mainContext.insert(document)
        document.tags = [tag]
        document.correspondent = correspondent
        document.documentType = type
        document.archiveSerialNumber = 7
        document.extractedText = "Recognized text"

        let record = DocumentRecord(document, pdfSHA256: "hash", writtenBy: "device-A")
        #expect(record.id == document.id)
        #expect(record.extractedText == "Recognized text", "recognized text goes into the folder (decision)")
        #expect(record.tagIDs == [tag.id])
        #expect(record.tagNames == ["Tax"])
        #expect(record.correspondentID == correspondent.id)
        #expect(record.documentTypeName == "Invoice")
        #expect(record.archiveSerialNumber == 7)
        #expect(record.source == "scan")
        #expect(record.formatVersion == ArchiveFolderFormat.currentVersion.description)
        #expect(record.modifiedAt == ArchiveFolderFormat.normalized(document.modifiedAt))
    }

    /// 1.1 (#13): a tag record carries its parent and symbol.
    @Test @MainActor func tagRecordHasParentAndSymbol() throws {
        let container = try TestSupport.makeContainer()
        let auto = ArchiveTag(name: "Auto")
        let golf = ArchiveTag(name: "Golf")
        container.mainContext.insert(auto)
        container.mainContext.insert(golf)
        golf.parent = auto
        golf.symbol = "car.fill"

        let record = EntityRecord(golf, writtenBy: "device-A")
        #expect(record.parent == auto.id)
        #expect(record.symbol == "car.fill")
        #expect(record.formatVersion == ArchiveFolderFormat.currentVersion.description)
        #expect(EntityRecord(auto, writtenBy: "device-A").parent == nil)
    }

    /// Moving a tag to the top level must reach the folder: `parent` is written as `null`, so
    /// `overlay` does not keep the old parent from the existing file.
    @Test func unnestedTagOverwritesTheOldParent() throws {
        var record = EntityRecord(id: UUID(), name: "Golf", parent: UUID(), formatVersion: "1.1")
        let existing = try ArchiveFolderFormat.encode(record)
        record.parent = nil
        let rewritten = try ArchiveFolderFormat.overlay(record, onto: existing)
        let object = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        #expect(object["parent"] is NSNull)
        #expect(try ArchiveFolderFormat.decode(EntityRecord.self, from: rewritten).parent == nil)
    }

    /// Tags without a matching UUID are matched by parent and normalized name (#8 part 2 reader).
    @Test func tagMatchKeyUsesParentAndNormalizedName() {
        let parent = UUID()
        #expect(EntityRecord.tagMatchKey(parent: parent, name: " Werkstätt ")
                == EntityRecord.tagMatchKey(parent: parent, name: "werkstatt"))
        #expect(EntityRecord.tagMatchKey(parent: parent, name: "Werkstatt")
                != EntityRecord.tagMatchKey(parent: nil, name: "Werkstatt"))
        #expect(EntityRecord.tagMatchKey(parent: parent, name: "Werkstatt")
                != EntityRecord.tagMatchKey(parent: UUID(), name: "Werkstatt"))
    }

    @Test func datesAreUTCWithMilliseconds() throws {
        let value = Date(timeIntervalSince1970: 1_790_000_000.25)
        #expect(ArchiveFolderFormat.string(from: value) == "2026-09-21T14:13:20.250Z")
        #expect(ArchiveFolderFormat.date(from: "2026-09-21T14:13:20.250Z") == value)
        #expect(ArchiveFolderFormat.date(from: "2026-09-21T14:13:20Z") == Date(timeIntervalSince1970: 1_790_000_000))
        let odd = Date(timeIntervalSince1970: 1_790_000_000.123456)
        let decoded = try ArchiveFolderFormat.decode(ArchiveInfo.self,
                                                     from: ArchiveFolderFormat.encode(ArchiveInfo(createdAt: odd)))
        #expect(decoded.createdAt == ArchiveFolderFormat.normalized(odd))
    }

    /// A cleared ASN, correspondent or type is written as `null`, so it reaches other devices;
    /// a key that is missing (older writer) is something else.
    @Test func clearedFieldsAreWrittenAsNull() throws {
        var record = fullDocumentRecord
        record.archiveSerialNumber = nil
        record.correspondentID = nil
        let object = try #require(try JSONSerialization.jsonObject(with: ArchiveFolderFormat.encode(record)) as? [String: Any])
        #expect(object["archiveSerialNumber"] is NSNull)
        #expect(object["correspondentID"] is NSNull)
    }

    /// Part of "missing fields keep local values": a sidecar without `tagIDs` (older writer)
    /// decodes as "no information", not as "no tags". Applying records comes with #8 part 2.
    @Test func missingFieldsDecodeAsUnknown() throws {
        let id = UUID()
        let old = Data(#"{"id":"\#(id.uuidString)","title":"Old writer"}"#.utf8)
        let record = try ArchiveFolderFormat.decode(DocumentRecord.self, from: old)
        #expect(record.id == id)
        #expect(record.title == "Old writer")
        #expect(record.tagIDs == nil)
        #expect(record.modifiedAt == nil)

        let empty = Data(#"{"tagIDs":[]}"#.utf8)
        #expect(try ArchiveFolderFormat.decode(DocumentRecord.self, from: empty).tagIDs == [])
    }

    @Test func unknownFieldsAreKeptWhenRewriting() throws {
        let existing = Data(#"{"futureField":{"nested":[1,2]},"title":"Old","writtenBy":"device-B"}"#.utf8)
        var record = fullDocumentRecord
        record.title = "New"
        let merged = try ArchiveFolderFormat.overlay(record, onto: existing)
        let object = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect(object["title"] as? String == "New")
        #expect(object["writtenBy"] as? String == "device-A")
        #expect((object["futureField"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        #expect(try ArchiveFolderFormat.decode(DocumentRecord.self, from: merged).title == "New")
    }

    @Test func unknownMinorIsReadUnknownMajorIsRefused() throws {
        #expect(FormatVersion("1.2") == ArchiveFolderFormat.currentVersion)
        #expect(FormatVersion.isSupported("1.7"))
        #expect(FormatVersion.isSupported(nil))
        #expect(!FormatVersion.isSupported("2.0"))
        #expect(FormatVersion("2.1")! > FormatVersion("1.9")!)

        let newerMinor = Data(#"{"title":"From 1.7","formatVersion":"1.7","deadlines":[{"id":"x"}]}"#.utf8)
        #expect(try ArchiveFolderFormat.decode(DocumentRecord.self, from: newerMinor).title == "From 1.7")
    }

    /// Evicted files (`.<uuid>.json.icloud`) still count as present.
    @Test func recordIDsIncludePlaceholders() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        let (a, b) = (UUID(), UUID())
        try Data().write(to: folder.appending(path: "\(a.uuidString).json"))
        try Data().write(to: folder.appending(path: ".\(b.uuidString).json.icloud"))
        try Data().write(to: folder.appending(path: "\(UUID().uuidString).pdf"))
        try Data().write(to: folder.appending(path: "notes.json"))
        #expect(ArchiveFolderLayout.recordIDs(in: folder) == [a, b])
    }
}
