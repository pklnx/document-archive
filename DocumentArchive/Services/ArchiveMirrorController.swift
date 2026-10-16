import Foundation
import Observation
import SwiftData

/// Runs the folder copy in the app: keeps the chosen folder (`FolderAccess`), starts a pass at
/// launch, when the store changes (`StoreChangeObserver`, debounced) and when the app becomes
/// active, and provides the state to the settings section and the sidebar footer.
///
/// Only stores on disk get a folder copy. Test runs and the UI test sample data never start it,
/// so they never write into a real folder.
@MainActor
@Observable
final class ArchiveMirrorController {
    static let shared = ArchiveMirrorController()
    /// `UserDefaults` key of the folder bookmark.
    nonisolated static let bookmarkKey = "archiveFolderBookmark"

    /// `false` while the app runs without a store on disk (tests, sample data).
    private(set) var isAvailable = false
    /// The folder the user chose, when it could be resolved.
    private(set) var folderURL: URL?
    private(set) var isRunning = false
    /// Documents done and total of the running pass.
    private(set) var progress: (done: Int, total: Int)?
    private(set) var lastRun: Date?
    private(set) var lastError: String?
    private(set) var deletionsAwaitingConfirmation: Int?
    /// A message about the last folder choice (folder already holds an archive, …).
    var notice: String?

    /// Whether a folder is chosen (even when it is not reachable right now).
    private(set) var isEnabled = false

    @ObservationIgnored private let folderAccess: FolderAccess
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var stateStore: ArchiveMirrorStateStore?
    @ObservationIgnored private var storeIdentifier: String?
    @ObservationIgnored private var observer: StoreChangeObserver?
    @ObservationIgnored private var observerTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false

    init(folderAccess: FolderAccess = FolderAccess(key: ArchiveMirrorController.bookmarkKey)) {
        self.folderAccess = folderAccess
    }

    /// Called once at launch for a store on disk.
    func start(container: ModelContainer) {
        guard let storeURL = container.configurations.first?.url,
              let identifier = ArchiveStore.storeIdentifier(at: storeURL) else { return }
        self.container = container
        storeIdentifier = identifier
        let stateStore = ArchiveMirrorStateStore(
            url: storeURL.deletingLastPathComponent().appending(path: ArchiveMirrorStateStore.fileName))
        self.stateStore = stateStore
        isAvailable = true
        isEnabled = folderAccess.hasFolder
        refreshFromState()
        DocumentDeletion.recorder = { [weak self] in self?.recorder }

        let observer = StoreChangeObserver(container: container)
        self.observer = observer
        observerTask = Task { [weak self] in
            for await _ in observer.changes() {
                self?.syncNow()
            }
        }
        syncNow()
    }

    /// Where deletions are recorded: only while a folder is chosen.
    private var recorder: DeletionRecording? {
        isEnabled ? stateStore : nil
    }

    // MARK: Actions

    /// A folder from the folder picker. A folder that already holds an archive is not used yet:
    /// reading it comes with #8 part 2, and nothing is written into it.
    func choose(_ url: URL) async {
        guard isAvailable else { return }
        let contents = await FolderAccess.withAccess(to: url) {
            await Task.detached(priority: .userInitiated) { ArchiveMirror.inspect(url) }.value
        }
        switch contents {
        case .archive(let count):
            notice = String(localized: "This folder already contains an archive with \(count) documents. Reading an existing archive comes with the next update, so nothing was written to it.")
            return
        case .newerFormat(let version):
            notice = ArchiveMirror.MirrorError.newerFormat(version).localizedDescription
            return
        case .empty:
            break
        }
        do {
            try folderAccess.save(url)
        } catch {
            notice = error.localizedDescription
            return
        }
        runTask?.cancel()
        stateStore?.reset(storeIdentifier: storeIdentifier)   // a new folder starts from scratch
        folderURL = url
        isEnabled = true
        refreshFromState()
        syncNow()
    }

    /// Writes what changed now (also "Sync Now" in the settings).
    func syncNow(confirmDeletions: Bool = false) {
        guard isEnabled else { return }
        if runTask != nil {
            rerunRequested = true
            return
        }
        runTask = Task {
            await performPass(confirmDeletions: confirmDeletions)
            runTask = nil
            if rerunRequested {
                rerunRequested = false
                syncNow()
            }
        }
    }

    /// Stops the running pass; it continues with the next one (at the latest on the next launch).
    func cancel() {
        rerunRequested = false
        runTask?.cancel()
    }

    /// "Back to Default": stops using the folder. The files in it stay.
    func useDefaultLocation() {
        cancel()
        folderAccess.clear()
        isEnabled = false
        stateStore?.reset(storeIdentifier: storeIdentifier)
        folderURL = nil
        refreshFromState()
    }

    func confirmDeletions() {
        syncNow(confirmDeletions: true)
    }

    /// The deleted documents stay in the folder.
    func discardDeletions() {
        stateStore?.discardPendingDeletions()
        refreshFromState()
    }

    // MARK: Pass

    private func performPass(confirmDeletions: Bool) async {
        guard let container, let stateStore, let storeIdentifier else { return }
        isRunning = true
        defer {
            isRunning = false
            progress = nil
            refreshFromState()
        }
        do {
            let folder = try folderAccess.resolve().url
            folderURL = folder
            try await FolderAccess.withAccess(to: folder) {
                let mirror = ArchiveMirror(context: container.mainContext, folder: folder, stateStore: stateStore,
                                           storeIdentifier: storeIdentifier)
                _ = try await BackgroundActivity.run("Folder copy") {
                    try await mirror.run(confirmDeletions: confirmDeletions) { [weak self] done, total in
                        self?.progress = (done, total)
                    }
                }
            }
        } catch {
            stateStore.update { $0.lastError = error.localizedDescription }
        }
    }

    private func refreshFromState() {
        let state = stateStore?.state
        lastRun = state?.lastRun
        lastError = isEnabled ? state?.lastError : nil
        deletionsAwaitingConfirmation = isEnabled ? state?.deletionsAwaitingConfirmation : nil
    }
}
