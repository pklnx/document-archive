import CoreData
import Foundation
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
    static let storeName = "DocumentArchive"
    static let schema = Schema([Document.self, Tag.self, Correspondent.self, DocumentType.self])

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
            return container
        }
        migrate()
        if choice == .cloudKit {
            do {
                let config = ModelConfiguration(storeName, schema: schema,
                                                cloudKitDatabase: .private(SyncMonitor.containerIdentifier))
                let container = try ModelContainer(for: schema, configurations: config)
                SyncMonitor.shared.isCloudKitEnabled = true
                return container
            } catch {
                print("Could not open the CloudKit store, using local storage: \(error)")
            }
        }
        // Same location as with CloudKit, so nothing is lost when sync is turned on later
        do {
            let local = ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            do {
                let local = ModelConfiguration("\(storeName)-lokal", schema: schema, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: local)
            } catch {
                fatalError("Could not create the store: \(error)")
            }
        }
    }
}
