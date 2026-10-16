import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Writing the archive into the folder (#8 part 1). Every test uses temporary directories and
/// in-memory archives; iCloud is simulated with `FakeUbiquityStatus`.
@Suite @MainActor struct ArchiveMirrorWriteTests {
    @Test func initialWriteCreatesPDFsSidecarsAndEntityFiles() async throws {
        let device = try MirrorFixture()
        let tag = ArchiveTag(name: "Tax")
        let correspondent = Correspondent(name: "Stadtwerke")
        let type = DocumentType(name: "Invoice")
        device.context.insert(tag)
        device.context.insert(correspondent)
        device.context.insert(type)
        let documents = ["Bill", "Contract", "Letter"].map { title in
            let document = device.insertDocument(title, pdf: TestSupport.samplePDF(lines: [title]))
            document.tags = [tag]
            document.correspondent = correspondent
            document.documentType = type
            return document
        }
        try device.context.save()

        let result = try await device.run()

        #expect(result.documentsWritten == 3)
        #expect(result.pdfsWritten == 3)
        #expect(result.entitiesWritten == 3)
        let layout = device.layout
        #expect(device.files(in: layout.folder(.document)).count == 6)
        for document in documents {
            let pdf = try Data(contentsOf: layout.pdf(document.id))
            #expect(pdf == document.pdfData)
            let sidecar = try device.sidecar(document.id)
            #expect(sidecar["pdfSHA256"] as? String == ArchiveFolderFormat.sha256(pdf))
            #expect(sidecar["title"] as? String == document.title)
            #expect(sidecar["tagIDs"] as? [String] == [tag.id.uuidString])
            #expect(sidecar["correspondentName"] as? String == "Stadtwerke")
            #expect(sidecar["writtenBy"] as? String == "device-A")
        }
        #expect(FileManager.default.fileExists(atPath: layout.record(.tag, tag.id).path))
        #expect(FileManager.default.fileExists(atPath: layout.record(.correspondent, correspondent.id).path))
        let typeFile = try ArchiveFolderFormat.decode(EntityRecord.self,
                                                      from: Data(contentsOf: layout.record(.documentType, type.id)))
        #expect(typeFile.name == "Invoice")
        #expect(typeFile.changedAt != nil)
        let info = try ArchiveFolderFormat.decode(ArchiveInfo.self, from: Data(contentsOf: layout.archiveInfo))
        #expect(info.formatVersion == "1.0")
    }

    @Test func documentsStillProcessingWaitForTheirText() async throws {
        let device = try MirrorFixture()
        let document = device.insertDocument("Scan")
        document.isProcessing = true
        try device.context.save()

        #expect(try await device.run().documentsWritten == 0)
        document.isProcessing = false
        #expect(try await device.run().documentsWritten == 1)
    }

    @Test func interruptedWriteLeavesNoPartialFile() async throws {
        let device = try MirrorFixture()
        let document = device.insertDocument("Bill")
        try device.context.save()
        let failing = ArchiveFileIO(beforeRename: { url in
            if url.pathExtension == "pdf" { throw CocoaError(.fileWriteOutOfSpace) }
        })

        await #expect(throws: CocoaError.self) { try await device.run(io: failing) }

        let documentsFolder = device.layout.folder(.document)
        #expect(!FileManager.default.fileExists(atPath: device.layout.pdf(document.id).path))
        #expect(!FileManager.default.fileExists(atPath: device.layout.record(.document, document.id).path))
        let all = (try? FileManager.default.contentsOfDirectory(atPath: documentsFolder.path)) ?? []
        #expect(all.isEmpty, "no temporary files left: \(all)")

        // An interrupted overwrite keeps the old content.
        try await device.run()
        let before = try Data(contentsOf: device.layout.record(.document, document.id))
        document.title = "Changed"
        document.touch()
        let failingSidecar = ArchiveFileIO(beforeRename: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        await #expect(throws: CocoaError.self) { try await device.run(io: failingSidecar) }
        #expect(try Data(contentsOf: device.layout.record(.document, document.id)) == before)
        #expect(device.files(in: documentsFolder).count == 2)
    }

    @Test func onlyChangedFilesAreWritten() async throws {
        let device = try MirrorFixture()
        let bill = device.insertDocument("Bill")
        let other = device.insertDocument("Other")
        try device.context.save()
        try await device.run()

        let unchanged = try await device.run()
        #expect(unchanged.filesWritten == 0)

        bill.title = "Electricity bill"
        bill.touch()
        let otherSidecar = try Data(contentsOf: device.layout.record(.document, other.id))
        let titleEdit = try await device.run()
        #expect(titleEdit.documentsWritten == 1)
        #expect(titleEdit.pdfsWritten == 0)
        #expect(try device.sidecar(bill.id)["title"] as? String == "Electricity bill")
        #expect(try Data(contentsOf: device.layout.record(.document, other.id)) == otherSidecar)

        // Replacing the PDF (e.g. #9's text layer) calls touch(); same size, new content.
        let replacement = MirrorFixture.pdfBytes("Bill").map { $0 == UInt8(ascii: "B") ? UInt8(ascii: "b") : $0 }
        bill.pdfData = Data(replacement)
        bill.touch()
        let pdfChange = try await device.run()
        #expect(pdfChange.pdfsWritten == 1)
        #expect(try Data(contentsOf: device.layout.pdf(bill.id)) == Data(replacement))
        #expect(try device.sidecar(bill.id)["pdfSHA256"] as? String == ArchiveFolderFormat.sha256(Data(replacement)))

        // Renaming a tag rewrites the tag file and the sidecars that name it, not the PDFs.
        let tag = ArchiveTag(name: "Tax")
        device.context.insert(tag)
        bill.tags = [tag]
        try await device.run()
        tag.name = "Taxes"
        let rename = try await device.run()
        #expect(rename.entitiesWritten == 1)
        #expect(rename.documentsWritten == 1)
        #expect(rename.pdfsWritten == 0)
        #expect(try await device.run().filesWritten == 0)
    }

    @Test func unknownFieldsSurviveATitleEdit() async throws {
        let device = try MirrorFixture()
        let document = device.insertDocument("Bill")
        try device.context.save()
        try await device.run()
        var object = try device.sidecar(document.id)
        object["futureField"] = ["written": "by a newer version"]
        try JSONSerialization.data(withJSONObject: object).write(to: device.layout.record(.document, document.id))

        document.title = "Edited"
        document.touch()
        try await device.run()

        let rewritten = try device.sidecar(document.id)
        #expect(rewritten["title"] as? String == "Edited")
        #expect((rewritten["futureField"] as? [String: String])?["written"] == "by a newer version")
    }

    @Test func newerMajorFormatStopsBeforeWritingAndMinorIsAccepted() async throws {
        let device = try MirrorFixture()
        device.insertDocument("Bill")
        try device.context.save()
        try FileManager.default.createDirectory(at: device.layout.root, withIntermediateDirectories: true)
        try Data(#"{"formatVersion":"2.0"}"#.utf8).write(to: device.layout.archiveInfo)

        #expect(ArchiveMirror.inspect(device.folder) == .newerFormat("2.0"))
        await #expect(throws: ArchiveMirror.MirrorError.newerFormat("2.0")) { try await device.run() }
        #expect(device.files(in: device.layout.folder(.document)).isEmpty)
        #expect(try Data(contentsOf: device.layout.archiveInfo) == Data(#"{"formatVersion":"2.0"}"#.utf8))

        try Data(#"{"formatVersion":"1.9","newKey":true}"#.utf8).write(to: device.layout.archiveInfo)
        #expect(try await device.run().documentsWritten == 1)
    }

    @Test func inspectTellsAnExistingArchiveFromAnEmptyFolder() async throws {
        let device = try MirrorFixture()
        #expect(ArchiveMirror.inspect(device.folder) == .empty)
        device.insertDocument("A")
        device.insertDocument("B")
        try device.context.save()
        try await device.run()
        #expect(ArchiveMirror.inspect(device.folder) == .archive(documents: 2))
    }

    /// Two devices on one folder: a newer sidecar from the other device is never overwritten, and
    /// equal `modifiedAt` is decided by `writtenBy` the same way on both devices.
    @Test func newerSidecarFromAnotherDeviceIsNotOverwritten() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        let a = try MirrorFixture(folder: folder, deviceID: "device-A")
        let b = try MirrorFixture(folder: folder, deviceID: "device-B")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let onA = a.insertDocument("Invoice")
        let onB = b.insertDocument("Invoice")
        for document in [onA, onB] {
            document.createdAt = t0
            document.documentDate = t0
            document.modifiedAt = t0
        }
        onB.id = onA.id
        try a.context.save()
        try b.context.save()

        #expect(try await a.run().documentsWritten == 1)
        let adopted = try await b.run()
        #expect(adopted.documentsWritten == 0, "the same document is taken over, not rewritten")
        #expect(adopted.leftInFolder == 0)

        onA.title = "Edited on A"
        onA.modifiedAt = t0.addingTimeInterval(20)
        #expect(try await a.run().documentsWritten == 1)

        onB.title = "Older edit on B"
        onB.modifiedAt = t0.addingTimeInterval(10)
        let older = try await b.run()
        #expect(older.leftInFolder == 1)
        #expect(try a.sidecar(onA.id)["title"] as? String == "Edited on A")

        // Equal modifiedAt: "device-B" > "device-A", so B wins on B …
        onB.title = "Same time on B"
        onB.modifiedAt = t0.addingTimeInterval(20)
        #expect(try await b.run().documentsWritten == 1)
        // … and A agrees.
        onA.notes = "Same time on A"
        let tie = try await a.run()
        #expect(tie.leftInFolder == 1)
        #expect(tie.documentsWritten == 0)
        #expect(try a.sidecar(onA.id)["title"] as? String == "Same time on B")
        #expect(try a.sidecar(onA.id)["writtenBy"] as? String == "device-B")
    }

    @Test func evictedFilesAreNeverTreatedAsMissing() async throws {
        let device = try MirrorFixture()
        let document = device.insertDocument("Bill")
        try device.context.save()
        try await device.run()
        let before = try Data(contentsOf: device.layout.record(.document, document.id))

        // macOS 14+: dataless under its real name.
        let ubiquity = FakeUbiquityStatus()
        ubiquity.set(.dataless, for: device.layout.record(.document, document.id))
        document.title = "Edited"
        document.touch()
        let result = try await device.run(ubiquity: ubiquity)
        #expect(result.waitingForDownload == 1)
        #expect(result.documentsWritten == 0)
        #expect(ubiquity.downloadRequests == ["\(document.id.uuidString).json"])
        #expect(try Data(contentsOf: device.layout.record(.document, document.id)) == before)

        // Downloaded: the edit is written in the next pass.
        #expect(try await device.run().documentsWritten == 1)
    }

    /// iOS and older providers: only a `.<name>.icloud` placeholder is there. The writer must not
    /// create the file next to it as if it were new.
    @Test func placeholderIsNotOverwrittenByANewFile() async throws {
        let device = try MirrorFixture()
        let document = device.insertDocument("Bill")
        try device.context.save()
        let documentsFolder = device.layout.folder(.document)
        try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
        let sidecar = device.layout.record(.document, document.id)
        try Data().write(to: UbiquityStatus.placeholderURL(for: sidecar))
        #expect(UbiquityStatus().state(of: sidecar) == .placeholder)

        let ubiquity = FakeUbiquityStatus()   // real placeholder detection, records downloads
        let result = try await device.run(ubiquity: ubiquity)

        #expect(result.waitingForDownload == 1)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(!FileManager.default.fileExists(atPath: device.layout.pdf(document.id).path))
        #expect(ubiquity.downloadRequests == [sidecar.lastPathComponent])
    }

    /// New device (state reset): a sidecar it never wrote, from another device and with other
    /// content, stays as it is; only objects that are not in the folder yet are written.
    @Test func newDeviceWritesOnlyNewObjects() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        let other = try MirrorFixture(folder: folder, deviceID: "device-B")
        let shared = other.insertDocument("Written by B")
        try other.context.save()
        try await other.run()
        let foreign = try Data(contentsOf: other.layout.record(.document, shared.id))

        let device = try MirrorFixture(folder: folder, deviceID: "device-A")
        let mine = device.insertDocument("Local copy")
        mine.id = shared.id
        let new = device.insertDocument("Only here")
        try device.context.save()
        let result = try await device.run()

        #expect(result.documentsWritten == 1)
        #expect(result.leftInFolder == 1)
        #expect(try Data(contentsOf: device.layout.record(.document, shared.id)) == foreign)
        #expect(try device.sidecar(new.id)["title"] as? String == "Only here")
    }

    /// The real store's identity: stable for one store file, different for another one.
    @Test func storeIdentifierBelongsToTheStoreFile() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        let schema = Schema([Document.self, ArchiveTag.self, Correspondent.self, DocumentType.self])
        func open(_ name: String) throws -> URL {
            let url = folder.appending(path: "\(name).store")
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
                schema: schema, url: url, cloudKitDatabase: .none))
            container.mainContext.insert(ArchiveTag(name: "x"))
            try container.mainContext.save()
            return url
        }
        let first = try open("A")
        let id = try #require(ArchiveStore.storeIdentifier(at: first))
        _ = try open("A")
        #expect(ArchiveStore.storeIdentifier(at: first) == id, "reopening keeps the identity")
        let second = try open("B")
        #expect(ArchiveStore.storeIdentifier(at: second) != id)
        #expect(ArchiveStore.storeIdentifier(at: folder.appending(path: "missing.store")) == nil)
    }

    @Test func onlyStoresOnDiskGetAFolderCopy() {
        #expect(!StoreChoice.inMemory(seed: false).isOnDisk)
        #expect(!StoreChoice.inMemory(seed: true).isOnDisk)
        #expect(StoreChoice.local.isOnDisk)
        #expect(StoreChoice.cloudKit.isOnDisk)
    }
}
