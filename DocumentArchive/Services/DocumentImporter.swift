import CoreGraphics
import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Creates new documents and starts the background processing:
/// thumbnail, text recognition and then auto-assignment.
@MainActor
enum DocumentImporter {
    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "“\(name)” could not be read.")
            case .unsupported(let name): String(localized: "“\(name)” is not a PDF or an image.")
            }
        }
    }

    static let importableTypes: [UTType] = [.pdf, .image]

    struct ImportResult {
        var imported: [Document] = []
        /// Files already in the archive (identical content), with the existing document.
        var duplicates: [(fileName: String, existing: Document)] = []
        var errors: [Error] = []
    }

    /// Imports files (PDFs and images). Every file becomes its own document.
    /// Files with the same content as an existing document are skipped.
    @discardableResult
    static func importFiles(_ urls: [URL], into context: ModelContext) -> ImportResult {
        var result = ImportResult()
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let name = url.deletingPathExtension().lastPathComponent
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            do {
                guard type.conforms(to: .pdf) || type.conforms(to: .image) else {
                    throw ImportError.unsupported(url.lastPathComponent)
                }
                let fileData = try Data(contentsOf: url)
                let hash = sha256(fileData)
                if let existing = existingDocument(withHash: hash, in: context) {
                    result.duplicates.append((url.lastPathComponent, existing))
                    continue
                }
                let pdfData: Data
                let source: DocumentSource
                if type.conforms(to: .pdf) {
                    pdfData = fileData
                    source = .file
                } else {
                    guard let data = PDFBuilder.makePDF(fromImageData: [fileData]) else { throw ImportError.unreadable(name) }
                    pdfData = data
                    source = .image
                }
                let document = insert(title: name, pdfData: pdfData, source: source, hash: hash,
                                      originalFileName: url.lastPathComponent, context: context)
                result.imported.append(document)
            } catch let error as ImportError {
                result.errors.append(error)
            } catch {
                result.errors.append(ImportError.unreadable(name))
            }
        }
        return result
    }

    /// Several images (e.g. a camera scan) become one multi-page document.
    @discardableResult
    static func importImages(_ images: [CGImage], source: DocumentSource, into context: ModelContext) -> Document? {
        guard let data = PDFBuilder.makePDF(from: images) else { return nil }
        return insert(title: defaultTitle(for: source), pdfData: data, source: source, hash: sha256(data), context: context)
    }

    /// Several photos from the library become one multi-page document.
    /// - Returns: The new document, or the existing one if exactly these photos were imported before.
    static func importImageData(_ items: [Data], into context: ModelContext) -> (document: Document?, isDuplicate: Bool) {
        let hash = sha256(items.reduce(Data(), +))
        if let existing = existingDocument(withHash: hash, in: context) { return (existing, true) }
        guard let data = PDFBuilder.makePDF(fromImageData: items) else { return (nil, false) }
        return (insert(title: defaultTitle(for: .image), pdfData: data, source: .image, hash: hash, context: context), false)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func existingDocument(withHash hash: String, in context: ModelContext) -> Document? {
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.contentHash == hash },
                                                   sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Adds the fingerprint to documents imported before duplicate detection existed.
    static func backfillHashes(in context: ModelContext) {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.contentHash == "" })
        guard let documents = try? context.fetch(descriptor), !documents.isEmpty else { return }
        for document in documents {
            if let data = document.pdfData { document.contentHash = sha256(data) }
        }
        try? context.save()
    }

    static func defaultTitle(for source: DocumentSource) -> String {
        let date = Date().formatted(date: .numeric, time: .shortened)
        switch source {
        case .scan: return String(localized: "Scan \(date)")
        case .image: return String(localized: "Photo \(date)")
        case .file: return String(localized: "Document \(date)")
        }
    }

    private static func insert(title: String, pdfData: Data, source: DocumentSource, hash: String,
                               originalFileName: String = "", context: ModelContext) -> Document {
        let document = Document(title: title, pdfData: pdfData, source: source, originalFileName: originalFileName)
        document.contentHash = hash
        context.insert(document)
        try? context.save()
        process(document, context: context, classify: true)
        return document
    }

    /// Creates the thumbnail and the full text in the background and saves the result.
    /// Returns at once; `processAndWait` does the work.
    /// - Parameter classify: Assign correspondent, type, tags and date automatically after text recognition.
    static func process(_ document: Document, context: ModelContext, classify: Bool) {
        guard document.pdfData != nil else { return }
        document.isProcessing = true
        Task { await processAndWait(document, context: context, classify: classify) }
    }

    /// Like `process`, but returns only when the document is processed and saved, so several
    /// documents can be processed one after another (bulk "Analyze again").
    static func processAndWait(_ document: Document, context: ModelContext, classify: Bool) async {
        guard document.isAlive, let data = document.pdfData else { return }
        document.isProcessing = true
        let mistral = MistralConfig.current()
        let result = await Task.detached(priority: .utility) {
            await DocumentProcessor.analyze(data, mistral: mistral)
        }.value
        guard document.isAlive else { return }
        document.pageCount = result.pageCount
        document.thumbnailData = result.thumbnail
        document.extractedText = result.text
        document.textSource = result.textSource
        document.processingNote = result.note
        document.fileSize = data.count
        if classify {
            let outcome = await AutoClassifier.classify(document, context: context)
            if let error = outcome.aiError {
                document.processingNote = [document.processingNote, error].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
        guard document.isAlive else { return }
        document.isProcessing = false
        try? context.save()
    }

    /// Resumes interrupted processing (e.g. when the app was quit in the middle).
    static func resumePendingProcessing(in context: ModelContext) {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.isProcessing })
        guard let pending = try? context.fetch(descriptor) else { return }
        for document in pending where document.pdfData != nil {
            process(document, context: context, classify: document.isInbox)
        }
    }
}
