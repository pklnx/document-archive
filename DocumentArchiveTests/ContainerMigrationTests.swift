import Foundation
import Testing
@testable import DocumentArchive

/// The container migration manifest (#42): on the first launch of a sandboxed Mac build, macOS
/// moves the archive from `~/Library` into the new container. The move itself can only be checked
/// by hand on a signed build (docs/development/index.md, "Sandbox"); these tests check the file.
@Suite @MainActor struct ContainerMigrationTests {
    /// The real app's identifier, also for a test build with `DA_BUNDLE_ID_SUFFIX`: the manifest
    /// names the real app's preferences.
    static let bundleID = "de.patrickklein.DocumentArchive"

    private var manifestURL: URL? {
        Bundle.main.url(forResource: "container-migration", withExtension: "plist")
    }

    #if os(macOS)
    private func movedItems() throws -> [String] {
        let url = try #require(manifestURL, "container-migration.plist is missing from the Mac app")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Resources")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try #require(plist as? [String: Any])
        #expect(Set(manifest.keys) == ["Move"], "moves only; nothing is copied or linked")
        return try #require(manifest["Move"] as? [String])
    }

    @Test func movesTheStoreTheFolderCopyStateAndTheSettings() throws {
        let store = ArchiveStore.storeName
        let fallback = "\(store)-lokal"
        var expected: [String] = []
        for name in [store, fallback] {
            expected += ["\(name).store", "\(name).store-wal", "\(name).store-shm", ".\(name)_SUPPORT"]
                .map { "${ApplicationSupport}/\($0)" }
        }
        expected.append("${ApplicationSupport}/\(ArchiveMirrorStateStore.fileName)")
        expected.append("${Library}/Preferences/\(Self.bundleID).plist")

        #expect(try movedItems() == expected)
        #expect(Bundle.main.bundleIdentifier?.hasPrefix(Self.bundleID) == true)
    }

    /// `LegacyMigration` left the old files in place as a backup; they stay outside.
    @Test func leavesTheLegacyFilesInPlace() throws {
        #expect(try movedItems().allSatisfy { !$0.contains(LegacyMigration.legacyName) })
    }

    /// Only Apple's variables; there is no `${Preferences}`.
    @Test func usesOnlyApplesVariables() throws {
        let allowed: Set = ["ApplicationSupport", "AutosavedInformation", "Caches", "Documents", "Home",
                            "Library", "BundleId"]
        let pattern = #/\$\{([A-Za-z]+)\}/#
        for item in try movedItems() {
            let variables = item.matches(of: pattern).map { String($0.output.1) }
            #expect(variables.count == 1 && item.hasPrefix("${"), "\(item) starts with one variable")
            #expect(variables.allSatisfy(allowed.contains), "\(item)")
        }
    }
    #else
    /// iPhone and iPad apps were always sandboxed; the project filters the manifest out.
    @Test func isNotInTheIOSApp() {
        #expect(manifestURL == nil)
    }
    #endif
}
