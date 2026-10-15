import Foundation

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
    ///   - legacyDefaults: The settings of the old app.
    ///   - migrateAPIKey: Copy the Mistral key in the Keychain (off in tests).
    static func run(
        newStoreName: String,
        directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: legacyBundleID),
        migrateAPIKey: Bool = true
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        if let directory { migrateStore(to: newStoreName, in: directory) }
        if let legacyDefaults { migrateSettings(from: legacyDefaults, to: defaults) }
        if migrateAPIKey { copyAPIKey() }
        defaults.set(true, forKey: doneKey)
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
        } catch {
            // Remove a partial copy, so the next launch can try again cleanly
            for (_, new) in pairs { try? fm.removeItem(at: dir.appending(path: new)) }
            print("Taking over the old database failed: \(error)")
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
