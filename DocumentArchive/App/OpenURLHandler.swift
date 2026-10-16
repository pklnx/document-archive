import Foundation

/// The app's single handler for URLs it is asked to open (`.onOpenURL` on `ContentView`).
/// File URLs ("Open with", the Dock icon, "Open in…" on iPhone and iPad) go to `ExternalImport`.
/// #15 adds its `documentarchive://` branch here; there is no second `.onOpenURL`.
@MainActor
enum OpenURLHandler {
    /// - Returns: Whether the URL was handled.
    @discardableResult
    static func handle(_ url: URL, externalImport: ExternalImport = .shared) -> Bool {
        if url.isFileURL {
            externalImport.receive([url], origin: .openWith)
            return true
        }
        return false
    }
}
