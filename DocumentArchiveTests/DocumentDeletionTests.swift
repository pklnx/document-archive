import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Deletes and the folder copy: explicit deletions only, the lost-store guard, the mass-delete
/// guard, `Deleted/` retention and merge tombstones.
@Suite @MainActor struct DocumentDeletionTests {
    private let day: TimeInterval = 24 * 60 * 60

    /// A device whose `count` documents are already in the folder.
    private func mirroredDevice(documents count: Int) async throws -> (MirrorFixture, [Document]) {
        let device = try MirrorFixture()
        let documents = (0..<count).map { device.insertDocument("Document \($0)") }
        try device.context.save()
        #expect(try await device.run().documentsWritten == count)
        return (device, documents)
    }

    private func tombstones(_ device: MirrorFixture) -> [String] {
        device.files(in: device.layout.tombstones)
    }

    /// 10 documents, so deleting one stays within the mass-delete guard (10 %).
    @Test func deletionMovesThePairToDeletedAndWritesATombstone() async throws {
        let (device, documents) = try await mirroredDevice(documents: 10)
        let deleted = documents[0]
        let id = deleted.id
        let deletedAt = Date(timeIntervalSince1970: 1_790_000_000)

        DocumentDeletion.delete([deleted], in: device.context, recorder: device.stateStore, now: deletedAt)
        #expect(try device.context.fetch(FetchDescriptor<Document>()).count == 9)
        #expect(device.stateStore.state.pendingDeletions.map(\.id) == [id])

        let result = try await device.run()

        #expect(result.tombstonesWritten == 1)
        let layout = device.layout
        #expect(!FileManager.default.fileExists(atPath: layout.pdf(id).path))
        #expect(!FileManager.default.fileExists(atPath: layout.record(.document, id).path))
        #expect(device.files(in: layout.deleted) == ["\(id.uuidString).json", "\(id.uuidString).pdf"])
        let tombstone = try ArchiveFolderFormat.decode(Tombstone.self, from: Data(contentsOf: layout.tombstone(id)))
        #expect(tombstone.kind == .document)
        #expect(tombstone.deletedBy == "device-A")
        #expect(tombstone.deletedAt == deletedAt)
        #expect(tombstone.mergedInto == nil)
        #expect(device.stateStore.state.pendingDeletions.isEmpty)
        #expect(device.files(in: layout.folder(.document)).count == 18, "the other documents stay")
    }

    @Test func deletingThroughTheStoreDirectlyWritesNoTombstone() async throws {
        let (device, documents) = try await mirroredDevice(documents: 2)
        device.context.delete(documents[0])
        try device.context.save()

        let result = try await device.run()

        #expect(result.tombstonesWritten == 0)
        #expect(tombstones(device).isEmpty)
        #expect(device.files(in: device.layout.folder(.document)).count == 4, "nothing is inferred from a diff")
    }

    @Test func documentDeletionWithoutAFolderOnlyDeletes() throws {
        let device = try MirrorFixture()
        let documents = [device.insertDocument("A"), device.insertDocument("B")]
        try device.context.save()
        let recorded = RecordedDeletions()

        DocumentDeletion.delete(documents, in: device.context, recorder: nil)
        #expect(try device.context.fetch(FetchDescriptor<Document>()).isEmpty)

        // Already deleted documents are skipped and not recorded again.
        DocumentDeletion.delete(documents, in: device.context, recorder: recorded)
        #expect(recorded.records.isEmpty)
    }

    /// The state belongs to store A; the container is a new, empty store B. Nothing is deleted
    /// from the folder, no tombstone is written, and the state starts over.
    @Test func lostStoreWritesNoTombstones() async throws {
        let (device, documents) = try await mirroredDevice(documents: 3)
        DocumentDeletion.delete([documents[0]], in: device.context, recorder: device.stateStore)
        let deviceID = device.stateStore.state.deviceID

        let emptyStore = try TestSupport.makeContainer()
        let result = try await device.mirror(context: emptyStore.mainContext, storeIdentifier: "store-B").run()

        #expect(result.stateWasReset)
        #expect(result.filesWritten == 0)
        #expect(tombstones(device).isEmpty)
        #expect(device.files(in: device.layout.folder(.document)).count == 6)
        #expect(device.files(in: device.layout.deleted).isEmpty)
        let state = device.stateStore.state
        #expect(state.storeIdentifier == "store-B")
        #expect(state.pendingDeletions.isEmpty)
        #expect(state.documents.isEmpty)
        #expect(state.deviceID == deviceID)
    }

