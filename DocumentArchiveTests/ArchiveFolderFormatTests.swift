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
                               changedAt: date, colorHex: "#EF4444", writtenBy: "device-A", formatVersion: "1.0")
        #expect(try ArchiveFolderFormat.decode(EntityRecord.self, from: ArchiveFolderFormat.encode(tag)) == tag)

        let tombstone = Tombstone(id: UUID(), kind: .tag, deletedAt: date, deletedBy: "device-A",
                                  mergedInto: UUID(), formatVersion: "1.0")
        #expect(try ArchiveFolderFormat.decode(Tombstone.self, from: ArchiveFolderFormat.encode(tombstone)) == tombstone)
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
        #expect(FormatVersion("1.0") == ArchiveFolderFormat.currentVersion)
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
