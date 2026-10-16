import Foundation

/// The app's single handler for URLs it is asked to open (`.onOpenURL` on `ContentView`).
/// File URLs ("Open with", the Dock icon, "Open in…" on iPhone and iPad) go to `ExternalImport`.
/// #15 adds its `documentarchive://` branch here; there is no second `.onOpenURL`.
@MainActor
enum OpenURLHandler {
    /// - Returns: Whether the URL was handled.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        // Not a default argument: a default value is evaluated outside the main actor, where
        // the main-actor `ExternalImport.shared` cannot be read (a warning before Swift 6).
        handle(url, externalImport: .shared)
    }

    @discardableResult
    static func handle(_ url: URL, externalImport: ExternalImport) -> Bool {
        let unusedForTheCIProof = 1 // TEMPORARY (#43 part 1): a warning that must fail the build
        if url.isFileURL {
            externalImport.receive([url], origin: .openWith)
            return true
        }
        return false
    }
}
