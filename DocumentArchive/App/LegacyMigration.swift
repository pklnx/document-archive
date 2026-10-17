import Foundation
import os

/// Takes over data from the time the app was called "Ablage", once per device:
/// the database with its PDFs, the Mistral API key and the settings.
/// The old files stay in place as a backup.
enum LegacyMigration {
    static let legacyName = "Ablage"
    static let legacyBundleID = "de.patrickklein.Ablage"
    static let doneKey = "migratedFromAblage"

    static let settingKeys = [
        "documentSort", "showInspector", AutoClassifier.autoCreateCorrespondentsKey,
        MistralConfig.useOCRKey, MistralConfig.useLLMKey, MistralConfig.ocrModelKey, MistralConfig.chatModelKey,
    ]

    /// - Parameters:
    ///   - directory: Folder holding the stores; defaults to Application Support.
    ///   - defaults: The app's settings, which also record that the migration ran.
    ///   - legacyDefaults: The settings of the old app; see `legacyDefaults(sandboxed:)`.
    ///   - migrateAPIKey: Copy the Mistral key in the Keychain (off in tests).
    static func run(
        newStoreName: String,
        directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = legacyDefaults(sandboxed: AppSandbox.isActive),
        migrateAPIKey: Bool = true
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        if let directory { migrateStore(to: newStoreName, in: directory) }
        if let legacyDefaults { migrateSettings(from: legacyDefaults, to: defaults) }
        if migrateAPIKey { copyAPIKey() }
        defaults.set(true, forKey: doneKey)
    }

    /// The old app's settings domain, read only by unsandboxed Mac builds (development builds,
    /// which never reach the App Store). A sandboxed app may not read another app's domain
    /// (cfprefsd denies it, and the privacy manifest's CA92.1 covers only the app's own settings),
    /// and on iPhone and iPad it never held the old app's data. The migration has run long before
    /// the first sandboxed build (pre-check in docs/development/index.md, "Sandbox"), and its
    /// result moves into the container with the app's own preferences.
    static func legacyDefaults(sandboxed: Bool) -> UserDefaults? {
        sandboxed ? nil : UserDefaults(suiteName: legacyBundleID)
    }

    /// Copies `Ablage.store` (with WAL/SHM and the folder holding the PDFs) to the new name.
    private static func migrateStore(to newName: String, in dir: URL) {
        let fm = FileManager.default
        let oldStore = dir.appending(path: "\(legacyName).store")
        let newStore = dir.appending(path: "\(newName).store")
        guard fm.fileExists(atPath: oldStore.path), !fm.fileExists(atPath: newStore.path) else { return }

        let pairs = [
            ("\(legacyName).store", "\(newName).store"),
            ("\(legacyName).store-wal", "\(newName).store-wal"),
            ("\(legacyName).store-shm", "\(newName).store-shm"),
            (".\(legacyName)_SUPPORT", ".\(newName)_SUPPORT"),
        ]
        do {
            for (old, new) in pairs where fm.fileExists(atPath: dir.appending(path: old).path) {
                try fm.copyItem(at: dir.appending(path: old), to: dir.appending(path: new))
            }
            Log.store.notice("Legacy migration: took over the old database")
        } catch {
            // Remove a partial copy, so the next launch can try again cleanly
            for (_, new) in pairs { try? fm.removeItem(at: dir.appending(path: new)) }
            Log.store.error("Legacy migration: taking over the old database failed: \(Log.code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func migrateSettings(from old: UserDefaults, to defaults: UserDefaults) {
        for key in settingKeys {
            if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func copyAPIKey() {
        guard KeychainStore.read(MistralConfig.apiKeyAccount) == nil,
              let key = KeychainStore.read(MistralConfig.apiKeyAccount, service: legacyBundleID) else { return }
        KeychainStore.save(key, for: MistralConfig.apiKeyAccount)
    }
}
