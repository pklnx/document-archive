import Foundation
import SwiftData

/// Writes the local archive into the chosen folder (the "copy in the folder", #8 part 1). Reading
/// it back (restore, two-way sync) follows in #8 part 2.
///
/// One `run()` is one pass:
/// 1. **Store identity:** a state that belongs to another store is discarded (new device: write
///    only what is not in the folder yet, never write tombstones from the old state).
/// 2. `archive.json`: created, or checked – a newer major format stops the pass before anything
///    is written.
/// 3. Tags, correspondents, document types, saved views and documents whose record hash changed
///    are written; a PDF only when its size or SHA-256 changed. A sidecar written by another device that is
///    newer is never overwritten, and files of objects this state has never written are only
///    touched when they were written by this device.
/// 4. Explicit deletions (`DocumentDeletion`, `MetadataDeletion`) become tombstones; deleted
///    documents move to `Deleted/`. A pass that would delete more than 20 documents, or more than
///    10 % of the folder's documents (only from 50 documents on), waits for confirmation.
/// 5. Once a day: `Deleted/` older than 30 days and tombstones older than a year are purged.
///
/// It needs only a `ModelContext` and a folder URL, so tests use an in-memory container and a
/// temporary directory. File work runs off the main actor (reading an evicted file blocks until it
/// has downloaded); evicted files are detected through `UbiquityStatusProviding` and retried later.
@MainActor
final class ArchiveMirror {
    struct Options {
        /// A pass that would delete more documents than this waits for confirmation. Only
        /// documents count; deleted tags, correspondents and types never ask.
        var maxDeletedDocuments = 20
        /// A pass that would delete more than this share (in percent) of the folder's documents
        /// waits for confirmation …
        var maxDeletedPercent = 10
        /// … but only when the folder holds at least this many documents, so a small archive
        /// does not ask for every single delete (maintainer decision on #8).
        var minDocumentsForPercentRule = 50
        var deletedRetention: TimeInterval = 30 * 24 * 60 * 60
        var tombstoneRetention: TimeInterval = 365 * 24 * 60 * 60
        var purgeInterval: TimeInterval = 24 * 60 * 60
        /// Documents whose PDFs are loaded and written together.
        var batchSize = 20
        var appVersion = ArchiveMirror.appVersion
    }

    enum MirrorError: LocalizedError, Equatable {
        /// `archive.json` names a major format version this app does not know.
        case newerFormat(String)
        /// `archive.json` is evicted; its download was requested.
        case folderNotDownloaded

        var errorDescription: String? {
            switch self {
            case .newerFormat(let version):
                String(localized: "The folder was created by a newer app version (format \(version)). Update the app to use it.")
            case .folderNotDownloaded:
                String(localized: "The folder is still downloading. The copy continues later.")
            }
        }
    }

    struct PassResult: Equatable {
        var documentsWritten = 0
        var pdfsWritten = 0
        var entitiesWritten = 0
        var tombstonesWritten = 0
        /// Files left alone: newer from another device, or never written by this device.
        var leftInFolder = 0
        /// Evicted files whose download was requested; retried in a later pass.
        var waitingForDownload = 0
        /// Set when the mass-delete guard held deletions back: the number of documents.
        var deletionsAwaitingConfirmation: Int?
        /// The state belonged to another store and was discarded.
        var stateWasReset = false
        var wasCancelled = false

        var filesWritten: Int { documentsWritten + pdfsWritten + entitiesWritten + tombstonesWritten }
    }

    /// What a chosen folder already contains.
    enum FolderContents: Equatable {
        /// No `Document Archive/`, or one without documents.
        case empty
        /// An archive whose documents were all written by this device (e.g. chosen again after
        /// "Back to Default"). Safe to use: the writer only overwrites its own files.
        case ownArchive(documents: Int)
        /// An archive with documents: reading it comes with #8 part 2.
        case archive(documents: Int)
        case newerFormat(String)
    }

