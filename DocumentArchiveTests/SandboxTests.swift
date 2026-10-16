import Foundation
import Testing
@testable import DocumentArchive

/// What the macOS App Sandbox means for the app (#42). These tests only run in the sandboxed
/// nightly job `test (macOS, sandboxed)`: an ad-hoc signed build with
/// `Config/DocumentArchive-macOS-SandboxTests.entitlements` and its own bundle identifier
/// (`DA_BUNDLE_ID_SUFFIX=.SandboxTests`), so it never touches the real app's container. The
/// required runs are unsigned and therefore unsandboxed, and skip them.
///
/// The job sets `DA_EXPECT_SANDBOX=1`; then the suite runs even when the process is not
/// sandboxed and fails, so a broken signing setup cannot skip the suite silently.
@Suite(.enabled(if: SandboxRun.isSandboxed || SandboxRun.isExpected))
struct SandboxTests {
    @Test func processIsSandboxed() {
        #expect(SandboxRun.isSandboxed, "APP_SANDBOX_CONTAINER_ID is not set: the test host is not sandboxed")
        let support = URL.applicationSupportDirectory.standardizedFileURL.path(percentEncoded: false)
        #expect(support.contains("/Library/Containers/"), "Application Support is \(support)")
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
}

/// How the test host was started; outside the suite, which cannot refer to itself in its traits.
enum SandboxRun {
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    static let isExpected = ProcessInfo.processInfo.environment["DA_EXPECT_SANDBOX"] == "1"
}
