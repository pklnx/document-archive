import Foundation
import Testing
@testable import DocumentArchive

@Suite struct LegacyMigrationTests {
    private func makeLegacyStore(in dir: URL) throws {
        try Data("store".utf8).write(to: dir.appending(path: "Ablage.store"))
        try Data("wal".utf8).write(to: dir.appending(path: "Ablage.store-wal"))
        let external = dir.appending(path: ".Ablage_SUPPORT/_EXTERNAL_DATA")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: external.appending(path: "ABC"))
    }

    @Test func copiesStoreAndSettingsOnce() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeLegacyStore(in: dir)
        let (defaults, defaultsName) = TestSupport.makeDefaults()
        let (legacy, legacyName) = TestSupport.makeDefaults()
        defer { TestSupport.removeDefaults(defaultsName); TestSupport.removeDefaults(legacyName) }
        legacy.set("title", forKey: "documentSort")
        legacy.set(false, forKey: MistralConfig.useOCRKey)
        legacy.set("unrelated", forKey: "somethingElse")

        LegacyMigration.run(newStoreName: "DocumentArchive", directory: dir, defaults: defaults,
                            legacyDefaults: legacy, migrateAPIKey: false)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appending(path: "DocumentArchive.store").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "DocumentArchive.store-wal").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "DocumentArchive.store-shm").path))
        #expect(try Data(contentsOf: dir.appending(path: ".DocumentArchive_SUPPORT/_EXTERNAL_DATA/ABC")) == Data("pdf".utf8))
        #expect(fm.fileExists(atPath: dir.appending(path: "Ablage.store").path), "the old store stays as a backup")
        #expect(defaults.string(forKey: "documentSort") == "title")
        #expect(defaults.object(forKey: MistralConfig.useOCRKey) as? Bool == false)
        #expect(defaults.object(forKey: "somethingElse") == nil)
        #expect(defaults.bool(forKey: LegacyMigration.doneKey))

        // A second run changes nothing, even if the old store changed meanwhile
        try Data("changed".utf8).write(to: dir.appending(path: "Ablage.store"))
        LegacyMigration.run(newStoreName: "DocumentArchive", directory: dir, defaults: defaults,
                            legacyDefaults: legacy, migrateAPIKey: false)
        #expect(try Data(contentsOf: dir.appending(path: "DocumentArchive.store")) == Data("store".utf8))
    }

    @Test func keepsAnExistingNewStoreAndExistingSettings() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeLegacyStore(in: dir)
        try Data("new".utf8).write(to: dir.appending(path: "DocumentArchive.store"))
        let (defaults, defaultsName) = TestSupport.makeDefaults()
        let (legacy, legacyName) = TestSupport.makeDefaults()
        defer { TestSupport.removeDefaults(defaultsName); TestSupport.removeDefaults(legacyName) }
        defaults.set("added", forKey: "documentSort")
        legacy.set("title", forKey: "documentSort")

        LegacyMigration.run(newStoreName: "DocumentArchive", directory: dir, defaults: defaults,
                            legacyDefaults: legacy, migrateAPIKey: false)

        #expect(try Data(contentsOf: dir.appending(path: "DocumentArchive.store")) == Data("new".utf8))
        #expect(defaults.string(forKey: "documentSort") == "added")
    }

    @Test func doesNothingWithoutLegacyData() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (defaults, defaultsName) = TestSupport.makeDefaults()
        defer { TestSupport.removeDefaults(defaultsName) }

        LegacyMigration.run(newStoreName: "DocumentArchive", directory: dir, defaults: defaults,
                            legacyDefaults: nil, migrateAPIKey: false)

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(defaults.bool(forKey: LegacyMigration.doneKey))
    }
}
