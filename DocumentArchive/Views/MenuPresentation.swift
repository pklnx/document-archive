import SwiftUI

/// Presents a confirmation (or anything else that anchors to the screen) that a menu item asked
/// for, but only once the menu has closed.
///
/// On iPadOS 26 a confirmation dialog presented while the menu that triggered it was still
/// closing sometimes never appeared: the dialog's popover tried to anchor to the toolbar button
/// of the closing menu, the toolbar stayed blurred and nothing else happened (More → Delete in
/// the document with the inspector column open). Waiting for the menu to close avoids the race.
/// macOS menus have closed when their action runs, so it presents at once there.
enum MenuPresentation {
    /// Long enough for iOS to finish closing a menu or a context menu.
    static let menuClosingTime: Duration = .milliseconds(450)

    /// Runs `present` after the menu that triggered it has closed.
    @MainActor
    static func afterMenuCloses(_ present: @escaping @MainActor () -> Void) {
        #if os(iOS)
        Task { @MainActor in
            try? await Task.sleep(for: menuClosingTime)
            present()
        }
        #else
        present()
        #endif
    }
}
