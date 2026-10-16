import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Writes "Copy PDF" / "Copy Text" (#19) to the pasteboard; `ClipboardContent` decides what.
/// The general pasteboard reaches the user's other devices through Universal Clipboard (the
/// system's normal behavior). Tests pass a named pasteboard of their own.
enum Clipboard {
    #if os(macOS)
    /// A PDF goes on the pasteboard as data **and** as the URL of a copy in `ExportFolder` named
    /// like the export: pasting into Mail attaches it, into Finder creates the file.
    static func copy(_ items: [ClipboardContent.Item], to pasteboard: NSPasteboard = .general,
                     folder: ExportFolder = .shared) {
        let pasteboardItems = items.compactMap { item -> NSPasteboardItem? in
            let pasteboardItem = NSPasteboardItem()
            switch item {
            case .pdf(let data, let fileName):
                pasteboardItem.setData(data, forType: .pdf)
                if let url = try? folder.write(data, named: fileName) {
                    pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                }
            case .text(let text):
                pasteboardItem.setString(text, forType: .string)
            }
            return pasteboardItem
        }
        guard !pasteboardItems.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems)
    }
    #else
    /// A PDF goes on the pasteboard through an item provider with the export's name, so Files
    /// and Mail name the pasted file.
    static func copy(_ items: [ClipboardContent.Item], to pasteboard: UIPasteboard = .general) {
        let providers = items.map { item -> NSItemProvider in
            switch item {
            case .pdf(let data, let fileName):
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
                provider.suggestedName = (fileName as NSString).deletingPathExtension
                return provider
            case .text(let text):
                return NSItemProvider(object: text as NSString)
            }
        }
        guard !providers.isEmpty else { return }
        pasteboard.setItemProviders(providers, localOnly: false, expirationDate: nil)
    }
    #endif
}
