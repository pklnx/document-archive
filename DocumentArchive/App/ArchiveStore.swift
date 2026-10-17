import CoreData
import Foundation
import os
import SwiftData

/// Which store the app opens at launch.
enum StoreChoice: Equatable {
    /// Unit tests and UI tests: nothing is read from or written to disk, never synced.
    case inMemory(seed: Bool)
    /// The archive on disk, synced through the private CloudKit database.
    case cloudKit
    /// The archive on disk, not synced.
    case local

    /// Launch argument for UI tests: start with an in-memory store filled with sample data.
    /// Only honoured in DEBUG builds.
    static let uiTestSeedArgument = "-UITestSeed"

    /// Decided before anything touches the disk: test runs never open the real archive,
    /// never run migrations and never contact iCloud.
    /// Only stores on disk get a folder copy; test and sample-data runs never touch a folder.
    var isOnDisk: Bool {
        if case .inMemory = self { return false }
        return true
    }

    static func decide(isRunningTests: Bool, arguments: [String], cloudKitAvailable: Bool) -> StoreChoice {
        if isRunningTests { return .inMemory(seed: false) }
        #if DEBUG
        if arguments.contains(uiTestSeedArgument) { return .inMemory(seed: true) }
        #endif
        return cloudKitAvailable ? .cloudKit : .local
    }
}

/// Creates the SwiftData container for a `StoreChoice`.
@MainActor
enum ArchiveStore {
    // nonisolated: read by the default `migrate` closure below, which is not on the main actor.
    nonisolated static let storeName = "DocumentArchive"
    static let schema = DocumentArchiveApp.schema

    /// The store the app opened at launch, for the diagnostics report; `nil` before.
    private(set) static var opened: OpenedStore?

    /// What `makeContainer` actually opened (a CloudKit choice can fall back to local storage).
    enum OpenedStore: String {
        case inMemory = "in memory"
        case sampleData = "in memory with sample data"
        case cloudKit = "CloudKit"
        case local = "local"
        /// The second fallback, `DocumentArchive-lokal.store`, after the normal store failed.
        case localFallback = "local fallback"
    }

    /// The persistent store's `NSStoreUUIDKey`. It identifies this store file: a lost, reset or
    /// fallback store has another one, which the folder copy uses to notice that its bookkeeping
    /// belongs to a different store. `nil` for in-memory stores.
    nonisolated static func storeIdentifier(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        else { return nil }
        return metadata[NSStoreUUIDKey] as? String
    }

    static func currentChoice() -> StoreChoice {
        StoreChoice.decide(isRunningTests: TestEnvironment.isRunningTests,
                           arguments: ProcessInfo.processInfo.arguments,
                           cloudKitAvailable: SyncMonitor.cloudKitAvailable())
    }

    /// - Parameter migrate: takes over data of the app's old name; only run for stores on disk.
    static func makeContainer(
        for choice: StoreChoice,
        migrate: () -> Void = { LegacyMigration.run(newStoreName: storeName) }
    ) -> ModelContainer {
        if case .inMemory(let seed) = choice {
            let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            #if DEBUG
            if seed { UITestSeed.fill(container.mainContext) }
            #endif
            return record(container, seed ? .sampleData : .inMemory)
        }
        migrate()
        if choice == .cloudKit {
            do {
                let config = ModelConfiguration(storeName, schema: schema,
                                                cloudKitDatabase: .private(SyncMonitor.containerIdentifier))
                let container = try ModelContainer(for: schema, configurations: config)
                SyncMonitor.shared.isCloudKitEnabled = true
                return record(container, .cloudKit)
            } catch {
                Log.store.error("CloudKit store failed, using local storage: \(Log.code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        // Same location as with CloudKit, so nothing is lost when sync is turned on later
        do {
            let local = ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
            return try record(ModelContainer(for: schema, configurations: local), .local)
        } catch {
            Log.store.error("Local store failed, trying the fallback store: \(Log.code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            do {
                let local = ModelConfiguration("\(storeName)-lokal", schema: schema, cloudKitDatabase: .none)
                return try record(ModelContainer(for: schema, configurations: local), .localFallback)
            } catch {
                Log.store.fault("Could not create the store: \(Log.code(of: error), privacy: .public)")
                fatalError("Could not create the store: \(error)")
            }
        }
    }

    private static func record(_ container: ModelContainer, _ store: OpenedStore) -> ModelContainer {
        opened = store
        Log.store.notice("Store opened: \(store.rawValue, privacy: .public)")
        return container
    }
}
