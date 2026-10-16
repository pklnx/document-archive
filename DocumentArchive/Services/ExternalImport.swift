import Foundation
import Observation
import SwiftData

/// The one entry point for files that arrive from outside the app: "Open with" in Finder, a drop
/// on the Dock icon, `open -a`, and "Open in…" / "Copy to Document Archive" from Files, Mail and
/// other apps on iPhone and iPad. Everything goes through `DocumentImporter`, so these files get
/// the same duplicate detection and processing as a normal import.
///
/// The watch folder (#12 part 2) and the share extension's queue (#12 part 3) add their origins here.
@MainActor @Observable
final class ExternalImport {
    enum Origin {
        /// Opened by the user from another app: imported right away, the result is shown.
        case openWith
    }

    static let shared = ExternalImport()

    /// The archive to import into; set by `ContentView` once a window exists. Files received
    /// before that (opened at launch) wait in `queued` and are imported when it is set.
    var context: ModelContext? {
        didSet { importQueued() }
    }

    /// Files received before `context` was set.
    private(set) var queued: [(url: URL, origin: Origin)] = []

    /// The result of interactive imports that the window has not shown yet; see `takeResult()`.
    private(set) var pendingResult: DocumentImporter.ImportResult?

    /// Where iOS puts copies of files handed over by other apps ("Copy to …", Mail attachments).
    /// The app owns these copies and removes them after the import; files opened in place
    /// (Files) stay where they are. Only used on iOS and iPadOS: the Mac build is not sandboxed,
    /// so there `Documents/Inbox` is a folder of the user's that is never touched.
    let inboxFolder: URL

    init(inboxFolder: URL = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)) {
        self.inboxFolder = inboxFolder
    }

    func receive(_ urls: [URL], origin: Origin) {
        guard !urls.isEmpty else { return }
        guard let context else {
            queued += urls.map { ($0, origin) }
            return
        }
        switch origin {
        case .openWith:
            let result = DocumentImporter.importFiles(urls, into: context)
            #if os(iOS)
            removeInboxCopies(urls)
            #endif
            guard !result.isEmpty else { return }
            if pendingResult == nil {
                pendingResult = result
            } else {
                pendingResult?.merge(result)
            }
        }
    }

    /// Hands the pending result to the window that shows it (notice, opening the document).
    func takeResult() -> DocumentImporter.ImportResult? {
        defer { pendingResult = nil }
        return pendingResult
    }

    private func importQueued() {
        guard context != nil, !queued.isEmpty else { return }
        let waiting = queued
        queued = []
        for (url, origin) in waiting {
            receive([url], origin: origin)
        }
    }

    #if os(iOS)
    private func removeInboxCopies(_ urls: [URL]) {
        let inbox = Self.normalizedPath(inboxFolder)
        for url in urls where url.isFileURL {
            let folder = Self.normalizedPath(url.deletingLastPathComponent())
            guard folder == inbox || folder.hasPrefix(inbox + "/") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The path without symbolic links (`/var` → `/private/var`) and without a trailing slash.
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
    #endif
}
