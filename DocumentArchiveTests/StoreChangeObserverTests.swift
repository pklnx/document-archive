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

    /// Waits until `counter` reaches `count` or `timeout` passes; slow CI runners need the margin.
    private func waitUntil(_ counter: Counter, reaches count: Int, timeout: Duration = .seconds(10)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while counter.count < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func severalSavesGiveOneDebouncedSignal() async throws {
        let container = try TestSupport.makeContainer()
        // A long debounce compared with the time three back-to-back saves take, also on a slow runner.
        let debounce = Duration.milliseconds(800)
        let observer = StoreChangeObserver(container: container, debounce: debounce)
        let (counter, task) = subscribe(observer)
        defer { task.cancel(); observer.stop() }

        for title in ["A", "B", "C"] {
            container.mainContext.insert(ArchiveTag(name: title))
            try container.mainContext.save()
        }
        #expect(counter.count == 0, "still waiting for quiet")
        try await waitUntil(counter, reaches: 1)
        // No second signal for the same burst.
        try await Task.sleep(for: debounce * 2)
        #expect(counter.count == 1)

        container.mainContext.insert(ArchiveTag(name: "D"))
        try container.mainContext.save()
        try await waitUntil(counter, reaches: 2)
        try await Task.sleep(for: debounce * 2)
        #expect(counter.count == 2)
    }

    /// An archive on disk, so its store has its own URL (in-memory stores share `/dev/null`).
    private func makeStoreOnDisk() throws -> ModelContainer {
        let schema = DocumentArchiveApp.schema
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "Test.store")
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url,
                                                                                  cloudKitDatabase: .none))
    }

    /// SwiftData posts `NSPersistentStoreRemoteChange` for every save; the observer relies on it
    /// for changes that do not pass through a `ModelContext` of the app (CloudKit import).
    @Test func theStorePostsRemoteChangeNotifications() async throws {
        let container = try makeStoreOnDisk()
        let storeURL = try #require(container.configurations.first?.url)
        let center = NotificationCenter.default
        let notified = Counter()
        let token = center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { notification in
            let url = notification.userInfo?[StoreChangeObserver.storeURLKey] as? URL
            guard url != nil, StoreChangeObserver.isSameStore(url, storeURL) else { return }
            Task { @MainActor in notified.count += 1 }
        }
        defer { center.removeObserver(token) }

        container.mainContext.insert(ArchiveTag(name: "Tax"))
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(300))
        #expect(notified.count >= 1)
    }

    @Test func savesOfAnotherArchiveAreIgnored() async throws {
        let container = try makeStoreOnDisk()
        let other = try makeStoreOnDisk()
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
        try await Task.sleep(for: .milliseconds(300))
        #expect(first.count == 1)
        #expect(second.count == 1)
    }
}
