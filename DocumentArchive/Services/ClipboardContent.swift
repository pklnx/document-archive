import Foundation

/// What "Copy PDF" and "Copy Text" put on the pasteboard (#19), decided without touching it.
/// `Clipboard` writes the items.
enum ClipboardContent {
    enum Kind {
        case pdf, text
    }

    enum Item: Equatable {
        /// The PDF's bytes and the name of the file it becomes when pasted (Finder, Mail, Files).
        case pdf(Data, fileName: String)
        case text(String)
    }

    /// The items for a copy of `document`; empty when there is nothing to copy (no PDF yet, no
    /// recognized text, a deleted document). The vault (#22) adds its exclusion here.
    @MainActor static func items(for document: Document, kind: Kind) -> [Item] {
        guard document.isAlive else { return [] }
        switch kind {
        case .pdf:
            guard let data = document.pdfData, !data.isEmpty else { return [] }
            return [.pdf(data, fileName: document.exportFileName)]
        case .text:
            let text = plainText(of: document)
            return text.isEmpty ? [] : [.text(text)]
        }
    }

    /// Whether the menu item is enabled; the same decision as `items`, without reading the PDF.
    @MainActor static func canCopy(_ document: Document, kind: Kind) -> Bool {
        guard document.isAlive else { return false }
        switch kind {
        case .pdf: return document.pdfData != nil
        case .text: return !document.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The recognized text as plain text: Mistral's OCR result is Markdown (headings, tables),
    /// converted by `MarkdownNotes.plainText`; text from the PDF or Apple Vision is plain already.
    static func plainText(of document: Document) -> String {
        let text = document.extractedText
        let plain = document.textSource == DocumentProcessor.mistralTextSource ? MarkdownNotes.plainText(from: text) : text
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