    /// 210 documents, so 21 deletions are exactly 10 %: only the count rule decides.
    @Test(arguments: [20, 21])
    func moreThan20DeletedDocumentsWaitForConfirmation(deletions: Int) async throws {
        let (device, documents) = try await mirroredDevice(documents: 210)
        DocumentDeletion.delete(Array(documents.prefix(deletions)), in: device.context, recorder: device.stateStore)

        let result = try await device.run()

        if deletions <= 20 {
            #expect(result.deletionsAwaitingConfirmation == nil)
            #expect(result.tombstonesWritten == deletions)
        } else {
            #expect(result.deletionsAwaitingConfirmation == deletions)
            #expect(result.tombstonesWritten == 0)
            #expect(tombstones(device).isEmpty)
            #expect(device.files(in: device.layout.deleted).isEmpty, "no files moved")
            #expect(device.stateStore.state.deletionsAwaitingConfirmation == deletions)

            // Another pass does not apply them either; confirming does.
            #expect(try await device.run().tombstonesWritten == 0)
            let confirmed = try await device.run(confirming: device.shownDeletions)
            #expect(confirmed.tombstonesWritten == deletions)
            #expect(device.stateStore.state.deletionsAwaitingConfirmation == nil)
            #expect(device.files(in: device.layout.folder(.document)).count == (210 - deletions) * 2)
        }
    }

    /// The 10 % rule applies only from 50 documents in the folder (maintainer decision).
    @Test(arguments: [(documents: 49, deletions: 6, stops: false),
                      (documents: 50, deletions: 5, stops: false),
                      (documents: 50, deletions: 6, stops: true)])
    func deletingMoreThanTenPercentWaitsForConfirmation(documents count: Int, deletions: Int, stops: Bool) async throws {
        let (device, documents) = try await mirroredDevice(documents: count)
        DocumentDeletion.delete(Array(documents.prefix(deletions)), in: device.context, recorder: device.stateStore)

        let result = try await device.run()

        #expect(result.tombstonesWritten == (stops ? 0 : deletions))
        #expect(result.deletionsAwaitingConfirmation == (stops ? deletions : nil))
    }

    /// Only documents count: deleting many tags never asks, also while documents are held back.
    @Test func deletedTagsDoNotCountTowardsTheGuard() async throws {
        let (device, documents) = try await mirroredDevice(documents: 50)
        let tags = (0..<25).map { ArchiveTag(name: "Tag \($0)") }
        tags.forEach(device.context.insert)
        try device.context.save()
        try await device.run()

        for tag in tags { MetadataDeletion.delete(tag, in: device.context, recorder: device.stateStore) }
        try device.context.save()
        DocumentDeletion.delete(Array(documents.prefix(6)), in: device.context, recorder: device.stateStore)
        let result = try await device.run()

        #expect(result.tombstonesWritten == 25, "the tags pass")
        #expect(result.deletionsAwaitingConfirmation == 6, "the documents wait")
        #expect(device.files(in: device.layout.folder(.tag)).isEmpty)
    }

    /// "Confirm" applies the deletions that were shown; deletions recorded afterwards are checked
    /// on their own.
    @Test func confirmingAppliesOnlyTheShownDeletions() async throws {
        let (device, documents) = try await mirroredDevice(documents: 60)
        DocumentDeletion.delete(Array(documents[0..<7]), in: device.context, recorder: device.stateStore)
        #expect(try await device.run().deletionsAwaitingConfirmation == 7)
        let shown = device.shownDeletions

        DocumentDeletion.delete(Array(documents[7..<14]), in: device.context, recorder: device.stateStore)
        let result = try await device.run(confirming: shown)

        #expect(result.tombstonesWritten == 7)
        #expect(Set(tombstones(device)) == Set(documents[0..<7].map { "\($0.id.uuidString).json" }))
        #expect(result.deletionsAwaitingConfirmation == 7, "7 of the 53 left are more than 10 %")
        #expect(Set(device.shownDeletions.map(\.id)) == Set(documents[7..<14].map(\.id)))
    }

    @Test func discardingKeepsTheDocumentsInTheFolder() async throws {
        let (device, documents) = try await mirroredDevice(documents: 60)
        let deleted = Array(documents.prefix(7))
        let ids = deleted.map(\.id)
        DocumentDeletion.delete(deleted, in: device.context, recorder: device.stateStore)
        #expect(try await device.run().deletionsAwaitingConfirmation == 7)

        device.stateStore.discardHeldDeletions()
        let after = try await device.run()

        #expect(after.tombstonesWritten == 0)
        #expect(after.deletionsAwaitingConfirmation == nil)
        #expect(device.stateStore.state.pendingDeletions.isEmpty)
        for id in ids {
            #expect(FileManager.default.fileExists(atPath: device.layout.record(.document, id).path))
            #expect(FileManager.default.fileExists(atPath: device.layout.pdf(id).path))
        }
        #expect(tombstones(device).isEmpty)
    }

