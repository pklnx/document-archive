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

        var isEmpty: Bool { imported.isEmpty && duplicates.isEmpty && errors.isEmpty }

        mutating func add(_ outcome: FileOutcome, fileName: String) {
            switch outcome {
            case .imported(let document): imported.append(document)
            case .duplicate(let existing): duplicates.append((fileName, existing))
            }
        }

        /// Appends another batch, e.g. several files opened one after another.
        mutating func merge(_ other: ImportResult) {
            imported += other.imported
            duplicates += other.duplicates
            errors += other.errors
        }

        /// Tells about skipped duplicates and errors; `nil` when everything was imported.
        /// Every way of importing files uses this wording.
        var notice: ImportNotice? {
            var lines: [String] = []
            if !duplicates.isEmpty {
                lines.append(duplicates.count == 1
                    ? String(localized: "This file is already in the archive and was skipped:")
                    : String(localized: "\(duplicates.count) files are already in the archive and were skipped:"))
                lines += duplicates.map { String(localized: "• \($0.fileName) → “\($0.existing.title)”") }
            }
            lines += errors.map(\.localizedDescription)
            guard !lines.isEmpty else { return nil }
            let title = errors.isEmpty
                ? (imported.isEmpty ? String(localized: "Already in the archive")
                                    : String(localized: "\(imported.count) imported, duplicates skipped"))
                : String(localized: "Import partly failed")
            return ImportNotice(title: title, message: lines.joined(separator: "\n"))
        }

        /// The document to open afterwards: the one new document, or the one existing document
        /// when the only file was a duplicate. `nil` for several documents.
        var documentToOpen: (document: Document, isNew: Bool)? {
            if imported.count == 1, let document = imported.first { return (document, true) }
            if imported.isEmpty, duplicates.count == 1, let existing = duplicates.first?.existing { return (existing, false) }
            return nil
        }
    }

    /// Imports files (PDFs and images). Every file becomes its own document.
    /// Files with the same content as an existing document are skipped.
    @discardableResult
    static func importFiles(_ urls: [URL], into context: ModelContext) -> ImportResult {
        var result = ImportResult()
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                guard isImportable(fileName: url.lastPathComponent) else {
                    throw ImportError.unsupported(url.lastPathComponent)
                }
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw ImportError.unreadable(url.deletingPathExtension().lastPathComponent)
                }
                result.add(try importFile(data: data, name: url.lastPathComponent, into: context),
                           fileName: url.lastPathComponent)
            } catch {
                result.errors.append(error)
            }
        }
        return result
    }

    /// What `importFile` did with one file.
    enum FileOutcome {
        case imported(Document)
        /// The archive already has a document with exactly these bytes.
        case duplicate(of: Document)
    }

    static func isImportable(fileName: String) -> Bool {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }

    /// The one import pipeline for a file whose bytes were already read (possibly off the main
    /// actor): duplicate check on the original bytes, then the insert and the normal processing.
    /// `importFiles` and `ExternalImport` both end here, so the paths cannot drift apart.
    /// #20 adds its cleanup step (and a `cleanup:` mode chosen by the caller) between the
    /// duplicate check and the insert.
    /// - Parameter name: The file name with its extension; it decides PDF or image and becomes the title.
    /// - Throws: `ImportError` for an unsupported type or an image that cannot be decoded.
    static func importFile(data: Data, name: String, into context: ModelContext) throws -> FileOutcome {
        let title = (name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        guard type.conforms(to: .pdf) || type.conforms(to: .image) else { throw ImportError.unsupported(name) }
        let hash = sha256(data)
        if let existing = existingDocument(withHash: hash, in: context) {
            return .duplicate(of: existing)
        }
        let pdfData: Data
        let source: DocumentSource
        if type.conforms(to: .pdf) {
            pdfData = data
            source = .file
        } else {
            guard let converted = PDFBuilder.makePDF(fromImageData: [data]) else { throw ImportError.unreadable(title) }
            pdfData = converted
            source = .image
        }
        return .imported(insert(title: title, pdfData: pdfData, source: source, hash: hash,
                                originalFileName: name, context: context))
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
