import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A PDF or image dropped onto the app.
///
/// On iPadOS, files dropped from Files or Photos arrive as file representations, not as file
/// URLs, and the system removes the received file once the drop handler returns. The file is
/// therefore copied into a temporary folder; `DocumentImporter.importDropped` removes the copy.
/// On macOS, Finder drops arrive the same way.
struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .pdf) { try ImportedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try ImportedFile(copying: $0.file) }
    }

    static let temporaryFolder = FileManager.default.temporaryDirectory.appending(path: "DroppedFiles")

    /// Copies `file` into its own temporary folder, keeping the file name (it becomes the title).
    init(copying file: URL) throws {
        let accessing = file.startAccessingSecurityScopedResource()
        defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        let folder = Self.temporaryFolder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        url = copy
    }

    /// Removes the temporary copy.
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

extension DocumentImporter {
    /// Imports dropped files like files picked in the file dialog and removes the temporary copies.
    @discardableResult
    static func importDropped(_ files: [ImportedFile], into context: ModelContext) -> ImportResult {
        defer { files.forEach { $0.remove() } }
        return importFiles(files.map(\.url), into: context)
    }
}
