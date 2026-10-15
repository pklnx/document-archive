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
        #endif
        .commands {
            AppCommands()
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(width: 520, height: 480)
                .modelContainer(container)
        }
        #endif
    }

    /// Creates the store chosen at launch (see `StoreChoice`). With CloudKit, SwiftData syncs
    /// through the private database (container `iCloud.de.patrickklein.DocumentArchive`).
    private static func makeContainer() -> ModelContainer {
        ArchiveStore.makeContainer(for: ArchiveStore.currentChoice())
    }
}
