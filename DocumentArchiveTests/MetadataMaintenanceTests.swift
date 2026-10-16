import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

@Suite @MainActor struct MetadataMaintenanceTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try TestSupport.makeContainer()
    }

    private func insertDocument(_ title: String, hash: String = "", createdAt: Date = Date()) -> Document {
        let doc = Document(title: title, pdfData: Data(title.utf8), source: .file)
        doc.contentHash = hash
        doc.createdAt = createdAt
        context.insert(doc)
        return doc
    }

    @Test func mergesDuplicateCorrespondentsIntoTheOldest() throws {
        let older = Correspondent(name: "Telekom Deutschland GmbH")
        older.createdAt = .distantPast
        let newer = Correspondent(name: "telekom deutschland")   // same core name
        context.insert(older)
        context.insert(newer)
        let a = insertDocument("A")
        let b = insertDocument("B")
        a.correspondent = older
        b.correspondent = newer
        try context.save()

        #expect(MetadataMaintenance.mergeDuplicates(in: context) == 1)
        let remaining = try context.fetch(FetchDescriptor<Correspondent>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == older.id)
        #expect(a.correspondent?.id == older.id)
        #expect(b.correspondent?.id == older.id)
    }

    @Test func mergesDuplicateTagsAndTypes() throws {
        let tag1 = ArchiveTag(name: "Steuer")
        tag1.createdAt = .distantPast
        let tag2 = ArchiveTag(name: "steuer")
        let type1 = DocumentType(name: "Rechnung")
        type1.createdAt = .distantPast
        let type2 = DocumentType(name: "Rechnung")
        [tag1, tag2].forEach(context.insert)
        [type1, type2].forEach(context.insert)
        let doc = insertDocument("A")
        doc.toggleTag(tag2)
        doc.documentType = type2
        try context.save()

        #expect(MetadataMaintenance.mergeDuplicates(in: context) == 2)
        #expect(try context.fetch(FetchDescriptor<ArchiveTag>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<DocumentType>()).count == 1)
        #expect(doc.sortedTags.map(\.id) == [tag1.id])
        #expect(doc.documentType?.id == type1.id)
    }

    @Test func groupsDocumentsWithIdenticalContent() {
        let original = insertDocument("Original", hash: "abc", createdAt: .distantPast)
        let copy = insertDocument("Copy", hash: "abc")
        _ = insertDocument("Other", hash: "def")
        _ = insertDocument("Without hash")

        let all = (try? context.fetch(FetchDescriptor<Document>())) ?? []
        let groups = MetadataMaintenance.duplicateDocumentGroups(all)
        #expect(groups.count == 1)
        #expect(groups.first?.map(\.id) == [original.id, copy.id])
    }

    @Test func removingDuplicatesKeepsTheOldestAndTakesOverDetails() throws {
        let original = insertDocument("Original", hash: "abc", createdAt: .distantPast)
        let copy = insertDocument("Copy", hash: "abc")
        let tag = ArchiveTag(name: "Wichtig")
        let correspondent = Correspondent(name: "Telekom")
        context.insert(tag)
        context.insert(correspondent)
        copy.toggleTag(tag)
        copy.isFavorite = true
        copy.archiveSerialNumber = 7
        copy.notes = "Original im Ordner"
        copy.correspondent = correspondent
        try context.save()

        #expect(MetadataMaintenance.removeDuplicateDocuments(in: context) == 1)
        let remaining = try context.fetch(FetchDescriptor<Document>())
        #expect(remaining.map(\.id) == [original.id])
        #expect(original.hasTag(tag))
        #expect(original.isFavorite)
        #expect(original.archiveSerialNumber == 7)
        #expect(original.notes == "Original im Ordner")
        #expect(original.correspondent?.id == correspondent.id)
    }

    /// Regression: views kept references to deleted documents and crashed when reading them.
    @Test func deletedDocumentIsNoLongerAlive() throws {
        let original = insertDocument("Original", hash: "abc", createdAt: .distantPast)
        let copy = insertDocument("Copy", hash: "abc")
        try context.save()
        #expect(copy.isAlive)

        MetadataMaintenance.removeDuplicateDocuments(in: context)

        #expect(!copy.isAlive)
        #expect(original.isAlive)
        // A stale reference must not show up as a duplicate group again
        #expect(MetadataMaintenance.duplicateDocumentGroups([original, copy]).isEmpty)
    }

    // MARK: Nested tags (#13)

    /// Two devices both created Auto › Golf › Werkstatt before syncing: one call merges all levels.
    @Test func identicalTreesMergeInOneCall() throws {
        func tree(_ createdAt: Date) -> [ArchiveTag] {
            let auto = ArchiveTag(name: "Auto")
            let golf = ArchiveTag(name: "Golf")
            let werkstatt = ArchiveTag(name: "Werkstatt")
            for tag in [auto, golf, werkstatt] {
                tag.createdAt = createdAt
                context.insert(tag)
            }
            golf.parent = auto
            werkstatt.parent = golf
            return [auto, golf, werkstatt]
        }
        let first = tree(Date(timeIntervalSince1970: 1000))
        let second = tree(Date(timeIntervalSince1970: 2000))
        let documents = (first + second).map { tag in
            let document = insertDocument(tag.name)
            document.tags = [tag]
            return document
        }
        try context.save()

        #expect(MetadataMaintenance.mergeDuplicates(in: context) == 3)

        let tags = try context.fetch(FetchDescriptor<ArchiveTag>())
        #expect(Set(tags.map(\.id)) == Set(first.map(\.id)), "the older tree is kept")
        #expect(first[1].parent?.id == first[0].id)
        #expect(first[2].parent?.id == first[1].id)
        #expect(try context.fetchCount(FetchDescriptor<Document>()) == 6, "all documents kept")
        for (index, document) in documents.enumerated() {
            #expect(document.tags?.map(\.id) == [first[index % 3].id])
        }
    }

    @Test func sameNameUnderDifferentParentsIsNotMerged() throws {
        let golf = ArchiveTag(name: "Golf")
        let polo = ArchiveTag(name: "Polo")
        let golfWorkshop = ArchiveTag(name: "Werkstatt")
        let poloWorkshop = ArchiveTag(name: "werkstatt")
        [golf, polo, golfWorkshop, poloWorkshop].forEach(context.insert)
        golfWorkshop.parent = golf
        poloWorkshop.parent = polo
        try context.save()

        #expect(MetadataMaintenance.mergeDuplicates(in: context) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ArchiveTag>()) == 4)
    }

    /// Device 1 put A under B, device 2 put B under A′ (a duplicate of A). Merging A′ into A must
    /// not close the cycle A → B → A.
    @Test func mergeThenRepairHasNoCycle() throws {
        let a = ArchiveTag(name: "A")
        a.createdAt = Date(timeIntervalSince1970: 1000)
        let aPrime = ArchiveTag(name: "A")
        aPrime.createdAt = Date(timeIntervalSince1970: 2000)
        let b = ArchiveTag(name: "B")
        [a, aPrime, b].forEach(context.insert)
        a.parent = b
        b.parent = aPrime
        try context.save()

        MetadataMaintenance.merge([aPrime], into: a, in: context, recorder: nil)
        #expect(TagHierarchy.repairCycles(in: context) == 0, "the merge itself created no cycle")
        try context.save()

        let tags = try context.fetch(FetchDescriptor<ArchiveTag>())
        #expect(tags.count == 2)
        #expect(tags.allSatisfy { TagHierarchy.isRooted($0) })
        #expect(b.parent == nil, "B was an ancestor of the keeper, so it became a root")
        #expect(a.parent?.id == b.id)
    }

    /// A cycle that arrived by sync is repaired by the launch merge in the same call.
    @Test func mergeDuplicatesRepairsCycles() throws {
        let a = ArchiveTag(name: "A")
        a.createdAt = Date(timeIntervalSince1970: 1000)
        let b = ArchiveTag(name: "B")
        [a, b].forEach(context.insert)
        b.parent = a
        a.parent = b
        try context.save()

        MetadataMaintenance.mergeDuplicates(in: context)
        #expect(a.parent == nil)
        #expect(b.parent?.id == a.id)
        #expect(!context.hasChanges)
    }

    /// Merges record a tombstone with `mergedInto` for every kind.
    @Test func mergesRecordTombstonesForEveryKind() throws {
        let recorder = RecordedDeletions()
        let keeperTag = ArchiveTag(name: "Tax")
        keeperTag.createdAt = .distantPast
        let duplicateTag = ArchiveTag(name: "tax")
        let keeperType = DocumentType(name: "Invoice")
        keeperType.createdAt = .distantPast
        let duplicateType = DocumentType(name: "Invoice")
        let keeperCorrespondent = Correspondent(name: "Telekom")
        keeperCorrespondent.createdAt = .distantPast
        let duplicateCorrespondent = Correspondent(name: "Telekom")
        [keeperTag, duplicateTag].forEach(context.insert)
        [keeperType, duplicateType].forEach(context.insert)
        [keeperCorrespondent, duplicateCorrespondent].forEach(context.insert)
        try context.save()

        #expect(MetadataMaintenance.mergeDuplicates(in: context, recorder: recorder) == 3)
        let merged = Dictionary(uniqueKeysWithValues: recorder.records.map { ($0.id, $0.mergedInto) })
        #expect(merged[duplicateTag.id] == keeperTag.id)
        #expect(merged[duplicateType.id] == keeperType.id)
        #expect(merged[duplicateCorrespondent.id] == keeperCorrespondent.id)
    }
}

