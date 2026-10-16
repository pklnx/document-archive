import Foundation

/// Remembers a folder the user chose (archive folder copy #8, watch folder #12) across launches,
/// through a bookmark in `UserDefaults`. A bookmark is not a secret: it only works for this app
/// on this device.
///
/// Platform differences:
/// - **macOS** (sandbox): a security-scoped bookmark (`.withSecurityScope`); access must be
///   started before every use (`withAccess`).
/// - **iOS/iPadOS**: a plain bookmark of the URL from the document picker; the scope is implicit,
///   but `startAccessingSecurityScopedResource` is still needed while using it.
struct FolderAccess {
    enum AccessError: LocalizedError, Equatable {
        /// No folder was chosen.
        case noFolder
        /// The folder was deleted, is on a drive that is not connected, or the bookmark no
        /// longer resolves.
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .noFolder: String(localized: "No folder has been chosen.")
            case .unavailable(let name): String(localized: "The folder “\(name)” is not available. It may have been deleted, or it is on a drive that is not connected.")
            }
        }
    }

    /// A resolved bookmark.
    struct Resolved: Equatable {
        var url: URL
        /// The bookmark was stale (folder moved or renamed) and has been stored again.
        var wasRefreshed: Bool
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    var hasFolder: Bool { defaults.data(forKey: key) != nil }

    /// Stores a bookmark for `url`. On iOS, `url` comes from `fileImporter` and must be accessed
    /// while the bookmark is created; `withAccess` does that.
    func save(_ url: URL) throws {
        let data = try Self.withAccess(to: url) {
            try url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(data, forKey: key)
    }

    /// Resolves the stored bookmark. A moved or renamed folder resolves to its new place, and the
    /// stale bookmark is replaced.
    func resolve() throws -> Resolved {
        guard let data = defaults.data(forKey: key) else { throw AccessError.noFolder }
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: Self.resolutionOptions, relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        } catch {
            throw AccessError.unavailable(Self.lastKnownName(of: data))
        }
        let exists = Self.withAccess(to: url) { () -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        // A folder moved to the Trash still resolves, but it is gone for the user.
        guard exists, !url.pathComponents.contains(".Trash") else {
            throw AccessError.unavailable(url.lastPathComponent)
        }
        if isStale { try? save(url) }
        return Resolved(url: url, wasRefreshed: isStale)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Runs `body` while the app may use `url` (security scope). Harmless for URLs that need none.
    static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }

    /// The folder name stored in the bookmark, for the error message when it cannot be resolved.
    private static func lastKnownName(of data: Data) -> String {
        let values = URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: data)
        return values?.name ?? String(localized: "Folder")
    }

    #if os(macOS)
    static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    static let creationOptions: URL.BookmarkCreationOptions = []
    static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
