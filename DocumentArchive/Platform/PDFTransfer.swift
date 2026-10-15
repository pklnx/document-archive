import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A PDF for sharing (ShareLink) or dragging out of the app.
struct PDFTransfer: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName { $0.fileName }
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

extension Document {
    var transfer: PDFTransfer? {
        pdfData.map { PDFTransfer(data: $0, fileName: exportFileName) }
    }
}