    let context: ModelContext
    let layout: ArchiveFolderLayout
    let stateStore: ArchiveMirrorStateStore
    let storeIdentifier: String
    let ubiquity: UbiquityStatusProviding
    let io: ArchiveFileIO
    let options: Options
    let now: () -> Date

    /// - Parameters:
    ///   - folder: the folder the user chose; the files go into its `Document Archive/` subfolder.
    ///   - storeIdentifier: the store's `NSStoreUUIDKey` (`ArchiveStore.storeIdentifier`).
    init(context: ModelContext, folder: URL, stateStore: ArchiveMirrorStateStore, storeIdentifier: String,
         ubiquity: UbiquityStatusProviding = UbiquityStatus(), io: ArchiveFileIO = ArchiveFileIO(),
         options: Options = Options(), now: @escaping () -> Date = Date.init) {
        self.context = context
        self.layout = ArchiveFolderLayout(chosenFolder: folder)
        self.stateStore = stateStore
        self.storeIdentifier = storeIdentifier
        self.ubiquity = ubiquity
        self.io = io
        self.options = options
        self.now = now
    }

    nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Document Archive \(version) (\(build))"
    }

    /// Checks a folder before it is used for the first time.
    /// - Parameter deviceID: this device's id; a folder whose sidecars were all written by it is
    ///   `.ownArchive`. Evicted sidecars cannot be checked, so they count as foreign.
    nonisolated static func inspect(_ folder: URL, deviceID: String? = nil,
                                    ubiquity: UbiquityStatusProviding = UbiquityStatus()) -> FolderContents {
        let layout = ArchiveFolderLayout(chosenFolder: folder)
        let io = ArchiveFileIO()
        if ubiquity.state(of: layout.archiveInfo) == .available,
           let data = try? io.read(layout.archiveInfo),
           let info = try? ArchiveFolderFormat.decode(ArchiveInfo.self, from: data),
           !FormatVersion.isSupported(info.formatVersion) {
            return .newerFormat(info.formatVersion ?? "")
        }
        let ids = ArchiveFolderLayout.recordIDs(in: layout.folder(.document))
        guard !ids.isEmpty else { return .empty }
        let allOwn = deviceID != nil && ids.allSatisfy { id in
            let url = layout.record(.document, id)
            guard ubiquity.state(of: url) == .available, let data = try? io.read(url),
                  let record = try? ArchiveFolderFormat.decode(DocumentRecord.self, from: data) else { return false }
            return record.writtenBy == deviceID
        }
        return allOwn ? .ownArchive(documents: ids.count) : .archive(documents: ids.count)
    }

    // MARK: - Pass

    /// A cancelled pass (folder changed, "Back to Default", Cancel) stops after the running step
    /// and **does not update the state** with what that step wrote: the state may already belong
    /// to another folder. Files it wrote to its own folder are simply written again next time.
    /// - Parameters:
    ///   - confirming: the deletions the user confirmed – exactly those that were shown
    ///     (`ArchiveMirrorState.heldDeletions`). Deletions recorded later go through the guard again.
    ///   - progress: documents done and total, after each batch.
    @discardableResult
    func run(confirming: [DeletionRecord] = [], progress: ((Int, Int) -> Void)? = nil) async throws -> PassResult {
        var result = PassResult()
        do {
            try await pass(confirming: confirming, result: &result, progress: progress)
        } catch is CancellationError {
            result.wasCancelled = true
        }
        return result
    }

    private func pass(confirming: [DeletionRecord], result: inout PassResult,
                      progress: ((Int, Int) -> Void)?) async throws {
        if stateStore.state.storeIdentifier != storeIdentifier {
            result.stateWasReset = stateStore.state.storeIdentifier != nil
            stateStore.update { $0 = $0.reset(storeIdentifier: storeIdentifier) }
        }
        let now = now()
        let deviceID = stateStore.state.deviceID
        let (layout, io, ubiquity, appVersion) = (layout, io, ubiquity, options.appVersion)

        try await Self.background {
            try Self.prepareFolder(layout, io: io, ubiquity: ubiquity, appVersion: appVersion, now: now)
        }
        try Task.checkCancellation()
        try await writeEntities(deviceID: deviceID, now: now, result: &result)
        try await writeDocuments(deviceID: deviceID, result: &result, progress: progress)
        try await applyDeletions(deviceID: deviceID, now: now, confirming: confirming, result: &result)
        try await purgeIfDue(now: now)
        stateStore.update {
            $0.lastRun = now
            $0.lastError = nil
        }
    }

    // MARK: Folder

    nonisolated private static func prepareFolder(_ layout: ArchiveFolderLayout, io: ArchiveFileIO,
                                                  ubiquity: UbiquityStatusProviding, appVersion: String, now: Date) throws {
        switch ubiquity.state(of: layout.archiveInfo) {
        case .dataless, .placeholder:
            ubiquity.startDownloading(layout.archiveInfo)
            throw MirrorError.folderNotDownloaded
        case .available:
            let info = try? ArchiveFolderFormat.decode(ArchiveInfo.self, from: io.read(layout.archiveInfo))
            guard FormatVersion.isSupported(info?.formatVersion) else {
                throw MirrorError.newerFormat(info?.formatVersion ?? "")
            }
            try io.createFolders(layout.allFolders)
        case .missing:
            try io.createFolders([layout.root] + layout.allFolders)
            let info = ArchiveInfo(formatVersion: ArchiveFolderFormat.currentVersion.description,
                                   createdBy: appVersion, createdAt: ArchiveFolderFormat.normalized(now))
            try io.write(ArchiveFolderFormat.encode(info), to: layout.archiveInfo)
        }
    }

    // MARK: Entities

    private struct EntityWork<Record: MirroredRecord>: Sendable {
        var kind: ArchiveObjectKind
        var id: UUID
        /// Hash without `changedAt`.
        var recordHash: String
        var record: Record
        var isKnown: Bool
    }

    private enum Outcome: Sendable {
        case written(pdf: Bool)
        /// The content is what was written last time (e.g. `modifiedAt` changed, nothing else).
        case unchanged
        /// The folder already holds the same content (written by another device or before a reset).
        case adopted(changedAt: Date?)
        case leftInFolder
        case waitingForDownload
    }

    /// Tags, correspondents, document types and saved views.
    private func writeEntities(deviceID: String, now: Date, result: inout PassResult) async throws {
        var records: [(ArchiveObjectKind, EntityRecord)] = []
        records += try context.fetch(FetchDescriptor<Tag>()).map { (.tag, EntityRecord($0, writtenBy: deviceID)) }
        records += try context.fetch(FetchDescriptor<Correspondent>()).map { (.correspondent, EntityRecord($0, writtenBy: deviceID)) }
        records += try context.fetch(FetchDescriptor<DocumentType>()).map { (.documentType, EntityRecord($0, writtenBy: deviceID)) }
        try await writeRecords(records, deviceID: deviceID, now: now, result: &result)

        let views = try context.fetch(FetchDescriptor<SavedView>())
            .map { (ArchiveObjectKind.savedView, SavedViewRecord($0, writtenBy: deviceID)) }
        try await writeRecords(views, deviceID: deviceID, now: now, result: &result)
    }

    private func writeRecords<Record: MirroredRecord>(_ records: [(ArchiveObjectKind, Record)], deviceID: String,
                                                      now: Date, result: inout PassResult) async throws {
        let entries = stateStore.state.entities
        var changed: [EntityWork<Record>] = []
        for (kind, record) in records {
            guard let id = record.id else { continue }
            let hash = try Self.hash(record)
            let entry = entries[id.uuidString]
            if entry?.recordHash == hash { continue }
            var stamped = record
            stamped.changedAt = ArchiveFolderFormat.normalized(now)
            changed.append(EntityWork(kind: kind, id: id, recordHash: hash, record: stamped, isKnown: entry != nil))
        }
        guard !changed.isEmpty else { return }
        let work = changed

        let (layout, io, ubiquity) = (layout, io, ubiquity)
        let outcomes = try await Self.background {
            try work.map { try Self.write($0, deviceID: deviceID, layout: layout, io: io, ubiquity: ubiquity) }
        }
        try Task.checkCancellation()
        stateStore.update { state in
            for (item, outcome) in zip(work, outcomes) {
                switch outcome {
                case .written, .unchanged:
                    state.entities[item.id.uuidString] = .init(kind: item.kind, recordHash: item.recordHash,
                                                               changedAt: item.record.changedAt ?? now)
                    if case .written = outcome { result.entitiesWritten += 1 }
                case .adopted(let changedAt):
                    state.entities[item.id.uuidString] = .init(kind: item.kind, recordHash: item.recordHash,
                                                               changedAt: changedAt ?? now)
                case .leftInFolder: result.leftInFolder += 1
                case .waitingForDownload: result.waitingForDownload += 1
                }
            }
        }
    }

    nonisolated private static func write<Record: MirroredRecord>(
        _ item: EntityWork<Record>, deviceID: String, layout: ArchiveFolderLayout,
        io: ArchiveFileIO, ubiquity: UbiquityStatusProviding) throws -> Outcome {
        let url = layout.record(item.kind, item.id)
        let state = ubiquity.state(of: url)
        if state.needsDownload {
            ubiquity.startDownloading(url)
            return .waitingForDownload
        }
        var existingData: Data?
        if state == .available {
            existingData = try io.read(url)
            if let existing = try? ArchiveFolderFormat.decode(Record.self, from: existingData!),
               let writer = existing.writtenBy, writer != deviceID {
                if !item.isKnown {
                    var same = existing
                    same.changedAt = nil
                    same.writtenBy = deviceID
                    return (try? hash(same)) == item.recordHash ? .adopted(changedAt: existing.changedAt) : .leftInFolder
                }
                if existing.isNewer(than: item.record) { return .leftInFolder }
            }
        }
        try io.write(ArchiveFolderFormat.overlay(item.record, onto: existingData), to: url)
        return .written(pdf: false)
    }

    // MARK: Documents

    private struct DocumentWork: Sendable {
        var id: UUID
        /// `pdfSHA256` is filled in off the main actor when `pdf` is set.
        var record: DocumentRecord
        var previous: ArchiveMirrorState.DocumentEntry?
        var fileSize: Int
        var modifiedAt: Date
        /// Loaded only when the PDF's hash must be computed: new document, or `fileSize` or
        /// `modifiedAt` changed.
        var pdf: Data?
    }

    private func writeDocuments(deviceID: String, result: inout PassResult, progress: ((Int, Int) -> Void)?) async throws {
        let documents = try context.fetch(FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.isAlive && !$0.isProcessing }
        var done = 0
        progress?(0, documents.count)
        for start in stride(from: 0, to: documents.count, by: max(options.batchSize, 1)) {
            try Task.checkCancellation()
            let batch = documents[start..<min(start + options.batchSize, documents.count)]
            // Checked again for every batch: the user can delete a document while an earlier batch
            // is written, and reading a deleted model crashes.
            let work = try batch.filter { $0.isAlive && !$0.isProcessing }
                .compactMap { try makeWork(for: $0, deviceID: deviceID) }
            if !work.isEmpty {
                let (layout, io, ubiquity) = (layout, io, ubiquity)
                let outcomes = try await Self.background {
                    try work.map { try Self.write($0, deviceID: deviceID, layout: layout, io: io, ubiquity: ubiquity) }
                }
                try Task.checkCancellation()
                stateStore.update { state in
                    for (item, (outcome, entry)) in zip(work, outcomes) {
                        switch outcome {
                        case .written(let pdf):
                            state.documents[item.id.uuidString] = entry
                            result.documentsWritten += 1
                            if pdf { result.pdfsWritten += 1 }
                        case .adopted, .unchanged:
                            state.documents[item.id.uuidString] = entry
                        case .leftInFolder: result.leftInFolder += 1
                        case .waitingForDownload: result.waitingForDownload += 1
                        }
                    }
                }
            }
            done += batch.count
            progress?(done, documents.count)
        }
    }

    /// `nil` when nothing changed, or when the PDF is not on this device yet (iCloud download).
    private func makeWork(for document: Document, deviceID: String) throws -> DocumentWork? {
        let entry = stateStore.state.documents[document.id.uuidString]
        var work = DocumentWork(id: document.id, record: DocumentRecord(document, pdfSHA256: "", writtenBy: deviceID),
                                previous: entry, fileSize: document.fileSize, modifiedAt: document.modifiedAt)
        if let entry, entry.fileSize == document.fileSize, entry.modifiedAt == document.modifiedAt {
            // A normal pass does not hash every PDF; an unchanged record is skipped right here.
            work.record.pdfSHA256 = entry.pdfSHA256
            return try Self.hash(work.record) == entry.recordHash ? nil : work
        }
        guard let data = document.pdfData else { return nil }
        work.pdf = data
        return work
    }

    /// Hashes the PDF if needed, then writes what changed. Returns the state entry to remember.
    nonisolated private static func write(_ item: DocumentWork, deviceID: String, layout: ArchiveFolderLayout,
                                          io: ArchiveFileIO, ubiquity: UbiquityStatusProviding)
        throws -> (Outcome, ArchiveMirrorState.DocumentEntry) {
        var record = item.record
        let pdfSHA256 = item.pdf.map(ArchiveFolderFormat.sha256) ?? record.pdfSHA256 ?? ""
        record.pdfSHA256 = pdfSHA256
        let recordHash = try hash(record)
        let entry = ArchiveMirrorState.DocumentEntry(recordHash: recordHash, pdfSHA256: pdfSHA256,
                                                     fileSize: item.fileSize, modifiedAt: item.modifiedAt)
        let pdfChanged = item.previous.map { $0.pdfSHA256 != pdfSHA256 || $0.fileSize != item.fileSize } ?? true
        if !pdfChanged, item.previous?.recordHash == recordHash { return (.unchanged, entry) }

        let sidecar = layout.record(.document, item.id)
        let state = ubiquity.state(of: sidecar)
        if state.needsDownload {
            ubiquity.startDownloading(sidecar)
            return (.waitingForDownload, entry)
        }
        var existingData: Data?
        if state == .available {
            existingData = try io.read(sidecar)
            if let existing = try? ArchiveFolderFormat.decode(DocumentRecord.self, from: existingData!),
               let writer = existing.writtenBy, writer != deviceID {
                if item.previous == nil {
                    // Never written by this state: only take it over when it is the same document.
                    var same = existing
                    same.writtenBy = deviceID
                    return ((try? hash(same)) == recordHash ? .adopted(changedAt: nil) : .leftInFolder, entry)
                }
                // Newer data from another device belongs to the read step (#8 part 2).
                if existing.isNewer(than: record) { return (.leftInFolder, entry) }
            }
        }
        let pdf = pdfChanged ? item.pdf : nil
        if let pdf {
            try io.write(pdf, to: layout.pdf(item.id))
        }
        try io.write(ArchiveFolderFormat.overlay(record, onto: existingData), to: sidecar)
        return (.written(pdf: pdf != nil), entry)
    }

    // MARK: Deletions

    private enum DeletionOutcome: Sendable {
        case tombstoneWritten
        /// Never in the folder: nothing to delete there.
        case dropped
        case waitingForDownload
    }

    /// The mass-delete guard: more than `maxDeletedDocuments` documents, or more than
    /// `maxDeletedPercent` of the folder's documents (from `minDocumentsForPercentRule` on).
    /// Only document deletions count. Deletions in `confirming` were confirmed and pass.
    private func applyDeletions(deviceID: String, now: Date, confirming: [DeletionRecord],
                                result: inout PassResult) async throws {
        let pending = stateStore.state.pendingDeletions
        guard !pending.isEmpty else { return }
        let (layout, io, ubiquity, options) = (layout, io, ubiquity, options)

        let unconfirmed = pending.filter { !confirming.contains($0) }
        let documentsInFolder = await Self.inBackground { ArchiveFolderLayout.recordIDs(in: layout.folder(.document)) }
        try Task.checkCancellation()
        let documentDeletions = unconfirmed.filter { $0.kind == .document }
        let deletedFromFolder = documentDeletions.filter { documentsInFolder.contains($0.id) }.count
        let tooMany = documentDeletions.count > options.maxDeletedDocuments
        let tooLarge = documentsInFolder.count >= options.minDocumentsForPercentRule
            && deletedFromFolder * 100 > documentsInFolder.count * options.maxDeletedPercent
        // Only documents are held back; deleted tags, correspondents and types always pass.
        let held = tooMany || tooLarge ? documentDeletions : []
        let toApply = pending.filter { !held.contains($0) }
        if !held.isEmpty {
            result.deletionsAwaitingConfirmation = held.count
        }

        let known = Set(stateStore.state.documents.keys).union(stateStore.state.entities.keys)
        let outcomes = try await Self.background {
            try toApply.map { deletion in
                try Self.apply(deletion, wasMirrored: known.contains(deletion.id.uuidString), deviceID: deviceID,
                               now: now, layout: layout, io: io, ubiquity: ubiquity)
            }
        }
        try Task.checkCancellation()
        stateStore.update { state in
            var finished: [DeletionRecord] = []
            for (deletion, outcome) in zip(toApply, outcomes) {
                switch outcome {
                case .tombstoneWritten:
                    result.tombstonesWritten += 1
                    finished.append(deletion)
                case .dropped:
                    finished.append(deletion)
                case .waitingForDownload:
                    result.waitingForDownload += 1
                    continue
                }
                state.documents[deletion.id.uuidString] = nil
                state.entities[deletion.id.uuidString] = nil
            }
            // Deletions recorded while the files were moved stay for the next pass.
            state.pendingDeletions.removeAll { finished.contains($0) }
            // What the settings and the sidebar show, and what "Confirm" confirms.
            state.heldDeletions = held.isEmpty ? nil : held
        }
    }

    nonisolated private static func apply(_ deletion: DeletionRecord, wasMirrored: Bool, deviceID: String, now: Date,
                                          layout: ArchiveFolderLayout, io: ArchiveFileIO,
                                          ubiquity: UbiquityStatusProviding) throws -> DeletionOutcome {
        let id = deletion.id
        let files = deletion.kind == .document ? [layout.record(.document, id), layout.pdf(id)]
                                               : [layout.record(deletion.kind, id)]
        let states = files.map(ubiquity.state(of:))
        if states.contains(.placeholder) {
            // The real file is not on this device; moving the placeholder would lose it.
            files.forEach(ubiquity.startDownloading)
            return .waitingForDownload
        }
        guard wasMirrored || states.contains(where: \.exists) else { return .dropped }

        for (file, state) in zip(files, states) where state.exists {
            if deletion.kind == .document {
                // Kept for 30 days, so an accidental delete does not also delete the backup.
                let target = layout.deleted.appending(path: file.lastPathComponent)
                try io.move(file, to: target)
                io.setModificationDate(now, of: target)
            } else {
                try io.remove(file)
            }
        }
        let tombstone = Tombstone(id: id, kind: deletion.kind, deletedAt: ArchiveFolderFormat.normalized(deletion.deletedAt),
                                  deletedBy: deviceID, mergedInto: deletion.mergedInto,
                                  formatVersion: ArchiveFolderFormat.currentVersion.description)
        try io.write(ArchiveFolderFormat.encode(tombstone), to: layout.tombstone(id))
        return .tombstoneWritten
    }

    // MARK: Retention

    private func purgeIfDue(now: Date) async throws {
        if let last = stateStore.state.lastPurge, now.timeIntervalSince(last) < options.purgeInterval { return }
        let (layout, io, ubiquity, options) = (layout, io, ubiquity, options)
        await Self.inBackground {
            Self.purge(layout: layout, io: io, ubiquity: ubiquity, options: options, now: now)
        }
        try Task.checkCancellation()
        stateStore.update { $0.lastPurge = now }
    }

    nonisolated private static func purge(layout: ArchiveFolderLayout, io: ArchiveFileIO,
                                          ubiquity: UbiquityStatusProviding, options: Options, now: Date) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        // Hidden files (placeholders of evicted files) are skipped: they have no useful date.
        let deleted = (try? manager.contentsOfDirectory(at: layout.deleted, includingPropertiesForKeys: keys,
                                                         options: .skipsHiddenFiles)) ?? []
        for file in deleted {
            guard let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  now.timeIntervalSince(modified) > options.deletedRetention else { continue }
            try? io.remove(file)
        }
        let tombstones = (try? manager.contentsOfDirectory(at: layout.tombstones, includingPropertiesForKeys: keys,
                                                            options: .skipsHiddenFiles)) ?? []
        for file in tombstones where file.pathExtension == "json" && ubiquity.state(of: file) == .available {
            guard let data = try? io.read(file),
                  let deletedAt = (try? ArchiveFolderFormat.decode(Tombstone.self, from: data))?.deletedAt,
                  now.timeIntervalSince(deletedAt) > options.tombstoneRetention else { continue }
            try? io.remove(file)
        }
    }

    // MARK: Helpers

    nonisolated private static func hash<Record: Encodable>(_ record: Record) throws -> String {
        ArchiveFolderFormat.sha256(try ArchiveFolderFormat.encode(record))
    }

    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility, operation: work).value
    }

    nonisolated private static func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility, operation: work).value
    }
}

