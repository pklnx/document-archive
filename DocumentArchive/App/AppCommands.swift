import SwiftUI

/// Actions of the current window, so the menu bar (macOS, iPadOS) and keyboard shortcuts can
/// trigger them.
struct AppActions {
    var importFiles: () -> Void
    var newTag: () -> Void
    var newCorrespondent: () -> Void
    var newDocumentType: () -> Void
    /// Saved views (#14): "Save as View…" for the list in front (⌥⌘S).
    var saveAsView: () -> Void
    /// Opens the settings sheet. On macOS, settings have their own window.
    var showSettings: () -> Void
}

extension FocusedValues {
    @Entry var appActions: AppActions?
}

/// Menu bar items: on macOS in the menu bar, on iPadOS in the menu bar (iPadOS 26) or in the
/// overlay shown while holding ⌘ (iPadOS 18). Later features add their items here.
struct AppCommands: Commands {
    @FocusedValue(\.appActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Documents…") { actions?.importFiles() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Divider()
            Button("New Tag…") { actions?.newTag() }
                .disabled(actions == nil)
            Button("New Correspondent…") { actions?.newCorrespondent() }
                .disabled(actions == nil)
            Button("New Document Type…") { actions?.newDocumentType() }
                .disabled(actions == nil)
            Divider()
            Button("Save as View…") { actions?.saveAsView() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        #if os(iOS)
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.showSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
        }
        #endif
    }
}
