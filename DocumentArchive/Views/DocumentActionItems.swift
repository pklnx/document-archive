import SwiftUI

/// "Print…", "Copy PDF" and "Copy Text" for one document (#19), in the detail view's "More"
/// menu and the list's single-document context menu. No ⌘C: the shortcut stays with text
/// selections (maintainer decision); ⌘P comes from `DocumentCommands`.
struct DocumentActionItems: View {
    let document: Document

    var body: some View {
        Button("Print…", systemImage: "printer") { DocumentActionRunner.print(document) }
            .disabled(document.pdfData == nil)
            .accessibilityIdentifier(AccessibilityID.documentPrint)
        Button("Copy PDF", systemImage: "doc.on.doc") { DocumentActionRunner.copy(document, kind: .pdf) }
            .disabled(!ClipboardContent.canCopy(document, kind: .pdf))
            .accessibilityIdentifier(AccessibilityID.documentCopyPDF)
        Button("Copy Text", systemImage: "text.quote") { DocumentActionRunner.copy(document, kind: .text) }
            .disabled(!ClipboardContent.canCopy(document, kind: .text))
            .accessibilityIdentifier(AccessibilityID.documentCopyText)
    }
}

/// Runs the document actions for menus and `DocumentCommands`.
@MainActor enum DocumentActionRunner {
    static func print(_ document: Document) {
        guard let job = PrintJob(document: document) else { return }
        // After the menu has closed: iOS presents the AirPrint sheet over the key window.
        Task { @MainActor in DocumentPrinter.print(job) }
    }

    static func copy(_ document: Document, kind: ClipboardContent.Kind) {
        Clipboard.copy(ClipboardContent.items(for: document, kind: kind))
    }

    /// The menu bar's actions for the document in front; `nil` for none.
    static func actions(for document: Document?) -> DocumentActions? {
        guard let document, document.isAlive else { return nil }
        return DocumentActions(print: document.pdfData == nil ? nil : { Self.print(document) })
    }
}
