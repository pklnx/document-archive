import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// The folder copy while the user keeps working: deletes during a pass, a folder change while a
/// pass runs, "Confirm" during a pass, and choosing the own folder again.
@Suite @MainActor struct ArchiveMirrorRobustnessTests {
    /// Review finding: a document deleted while an earlier batch was written was read later
    /// (SwiftData traps on deleted models).
    @Test func documentDeletedDuringThePassIsSkipped() async throws {
        let device = try MirrorFixture()
        let documents = ["A", "B", "C"].enumerated().map { index, title in
            let document = device.insertDocument(title)
            document.createdAt = Date(timeIntervalSince1970: 1_790_000_000 + Double(index))
            return document
        }
        try device.context.save()
        let last = documents[2]
        let lastID = last.id
        var options = ArchiveMirror.Options()
        options.batchSize = 1

        let result = try await device.run(options: options, progress: { done, _ in
            if done == 1, last.isAlive {
                DocumentDeletion.delete([last], in: device.context, recorder: nil)
            }
        })

        #expect(result.documentsWritten == 2)
        #expect(!FileManager.default.fileExists(atPath: device.layout.record(.document, lastID).path))
    }

    /// Review finding: after the folder was changed during a pass, the old pass recorded the
    /// files it wrote to the old folder in the new folder's state, so they were never written there.
    @Test func cancelledPassRecordsNothingInAResetState() async throws {
        let device = try MirrorFixture()
        device.context.insert(ArchiveTag(name: "Tax"))
        device.insertDocument("Bill")
        try device.context.save()
        let slowTags = ArchiveFileIO(beforeRename: { url in
            if url.deletingLastPathComponent().lastPathComponent == "Tags" { Thread.sleep(forTimeInterval: 0.5) }
        })
        let mirror = device.mirror(io: slowTags)

        let pass = Task { try await mirror.run() }
        try await Task.sleep(for: .milliseconds(150))
        // What the controller does when another folder is chosen.
        device.stateStore.reset(storeIdentifier: "store-A")
        pass.cancel()
        let result = try await pass.value

        #expect(result.wasCancelled)
        #expect(device.stateStore.state.entities.isEmpty)
        #expect(device.stateStore.state.documents.isEmpty)
        #expect(device.stateStore.state.lastRun == nil)
    }

    /// Review finding: "Confirm" pressed while a pass ran was dropped, because the follow-up
    /// pass ran without the confirmation.
    @Test func confirmationWaitsForTheRunningPass() {
        let shown = [DeletionRecord(id: UUID(), kind: .document, deletedAt: Date())]
        var requests = PassRequests()
        #expect(requests.take() == nil)

        requests.add(confirming: [])        // store change while a pass runs
        requests.add(confirming: shown)     // "Confirm"
        requests.add(confirming: [])        // app became active
        #expect(requests.take() == shown, "one follow-up pass, with the confirmation")
        #expect(requests.take() == nil)

        requests.add(confirming: shown)
        requests.add(confirming: shown)
        #expect(requests.take() == shown, "not confirmed twice")
    }

    /// Choosing the own folder again (e.g. after "Back to Default") is accepted when every
    /// sidecar was written by this device; another device's or an evicted sidecar is not.
    @Test func ownArchiveCanBeChosenAgain() async throws {
        let device = try MirrorFixture(deviceID: "device-A")
        let document = device.insertDocument("Bill")
        device.insertDocument("Letter")
        try device.context.save()
        try await device.run()

        #expect(ArchiveMirror.inspect(device.folder, deviceID: "device-A") == .ownArchive(documents: 2))
        #expect(ArchiveMirror.inspect(device.folder, deviceID: "device-B") == .archive(documents: 2))
        #expect(ArchiveMirror.inspect(device.folder) == .archive(documents: 2))
        let evicted = FakeUbiquityStatus()
        evicted.set(.dataless, for: device.layout.record(.document, document.id))
        #expect(ArchiveMirror.inspect(device.folder, deviceID: "device-A", ubiquity: evicted) == .archive(documents: 2))

        // After "Back to Default" and choosing it again, the writer only rewrites its own files.
        device.stateStore.reset(storeIdentifier: "store-A")
        document.title = "Electricity bill"
        document.touch()
        let result = try await device.run()
        #expect(result.leftInFolder == 0)
        #expect(try device.sidecar(document.id)["title"] as? String == "Electricity bill")
    }
}
