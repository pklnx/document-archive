import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A PDF for sharing (ShareLink) or dragging out of the app.
///
/// The file representation comes first: it writes `<fileName>` into `ExportFolder`, so Mail,
/// AirDrop and "Save to Files" receive the chosen name even where they ignore a data
/// representation's suggested name (#19). The bytes are loaded only when a receiver asks for
/// them, so building transfers for a list row or for several documents (#10) reads no PDF.
struct PDFTransfer: Transferable {
    enum TransferError: Error {
        /// The document has no PDF (still downloading from iCloud) or was deleted.
        case noData
    }

    /// The file name with ".pdf" (`FileNaming.sanitized`).
    let fileName: String
    /// Runs on the main actor, where the document lives; `@Sendable` because `Transferable`
    /// values are `Sendable`.
    private let load: @MainActor @Sendable () -> Data?
    private let folder: ExportFolder

    init(fileName: String, folder: ExportFolder = .shared, load: @escaping @MainActor @Sendable () -> Data?) {
        self.fileName = FileNaming.sanitized(fileName)
        self.folder = folder
        self.load = load
    }

    init(data: Data, fileName: String, folder: ExportFolder = .shared) {
        self.init(fileName: fileName, folder: folder) { data }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { transfer in
            SentTransferredFile(try await transfer.writeFile())
        }
        .suggestedFileName { $0.fileName }
        DataRepresentation(exportedContentType: .pdf) { try await $0.data() }
            .suggestedFileName { $0.fileName }
    }

    /// The PDF's bytes, read now.
    func data() async throws -> Data {
        guard let data = await load() else { throw TransferError.noData }
        return data
    }

    /// Writes the PDF as `<folder>/<random>/<fileName>`; what the file representation sends.
    func writeFile() async throws -> URL {
        try folder.write(try await data(), named: fileName)
    }
}

/// For exporting through the file dialog (`fileExporter`).
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// On the main actor: the transfer's loader captures the document, a SwiftData model, which stays
/// on the main actor (see docs/development/index.md → Concurrency).
@MainActor
extension Document {
    /// For a document with a PDF; `nil` while it is still downloading.
    var transfer: PDFTransfer? {
        pdfData == nil ? nil : transfer(named: exportFileName)
    }

    /// The document's PDF under `fileName` ("Share as…"), read when a receiver asks for it. A
    /// deleted document sends nothing.
    func transfer(named fileName: String) -> PDFTransfer {
        PDFTransfer(fileName: fileName) { [self] in isAlive ? pdfData : nil }
    }
}
