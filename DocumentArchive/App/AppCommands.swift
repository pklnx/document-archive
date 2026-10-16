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

/// Actions on the one open document (#19), set by `ContentView` from the selection: `nil` when
/// no document or several are selected, so ⌘P never prints a document that is not in front.
struct DocumentActions {
    /// `nil` while the document has no PDF (still downloading).
    var print: (() -> Void)?
}

extension FocusedValues {
    @Entry var documentActions: DocumentActions?
}

/// Document items of the menu bar (#19): File → Print… (⌘P) instead of the system's default
/// item. Works with the list focused, too, and on iPadOS with a hardware keyboard (also listed in
/// the ⌘-hold overlay). #9 adds ⌘F / ⌘G here.
struct DocumentCommands: Commands {
    @FocusedValue(\.documentActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Print…") { actions?.print?() }
                .keyboardShortcut("p")
                .disabled(actions?.print == nil)
        }
    }
}
