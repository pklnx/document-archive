import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Simulates evicted iCloud files: states set here win, everything else is decided by the real
/// `UbiquityStatus` (which also detects real `.icloud` placeholder files). Records download requests.
final class FakeUbiquityStatus: UbiquityStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [String: UbiquitousFileState] = [:]
    private var downloads: [URL] = []

    func set(_ state: UbiquitousFileState, for url: URL) {
        lock.withLock { overrides[url.standardizedFileURL.path] = state }
    }

    var downloadRequests: [String] {
        lock.withLock { downloads.map(\.lastPathComponent) }
    }

    func state(of url: URL) -> UbiquitousFileState {
        lock.withLock { overrides[url.standardizedFileURL.path] } ?? UbiquityStatus().state(of: url)
    }

    func startDownloading(_ url: URL) {
        lock.withLock { downloads.append(url) }
    }
}

/// One "device": an in-memory archive, its folder-copy state and the folder it writes to (a
/// temporary directory, never a real folder). Two fixtures on one folder are two devices.
@MainActor
struct MirrorFixture {
    let container: ModelContainer
    /// The folder the user "chose"; files go into its `Document Archive/` subfolder.
    let folder: URL
    let stateStore: ArchiveMirrorStateStore
    var context: ModelContext { container.mainContext }
    var layout: ArchiveFolderLayout { ArchiveFolderLayout(chosenFolder: folder) }

    init(folder: URL? = nil, deviceID: String = "device-A") throws {
        container = try TestSupport.makeContainer()
        self.folder = try folder ?? TestSupport.makeTemporaryDirectory()
        let stateFolder = try TestSupport.makeTemporaryDirectory()
        stateStore = ArchiveMirrorStateStore(url: stateFolder.appending(path: ArchiveMirrorStateStore.fileName))
        stateStore.update { $0.deviceID = deviceID }
    }

    func mirror(context: ModelContext? = nil, storeIdentifier: String = "store-A",
                ubiquity: UbiquityStatusProviding = UbiquityStatus(), io: ArchiveFileIO = ArchiveFileIO(),
                options: ArchiveMirror.Options = .init(), now: @escaping () -> Date = Date.init) -> ArchiveMirror {
        ArchiveMirror(context: context ?? self.context, folder: folder, stateStore: stateStore,
                      storeIdentifier: storeIdentifier, ubiquity: ubiquity, io: io, options: options, now: now)
    }

    @discardableResult
    func run(confirmDeletions: Bool = false, ubiquity: UbiquityStatusProviding = UbiquityStatus(),
             io: ArchiveFileIO = ArchiveFileIO(), now: @escaping () -> Date = Date.init) async throws -> ArchiveMirror.PassResult {
        try await mirror(ubiquity: ubiquity, io: io, now: now).run(confirmDeletions: confirmDeletions)
    }

    /// A processed document with small fake PDF bytes (the mirror does not read the PDF).
    @discardableResult
    func insertDocument(_ title: String, pdf: Data? = nil) -> Document {
        let document = Document(title: title, pdfData: pdf ?? Self.pdfBytes(title), source: .file)
        document.isProcessing = false
        context.insert(document)
        return document
    }

    static func pdfBytes(_ text: String) -> Data {
        Data("%PDF-1.4 \(text)".utf8)
    }

    /// Visible file names in a folder, sorted.
    func files(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The document's sidecar as a JSON object.
    func sidecar(_ id: UUID) throws -> [String: Any] {
        let data = try Data(contentsOf: layout.record(.document, id))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Collects explicit deletions without a folder.
@MainActor
final class RecordedDeletions: DeletionRecording {
    var records: [DeletionRecord] = []

    func record(_ deletions: [DeletionRecord]) {
        records += deletions
    }
}
