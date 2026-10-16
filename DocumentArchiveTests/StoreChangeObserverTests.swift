import CoreData
import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// The shared "store changed" signal (`StoreChangeObserver`).
@Suite @MainActor struct StoreChangeObserverTests {
    /// Counts the signals of one subscriber.
    @MainActor
    final class Counter {
        var count = 0
    }

    private func subscribe(_ observer: StoreChangeObserver) -> (Counter, Task<Void, Never>) {
        let counter = Counter()
        let stream = observer.changes()
        let task = Task { @MainActor in
            for await _ in stream { counter.count += 1 }
        }
        return (counter, task)
    }

    /// Waits until `condition` holds or `timeout` (scaled) passes; slow CI runners need the margin.
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + TestSupport.scaled(timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntil(_ counter: Counter, reaches count: Int) async throws {
        try await waitUntil { counter.count >= count }
    }

    /// A burst of saves (their `didSave` and remote change notifications) gives one signal.
    /// The notifications are posted to the observer's own center: with real saves, a remote
    /// change notification that arrives late on a busy runner (tests run in parallel) would be a
    /// second burst.
    @Test func severalSavesGiveOneDebouncedSignal() async throws {
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = Duration.milliseconds(300)
        let observer = StoreChangeObserver(container: container, debounce: debounce, center: center)
        let (counter, task) = subscribe(observer)
        defer { task.cancel(); observer.stop() }
        let storeURL = try #require(container.configurations.first?.url)
        func save() {
            center.post(name: ModelContext.didSave, object: container.mainContext)
            center.post(name: .NSPersistentStoreRemoteChange, object: nil,
                        userInfo: [StoreChangeObserver.storeURLKey: storeURL])
        }

        for _ in 0..<3 { save() }
        #expect(counter.count == 0, "still waiting for quiet")
        try await waitUntil(counter, reaches: 1)
        // No second signal for the same burst.
        try await Task.sleep(for: debounce * 2)
        #expect(counter.count == 1)

        save()
        try await waitUntil(counter, reaches: 2)
        try await Task.sleep(for: debounce * 2)
        #expect(counter.count == 2)
    }

    /// A real save to the store reaches the observer (through `didSave` or the remote change).
    @Test func aSaveIsSignalled() async throws {
        // On disk: in-memory stores of tests running in parallel all report `/dev/null` as their
        // URL, so their saves would count as changes of this store.
        let container = try TestSupport.makeContainerOnDisk()
        let observer = StoreChangeObserver(container: container, debounce: .milliseconds(50))
        let (counter, task) = subscribe(observer)
        defer { task.cancel(); observer.stop() }

        container.mainContext.insert(ArchiveTag(name: "Tax"))
        try container.mainContext.save()
        try await waitUntil(counter, reaches: 1)
        #expect(counter.count >= 1)
    }

    /// SwiftData posts `NSPersistentStoreRemoteChange` for every save; the observer relies on it
    /// for changes that do not pass through a `ModelContext` of the app (CloudKit import).
    @Test func theStorePostsRemoteChangeNotifications() async throws {
        let container = try TestSupport.makeContainerOnDisk()
        let storeURL = try #require(container.configurations.first?.url)
        let center = NotificationCenter.default
        // Recorded on the posting thread, not through the main actor, which the tests running in
        // parallel keep busy.
        let notified = Recorder<URL>()
        let token = center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { notification in
            guard let url = notification.userInfo?[StoreChangeObserver.storeURLKey] as? URL,
                  StoreChangeObserver.isSameStore(url, storeURL) else { return }
            notified.append(url)
        }
        defer { center.removeObserver(token) }

        container.mainContext.insert(ArchiveTag(name: "Tax"))
        try container.mainContext.save()
        try await waitUntil { !notified.values.isEmpty }
        #expect(!notified.values.isEmpty)
    }

    @Test func savesOfAnotherArchiveAreIgnored() async throws {
        let container = try TestSupport.makeContainerOnDisk()
        let other = try TestSupport.makeContainerOnDisk()
        let observer = StoreChangeObserver(container: container, debounce: .milliseconds(50))
        let (counter, task) = subscribe(observer)
        defer { task.cancel(); observer.stop() }

        other.mainContext.insert(ArchiveTag(name: "Elsewhere"))
        try other.mainContext.save()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)
    }

    /// Changes from other devices arrive as `NSPersistentStoreRemoteChange` (CloudKit store).
    @Test func remoteChangesAreSignalledToEverySubscriber() async throws {
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let observer = StoreChangeObserver(container: container, debounce: .milliseconds(50), center: center)
        let (first, firstTask) = subscribe(observer)
        let (second, secondTask) = subscribe(observer)
        defer { firstTask.cancel(); secondTask.cancel(); observer.stop() }

        center.post(name: .NSPersistentStoreRemoteChange, object: nil,
                    userInfo: [StoreChangeObserver.storeURLKey: URL(filePath: "/elsewhere.store")])
        try await Task.sleep(for: .milliseconds(300))
        #expect(first.count == 0, "another store")

        center.post(name: .NSPersistentStoreRemoteChange, object: nil,
                    userInfo: [StoreChangeObserver.storeURLKey: container.configurations.first!.url])
        // Waits instead of a fixed sleep: with tests running in parallel the main actor is busy.
        try await waitUntil(first, reaches: 1)
        try await waitUntil(second, reaches: 1)
        #expect(first.count == 1)
        #expect(second.count == 1)
    }
}
