import Foundation

/// The folder copy's local bookkeeping, in `ArchiveMirror.json` next to the store (not in the
/// folder, never synced).
///
/// It belongs to one store: `storeIdentifier` is the persistent store's `NSStoreUUIDKey`. When
/// the store is replaced (lost or reset, the `-lokal` fallback store, Application Support restored
/// separately), the state is discarded and the device counts as new: it writes only objects that
/// are not in the folder yet and never writes tombstones from the old state.
struct ArchiveMirrorState: Codable, Equatable {
    /// What was last written for a document.
    struct DocumentEntry: Codable, Equatable {
        /// SHA-256 of the sidecar as this device encoded it (without unknown keys).
        var recordHash: String
        var pdfSHA256: String
        var fileSize: Int
        /// `pdfSHA256` is computed again only when `fileSize` or `modifiedAt` changed.
        var modifiedAt: Date
    }

    /// What was last written for a tag, correspondent or document type.
    struct EntityEntry: Codable, Equatable {
        var kind: ArchiveObjectKind
        /// SHA-256 of the record without `changedAt`.
        var recordHash: String
        /// Local change time, written to the file as `changedAt` (the models have none).
        var changedAt: Date
    }

    var storeIdentifier: String?
    /// This device's id in the folder (`writtenBy`, `deletedBy`). Kept when the state is reset.
    var deviceID: String
    /// Keyed by UUID string.
    var documents: [String: DocumentEntry] = [:]
    var entities: [String: EntityEntry] = [:]
    /// Explicit deletions not yet written as tombstones (`DocumentDeletion`, `MetadataDeletion`).
    var pendingDeletions: [DeletionRecord] = []
    /// Document deletions the mass-delete guard held back. This is what the settings and the
    /// sidebar show, and exactly what "Confirm" confirms; later deletions are checked again.
    var heldDeletions: [DeletionRecord]?

    var deletionsAwaitingConfirmation: Int? { heldDeletions?.count }
    var lastRun: Date?
    var lastError: String?
    var lastPurge: Date?

    init(deviceID: String = UUID().uuidString, storeIdentifier: String? = nil) {
        self.deviceID = deviceID
        self.storeIdentifier = storeIdentifier
    }

    /// A fresh state for another store or folder; only the device id survives.
    func reset(storeIdentifier: String?) -> ArchiveMirrorState {
        ArchiveMirrorState(deviceID: deviceID, storeIdentifier: storeIdentifier)
    }
}

/// Loads and saves `ArchiveMirrorState`, and records explicit deletions into it.
@MainActor
final class ArchiveMirrorStateStore: DeletionRecording {
    static let fileName = "ArchiveMirror.json"

    let url: URL
    private(set) var state: ArchiveMirrorState

    /// Reads the state at `url`, or starts a new one.
    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(ArchiveMirrorState.self, from: data) {
            self.state = state
        } else {
            self.state = ArchiveMirrorState()
        }
    }

    func update(_ change: (inout ArchiveMirrorState) -> Void) {
        change(&state)
        save()
    }

    func record(_ deletions: [DeletionRecord]) {
        update { $0.pendingDeletions += deletions }
    }

    /// Drops the deletions the mass-delete guard held back ("Discard"). Their files stay in the
    /// folder, and the writer forgets them, so it never touches those files again. Deletions
    /// recorded after they were shown stay queued.
    func discardHeldDeletions() {
        update { state in
            let held = state.heldDeletions ?? []
            for deletion in held {
                state.documents[deletion.id.uuidString] = nil
                state.entities[deletion.id.uuidString] = nil
            }
            state.pendingDeletions.removeAll { held.contains($0) }
            state.heldDeletions = nil
        }
    }

    /// Starts over for another folder or store; only the device id is kept.
    func reset(storeIdentifier: String?) {
        update { $0 = $0.reset(storeIdentifier: storeIdentifier) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            print("Could not save the folder copy state: \(error)")
        }
    }
}
