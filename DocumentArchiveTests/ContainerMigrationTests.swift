import Foundation
import Testing
@testable import DocumentArchive

/// The container migration manifest (#42): on the first launch of a sandboxed Mac build, macOS
/// moves the archive from `~/Library` into the new container. The move itself can only be checked
/// by hand on a signed build (docs/development/index.md, "Sandbox"); these tests check the file,
/// and that it ships in the real app only. Its paths are relative to the home folder, so a
/// sandboxed test build (`DA_BUNDLE_ID_SUFFIX`) that carried it would move the real archive into
/// the test container. The list is read from the source file, so it is also checked in the
/// sandboxed run, whose app has no manifest.
@Suite @MainActor struct ContainerMigrationTests {
    /// The real app's identifier, also for a test build with `DA_BUNDLE_ID_SUFFIX`: the manifest
    /// names the real app's preferences.
    nonisolated static let bundleID = "de.patrickklein.DocumentArchive"

    private var manifestURL: URL? {
        Bundle.main.url(forResource: "container-migration", withExtension: "plist")
    }

    #if os(macOS)
    private static let sourceURL = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "DocumentArchive/container-migration.plist")

    /// The real app (unsigned `test (macOS)` run) ships the manifest, unchanged.
    @Test(.enabled(if: AppBuild.isRealApp)) func realAppContainsTheManifest() throws {
        let url = try #require(manifestURL, "container-migration.plist is missing from the Mac app")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Resources")
        let shipped = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let source = try PropertyListSerialization.propertyList(from: Data(contentsOf: Self.sourceURL), format: nil)
        #expect((shipped as? NSDictionary) == (source as? NSDictionary))
    }

    /// A build with a bundle identifier suffix (the sandboxed test builds) never ships it.
    @Test(.enabled(if: !AppBuild.isRealApp)) func testBuildHasNoManifest() {
        #expect(Bundle.main.bundleIdentifier?.hasPrefix(Self.bundleID + ".") == true)
        #expect(manifestURL == nil, "a test build with the manifest moves the real archive on its first launch")
    }

    private func movedItems() throws -> [String] {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: Self.sourceURL), format: nil)
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

/// Which app hosts the tests; outside the suite, whose traits cannot use its own members.
enum AppBuild {
    static let isRealApp = Bundle.main.bundleIdentifier == ContainerMigrationTests.bundleID
}
