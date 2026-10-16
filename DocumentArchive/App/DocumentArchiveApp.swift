import SwiftData
import SwiftUI

@main
struct DocumentArchiveApp: App {
    /// Every synced model: the store, the tests and the UI test data all use this one schema.
    nonisolated static var schema: Schema {
        Schema([Document.self, Tag.self, Correspondent.self, DocumentType.self])
    }

    let container: ModelContainer

    /// Creates the store chosen at launch (see `StoreChoice`). With CloudKit, SwiftData syncs
    /// through the private database (container `iCloud.de.patrickklein.DocumentArchive`).
    /// A store on disk also gets the folder copy, when the user chose a folder (#8).
    init() {
        let choice = ArchiveStore.currentChoice()
        container = ArchiveStore.makeContainer(for: choice)
        let changes = StoreChangeObserver(container: container)
        if choice.isOnDisk {
            ArchiveMirrorController.shared.start(container: container, changes: changes)
        }
        if !TestEnvironment.isRunningTests {
            TagCycleRepair.shared.start(container: container, changes: changes)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
        .commands {
            AppCommands()
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(width: 560, height: 520)
                .modelContainer(container)
        }
        #endif
    }
}
