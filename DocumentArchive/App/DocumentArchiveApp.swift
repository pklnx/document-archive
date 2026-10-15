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

    /// Creates the store chosen at launch (see `StoreChoice`). With CloudKit, SwiftData syncs
    /// through the private database (container `iCloud.de.patrickklein.DocumentArchive`).
    private static func makeContainer() -> ModelContainer {
        ArchiveStore.makeContainer(for: ArchiveStore.currentChoice())
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