    @Test func deletedFilesArePurgedAfter30DaysAndTombstonesAfterAYear() async throws {
        let (device, documents) = try await mirroredDevice(documents: 10)
        let start = Date()
        let id = documents[0].id
        DocumentDeletion.delete([documents[0]], in: device.context, recorder: device.stateStore, now: start)
        try await device.run(now: { start })
        #expect(device.files(in: device.layout.deleted).count == 2)

        try await device.run(now: { start.addingTimeInterval(29 * day) })
        #expect(device.files(in: device.layout.deleted).count == 2, "kept for 30 days")

        try await device.run(now: { start.addingTimeInterval(31 * day) })
        #expect(device.files(in: device.layout.deleted).isEmpty)
        #expect(tombstones(device) == ["\(id.uuidString).json"], "the tombstone stays for a year")

        try await device.run(now: { start.addingTimeInterval(364 * day) })
        #expect(tombstones(device).count == 1)
        try await device.run(now: { start.addingTimeInterval(366 * day) })
        #expect(tombstones(device).isEmpty)
    }

    /// Two devices merge the same duplicates (inserted in a different order, same `createdAt`)
    /// and keep the same tag: `createdAt`, then the smallest `id`. The merge writes a tombstone
    /// with `mergedInto` and removes the duplicate's file.
    @Test func mergingTagsWritesATombstoneWithMergedInto() async throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        var keepers: [UUID] = []
        for order in [[0, 1], [1, 0]] {
            let device = try MirrorFixture()
            let tags = order.map { index in
                let tag = ArchiveTag(name: index == 0 ? "Tax" : "tax")
                tag.id = ids[index]
                tag.createdAt = created
                device.context.insert(tag)
                return tag
            }
            let document = device.insertDocument("Bill")
            document.tags = [tags[1]]
            try device.context.save()
            try await device.run()

            #expect(MetadataMaintenance.mergeDuplicates(in: device.context, recorder: device.stateStore) == 1)
            let kept = try #require(try device.context.fetch(FetchDescriptor<ArchiveTag>()).first)
            keepers.append(kept.id)
            #expect(document.sortedTags.map(\.id) == [kept.id])

            let result = try await device.run()
            #expect(result.tombstonesWritten == 1)
            let removed = ids.first { $0 != kept.id }!
            let tombstone = try ArchiveFolderFormat.decode(Tombstone.self,
                                                           from: Data(contentsOf: device.layout.tombstone(removed)))
            #expect(tombstone.kind == .tag)
            #expect(tombstone.mergedInto == kept.id)
            #expect(!FileManager.default.fileExists(atPath: device.layout.record(.tag, removed).path))
            #expect(FileManager.default.fileExists(atPath: device.layout.record(.tag, kept.id).path))
        }
        #expect(keepers == [ids[0], ids[0]], "both devices keep the tag with the smallest id")
    }

    @Test func deletingATagWritesATombstoneWithoutMergedInto() async throws {
        let device = try MirrorFixture()
        let tag = ArchiveTag(name: "Old")
        device.context.insert(tag)
        try device.context.save()
        try await device.run()

        MetadataDeletion.delete(tag, in: device.context, recorder: device.stateStore)
        try device.context.save()
        #expect(try await device.run().tombstonesWritten == 1)

        let tombstone = try ArchiveFolderFormat.decode(Tombstone.self, from: Data(contentsOf: device.layout.tombstone(tag.id)))
        #expect(tombstone.kind == .tag)
        #expect(tombstone.mergedInto == nil)
        #expect(device.files(in: device.layout.folder(.tag)).isEmpty)
    }

    @Test func removingDuplicateDocumentsGoesThroughDocumentDeletion() throws {
        let device = try MirrorFixture()
        let original = device.insertDocument("Original")
        original.contentHash = "same"
        original.createdAt = .distantPast
        let copy = device.insertDocument("Copy")
        copy.contentHash = "same"
        try device.context.save()
        let recorded = RecordedDeletions()

        #expect(MetadataMaintenance.removeDuplicateDocuments(in: device.context, recorder: recorded) == 1)
        #expect(recorded.records.map(\.id) == [copy.id])
        #expect(recorded.records.first?.kind == .document)
    }

    /// A deletion of a document that never reached the folder writes nothing.
    @Test func deletionBeforeTheFirstCopyIsDropped() async throws {
        let device = try MirrorFixture()
        let document = device.insertDocument("Short-lived")
        try device.context.save()
        DocumentDeletion.delete([document], in: device.context, recorder: device.stateStore)

        let result = try await device.run()

        #expect(result.tombstonesWritten == 0)
        #expect(device.stateStore.state.pendingDeletions.isEmpty)
    }
}
