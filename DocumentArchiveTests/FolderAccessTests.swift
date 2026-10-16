import Foundation
import Testing
@testable import DocumentArchive

/// The bookmark of a chosen folder (`FolderAccess`), with temporary folders and settings only.
@Suite struct FolderAccessTests {
    private func makeAccess() -> (FolderAccess, String) {
        let (defaults, name) = TestSupport.makeDefaults()
        return (FolderAccess(defaults: defaults, key: "folder"), name)
    }

    private func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @Test func storesAndResolvesAFolder() throws {
        let (access, defaultsName) = makeAccess()
        defer { TestSupport.removeDefaults(defaultsName) }
        let folder = try TestSupport.makeTemporaryDirectory()
        #expect(!access.hasFolder)

        try access.save(folder)

        #expect(access.hasFolder)
        let resolved = try access.resolve()
        #expect(path(resolved.url) == path(folder))
        #expect(!resolved.wasRefreshed)
    }

    @Test func movedFolderResolvesToItsNewPlace() throws {
        let (access, defaultsName) = makeAccess()
        defer { TestSupport.removeDefaults(defaultsName) }
        let parent = try TestSupport.makeTemporaryDirectory()
        let original = parent.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try access.save(original)

        let moved = parent.appending(path: "Renamed Archive", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: original, to: moved)
        let first = try access.resolve()
        #expect(path(first.url) == path(moved))

        // A stale bookmark was stored again, so the next resolution is current.
        let second = try access.resolve()
        #expect(path(second.url) == path(moved))
        #expect(!second.wasRefreshed)
    }

    @Test func deletedFolderGivesAClearError() throws {
        let (access, defaultsName) = makeAccess()
        defer { TestSupport.removeDefaults(defaultsName) }
        let folder = try TestSupport.makeTemporaryDirectory()
        try access.save(folder)
        try FileManager.default.removeItem(at: folder)

        #expect {
            try access.resolve()
        } throws: { error in
            guard case .unavailable = error as? FolderAccess.AccessError else { return false }
            return (error as? LocalizedError)?.errorDescription?.isEmpty == false
        }
    }

    @Test func withoutAFolderThereIsNothingToResolve() throws {
        let (access, defaultsName) = makeAccess()
        defer { TestSupport.removeDefaults(defaultsName) }
        #expect(throws: FolderAccess.AccessError.noFolder) { try access.resolve() }

        try access.save(try TestSupport.makeTemporaryDirectory())
        access.clear()
        #expect(!access.hasFolder)
        #expect(throws: FolderAccess.AccessError.noFolder) { try access.resolve() }
    }

    /// iOS "Show in Files" opens the archive folder through `shareddocuments://`.
    @Test func filesAppURLKeepsThePathEncoded() {
        let folder = URL(filePath: "/private/var/mobile/Documents/Document Archive/", directoryHint: .isDirectory)
        #expect(RevealFolderButton.filesAppURL(for: folder)?.absoluteString
                == "shareddocuments:///private/var/mobile/Documents/Document%20Archive/")
    }
}