/// File operations in the archive folder. Every write is atomic (temporary file, then rename) and
/// coordinated (`NSFileCoordinator`), so a cloud provider only ever uploads complete files.
struct ArchiveFileIO: Sendable {
    /// Test seam: runs after the content is in the temporary file, before it gets its final name.
    var beforeRename: @Sendable (URL) throws -> Void = { _ in }

    func read(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: url, options: [], error: error) { target in
                result = Result { try Data(contentsOf: target) }
            }
        }
        return try result.get()
    }

    func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        // A temporary folder on the same volume that the provider does not sync.
        let staging = (try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: url.deletingLastPathComponent(), create: true))
        let temporary = staging?.appending(path: url.lastPathComponent)
            ?? url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer {
            if let staging { try? manager.removeItem(at: staging) } else { try? manager.removeItem(at: temporary) }
        }
        try data.write(to: temporary)
        try beforeRename(url)
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: error) { target in
                result = Result {
                    if manager.fileExists(atPath: target.path) {
                        _ = try manager.replaceItemAt(target, withItemAt: temporary)
                    } else {
                        try manager.moveItem(at: temporary, to: target)
                    }
                }
            }
        }
        try result.get()
    }

    /// Moves `source` to `destination`, replacing a file there.
    func move(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                                   options: .forReplacing, error: error) { from, to in
                result = Result {
                    if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
                    try manager.moveItem(at: from, to: to)
                }
            }
        }
        try result.get()
    }

    func remove(_ url: URL) throws {
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: error) { target in
                result = Result { try FileManager.default.removeItem(at: target) }
            }
        }
        try result.get()
    }

    func setModificationDate(_ date: Date, of url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func createFolders(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func coordinate(_ body: (NSFileCoordinator, NSErrorPointer) -> Void) throws {
        var error: NSError?
        body(NSFileCoordinator(), &error)
        if let error { throw error }
    }
}
