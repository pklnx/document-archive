import SwiftData
import SwiftUI

@main
struct DocumentArchiveApp: App {
    let container: ModelContainer = Self.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .commands {
            ImportCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(width: 520, height: 480)
                .modelContainer(container)
        }
        #endif
    }

    /// Creates the store. With the iCloud entitlement, SwiftData syncs automatically through the
    /// private CloudKit database (container `iCloud.de.patrickklein.DocumentArchive`).
    /// Without it (e.g. an unsigned build), data is stored locally only.
    static let storeName = "DocumentArchive"

    static let schema = Schema([Document.self, Tag.self, Correspondent.self, DocumentType.self])

    private static func makeContainer() -> ModelContainer {
        // Unit tests are hosted by the app: never touch the real archive during a test run.
        if TestEnvironment.isRunningTests {
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }
        LegacyMigration.run(newStoreName: storeName)
        let monitor = SyncMonitor.shared
        if SyncMonitor.hasCloudKitEntitlement {
            do {
                let config = ModelConfiguration(storeName, schema: schema,
                                                cloudKitDatabase: .private(SyncMonitor.containerIdentifier))
                let container = try ModelContainer(for: schema, configurations: config)
                monitor.isCloudKitEnabled = true
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

/// Actions of the current window, so the menu bar (macOS) can trigger them.
struct ImportActions {
    var importFiles: () -> Void
    var newTag: () -> Void
    var newCorrespondent: () -> Void
    var newDocumentType: () -> Void
}

extension FocusedValues {
    @Entry var importActions: ImportActions?
}

#if os(macOS)
struct ImportCommands: Commands {
    @FocusedValue(\.importActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Documents…") { actions?.importFiles() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Divider()
            Button("New Tag…") { actions?.newTag() }
                .disabled(actions == nil)
            Button("New Correspondent…") { actions?.newCorrespondent() }
                .disabled(actions == nil)
            Button("New Document Type…") { actions?.newDocumentType() }
                .disabled(actions == nil)
        }
    }
}
#endif
