import CoreData
import Foundation
import SwiftData

/// One debounced signal "the store changed", shared by everything that follows the archive's
/// changes: the folder copy (#8) now, later Spotlight (#15), deadlines (#11) and Ask (#17).
/// Subscribers call `changes()` instead of observing notifications themselves.
///
/// Sources:
/// - `ModelContext.didSave` of any context of the observed container (local edits, imports);
/// - `NSPersistentStoreRemoteChange` of the container's store. SwiftData keeps persistent history
///   and posts it after every save to the store (`StoreChangeObserverTests` checks this). The
///   CloudKit mirroring saves the changes it imports from other devices into the same store,
///   without a `ModelContext` of the app, so they arrive this way. That the import posts it is
///   checked once the paid account exists (#7); if not, reading the persistent history is the
///   fallback.
///
/// Many saves in a short time (an import, a bulk edit) give one signal after `debounce`.
@MainActor
final class StoreChangeObserver {
    private let debounce: Duration
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var pending: Task<Void, Never>?

    init(container: ModelContainer, debounce: Duration = .seconds(5), center: NotificationCenter = .default) {
        self.debounce = debounce
        self.center = center
        tokens.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            // Other containers (tests, previews) are ignored.
            guard (notification.object as? ModelContext)?.container === container else { return }
            Task { @MainActor in self?.signal() }
        })
        let storeURL = container.configurations.first?.url
        tokens.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { [weak self] notification in
            guard Self.isSameStore(notification.userInfo?[Self.storeURLKey] as? URL, storeURL) else { return }
            Task { @MainActor in self?.signal() }
        })
    }

    /// The `userInfo` key of the store's URL in `NSPersistentStoreRemoteChange`.
    nonisolated static let storeURLKey = "storeURL"

    /// A notification without a URL is accepted; one for another store file is not.
    nonisolated static func isSameStore(_ notified: URL?, _ observed: URL?) -> Bool {
        guard let notified, let observed else { return true }
        return notified.standardizedFileURL.resolvingSymlinksInPath() == observed.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// A new stream for one subscriber; it yields once per debounced change.
    func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    /// Stops observing and ends every stream.
    func stop() {
        tokens.forEach(center.removeObserver)
        tokens = []
        pending?.cancel()
        continuations.values.forEach { $0.finish() }
        continuations = [:]
    }

    /// Restarts the debounce timer; also used for triggers that are no store change.
    func signal() {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.continuations.values.forEach { $0.yield() }
        }
    }
}
