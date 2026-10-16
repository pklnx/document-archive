import Foundation

/// Temporary copies of PDFs handed to other apps under a chosen name (#19): the share sheet's
/// file representation (`PDFTransfer`) and, on macOS, the file a copied PDF puts on the
/// pasteboard. Each copy gets its own subfolder, so two documents with the same name never
/// overwrite each other. The folder is emptied at launch (all platforms) and when the Mac app
/// quits; the receiving app has its own copy by then.
struct ExportFolder: Sendable {
    let root: URL

    /// The app's folder in the system's temporary directory.
    static let shared = ExportFolder(root: FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory))

    /// Writes `data` as `<root>/<random>/<fileName>` (the name sanitized by `FileNaming`) and
    /// returns the file's URL.
    func write(_ data: Data, named fileName: String) throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: FileNaming.sanitized(fileName), directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes every copy. Errors are ignored: a file still open elsewhere goes next time.
    func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}
