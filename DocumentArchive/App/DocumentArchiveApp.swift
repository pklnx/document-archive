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

    /// Erstellt den Datenspeicher. Mit iCloud-Entitlement synchronisiert SwiftData automatisch
    /// über die private CloudKit-Datenbank (Container `iCloud.de.patrickklein.DocumentArchive`).
    /// Ohne Entitlement (z. B. unsignierter Build) wird nur lokal gespeichert.
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
                print("CloudKit-Store konnte nicht geöffnet werden, verwende lokalen Speicher: \(error)")
            }
        }
        // Gleicher Speicherort wie mit CloudKit, damit beim späteren Aktivieren nichts verloren geht
        do {
            let local = ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            do {
                let local = ModelConfiguration("\(storeName)-lokal", schema: schema, cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: local)
            } catch {
                fatalError("Datenspeicher konnte nicht erstellt werden: \(error)")
            }
        }
    }
}

/// Aktionen des aktuellen Fensters, damit die Menüleiste (macOS) sie auslösen kann.
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
            Button("Dokumente importieren …") { actions?.importFiles() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Divider()
            Button("Neuer Tag …") { actions?.newTag() }
                .disabled(actions == nil)
            Button("Neuer Korrespondent …") { actions?.newCorrespondent() }
                .disabled(actions == nil)
            Button("Neuer Dokumenttyp …") { actions?.newDocumentType() }
                .disabled(actions == nil)
        }
    }
}
#endif
