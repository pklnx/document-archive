import Foundation

/// Übernimmt einmalig Daten aus der Zeit, als die App noch „Ablage“ hieß:
/// Datenbank samt PDFs, Mistral-API-Schlüssel und Einstellungen.
/// Die alten Dateien bleiben als Sicherung liegen.
enum LegacyMigration {
    private static let legacyName = "Ablage"
    private static let legacyBundleID = "de.patrickklein.Ablage"
    private static let doneKey = "migratedFromAblage"

    private static let settingKeys = [
        "documentSort", "showInspector", AutoClassifier.autoCreateCorrespondentsKey,
        MistralConfig.useOCRKey, MistralConfig.useLLMKey, MistralConfig.ocrModelKey, MistralConfig.chatModelKey,
    ]

    static func run(newStoreName: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        migrateStore(to: newStoreName)
        migrateSettings()
        migrateAPIKey()
        defaults.set(true, forKey: doneKey)
    }

    /// Kopiert `Ablage.store` (+ WAL/SHM und den Ordner mit den PDFs) auf den neuen Namen.
    private static func migrateStore(to newName: String) {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
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
            // Halbe Kopie wieder entfernen, damit beim nächsten Start ein sauberer Versuch möglich ist
            for (_, new) in pairs { try? fm.removeItem(at: dir.appending(path: new)) }
            print("Übernahme der alten Datenbank fehlgeschlagen: \(error)")
        }
    }

    private static func migrateSettings() {
        guard let old = UserDefaults(suiteName: legacyBundleID) else { return }
        for key in settingKeys {
            if UserDefaults.standard.object(forKey: key) == nil, let value = old.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    private static func migrateAPIKey() {
        guard KeychainStore.read(MistralConfig.apiKeyAccount) == nil,
              let key = KeychainStore.read(MistralConfig.apiKeyAccount, service: legacyBundleID) else { return }
        KeychainStore.save(key, for: MistralConfig.apiKeyAccount)
    }
}
