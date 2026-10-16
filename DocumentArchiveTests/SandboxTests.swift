import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// What the macOS App Sandbox means for the app (#42). These tests only run in the sandboxed
/// nightly job `test (macOS, sandboxed)`: an ad-hoc signed build with
/// `Config/DocumentArchive-macOS-SandboxTests.entitlements` and its own bundle identifier
/// (`DA_BUNDLE_ID_SUFFIX=.SandboxTests`), so it never touches the real app's container. The
/// required runs are unsigned and therefore unsandboxed, and skip them. Every file they write is
/// in a temporary folder inside the test build's own container.
///
/// The job sets `DA_EXPECT_SANDBOX=1`; then the suite runs even when the process is not
/// sandboxed and fails, so a broken signing setup cannot skip the suite silently.
@Suite(.enabled(if: SandboxRun.isSandboxed || SandboxRun.isExpected))
@MainActor struct SandboxTests {
    @Test func processIsSandboxed() {
        #expect(SandboxRun.isSandboxed, "APP_SANDBOX_CONTAINER_ID is not set: the test host is not sandboxed")
        #expect(AppSandbox.isActive)
        let support = URL.applicationSupportDirectory.standardizedFileURL.path(percentEncoded: false)
        #expect(support.contains("/Library/Containers/"), "Application Support is \(support)")
    }

    /// The sandboxed test build must not carry the container migration manifest: on its first
    /// launch it would move the real archive into the test container (#61 review). CI checks the
    /// built app before launching it (scripts/check-container-migration.py); this is the last line.
    @Test func testBuildHasItsOwnIdentifierAndNoMigrationManifest() {
        #expect(Bundle.main.bundleIdentifier != ContainerMigrationTests.bundleID)
        #expect(Bundle.main.url(forResource: "container-migration", withExtension: "plist") == nil)
    }

    /// Writing outside the container fails, which proves the sandbox is active. (Reading does not
    /// prove it here: Xcode gives every test host read-only access to the whole disk.)
    @Test func writingOutsideTheContainerFails() throws {
        let home = try #require(SandboxRun.realHomeDirectory)
        #expect(URL.homeDirectory.standardizedFileURL != home.standardizedFileURL, "the home folder is the container's")
        let probe = home.appending(path: "Library/Preferences/DocumentArchive-SandboxProbe-\(UUID().uuidString).txt")
        var written = false
        #expect(throws: (any Error).self) {
            try Data("probe".utf8).write(to: probe)
            written = true
        }
        if written { try? FileManager.default.removeItem(at: probe) }
    }

    /// Security-scoped bookmarks under an ad-hoc signature: the folder copy (#8) and the watch
    /// folder (#12) keep the user's folder this way.
    @Test func folderBookmarkRoundTripAllowsWriting() throws {
        let (defaults, defaultsName) = TestSupport.makeDefaults()
        defer { TestSupport.removeDefaults(defaultsName) }
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let access = FolderAccess(defaults: defaults, key: "folder")

        try access.save(folder)
        let resolved = try access.resolve()

        let file = resolved.url.appending(path: "written.txt")
        try FolderAccess.withAccess(to: resolved.url) {
            try Data("sandbox".utf8).write(to: file)
        }
        #expect(try Data(contentsOf: folder.appending(path: "written.txt")) == Data("sandbox".utf8))
    }

    /// One folder copy pass into a folder resolved from its bookmark, the way
    /// `ArchiveMirrorController` runs it.
    @Test func folderCopyPassWritesTheArchive() async throws {
        let (defaults, defaultsName) = TestSupport.makeDefaults()
        defer { TestSupport.removeDefaults(defaultsName) }
        let chosen = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: chosen) }
        let access = FolderAccess(defaults: defaults, key: "folder")
        try access.save(chosen)
        let folder = try access.resolve().url

        let device = try MirrorFixture(folder: folder)
        let document = device.insertDocument("Bill", pdf: TestSupport.samplePDF(lines: ["Bill"]))
        try device.context.save()
        let result = try await FolderAccess.withAccess(to: folder) {
            try await device.run()
        }

        #expect(result.documentsWritten == 1)
        #expect(result.pdfsWritten == 1)
        #expect(try Data(contentsOf: device.layout.pdf(document.id)) == document.pdfData)
        #expect(FileManager.default.fileExists(atPath: device.layout.record(.document, document.id).path))
        #expect(FileManager.default.fileExists(atPath: device.layout.archiveInfo.path))
    }

    /// Drag and drop: the dropped file is copied into `DroppedFiles` (inside the container) and
    /// imported from there.
    @Test func droppedFileIsCopiedAndImported() async throws {
        let container = try TestSupport.makeContainer()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "Rechnung.pdf")
        try TestSupport.samplePDF(lines: ["Rechnung"]).write(to: original)

        let file = try ImportedFile(copying: original)
        #expect(file.url.standardizedFileURL.path().hasPrefix(ImportedFile.temporaryFolder.standardizedFileURL.path()))
        #expect(ImportedFile.temporaryFolder.path(percentEncoded: false).contains("/Library/Containers/"))

        let result = await DocumentImporter.importDropped([file], into: container.mainContext)
        try await TestSupport.waitUntilProcessed(result.imported)

        #expect(result.errors.isEmpty)
        #expect(result.imported.map(\.title) == ["Rechnung"])
        #expect(!FileManager.default.fileExists(atPath: file.url.path), "the copy is removed")
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    /// "Open with": a file handed to `ExternalImport` is imported and left where it is.
    @Test func openedFileIsImportedAndLeftInPlace() async throws {
        let container = try TestSupport.makeContainer()
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Vertrag.pdf")
        try TestSupport.samplePDF(lines: ["Vertrag"]).write(to: file)
        let externalImport = ExternalImport(inboxFolder: directory.appending(path: "Documents/Inbox"))
        externalImport.context = container.mainContext

        externalImport.receive([file], origin: .openWith)
        let result = try #require(await externalImport.importedResult())
        try await TestSupport.waitUntilProcessed(result.imported)

        #expect(result.imported.map(\.title) == ["Vertrag"])
        #expect(FileManager.default.fileExists(atPath: file.path), "the opened file stays in place")
    }

    /// The ad-hoc signed sandboxed build may not use the data protection keychain; `KeychainStore`
    /// falls back to the file keychain. Uses the tests' own service name, never the real key.
    @Test func keychainRoundTripWithTheTestService() {
        let service = KeychainStoreTests.service
        let account = "sandbox-test-account"
        KeychainStore.delete(account, service: service)
        defer { KeychainStore.delete(account, service: service) }
        let secret = TestSupport.fakeKey()

        KeychainStore.save(secret, for: account, service: service)
        #expect(KeychainStore.read(account, service: service) == secret)

        KeychainStore.delete(account, service: service)
        #expect(KeychainStore.read(account, service: service) == nil)
    }
}

/// How the test host was started; outside the suite, which cannot refer to itself in its traits.
enum SandboxRun {
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    static let isExpected = ProcessInfo.processInfo.environment["DA_EXPECT_SANDBOX"] == "1"

    /// The user's real home folder; in the sandbox, `URL.homeDirectory` is the container.
    static var realHomeDirectory: URL? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
    }
}
