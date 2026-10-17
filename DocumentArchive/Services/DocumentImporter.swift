import CoreGraphics
import CryptoKit
import Foundation
import os
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
    /// Each file is read inside its security-scoped access; the duplicate check, the photo
    /// cleanup and the insert follow in `importFile(data:name:origin:cleanup:into:)`.
    /// - Parameter cleanup: How photos are cleaned up; `nil` uses the setting for `origin`.
    @discardableResult
    static func importFiles(_ urls: [URL], origin: ImportOrigin = .interactive, cleanup: CleanupMode? = nil,
                            into context: ModelContext) async -> ImportResult {
        var result = ImportResult()
        for url in urls {
            let data: Data
            do {
                data = try readFile(url)
            } catch {
                Log.importing.error("File not read: \(Log.code(of: error), privacy: .public) \(url.lastPathComponent, privacy: .private)")
                result.errors.append(error)
                continue
            }
            do {
                result.add(try await importFile(data: data, name: url.lastPathComponent, origin: origin,
                                                cleanup: cleanup, into: context),
                           fileName: url.lastPathComponent)
            } catch {
                result.errors.append(error)   // logged by importFile
            }
        }
        return result
    }

    /// The file's bytes, read inside its security-scoped access.
    private static func readFile(_ url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard isImportable(fileName: url.lastPathComponent) else {
            throw ImportError.unsupported(url.lastPathComponent)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url.deletingPathExtension().lastPathComponent)
        }
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
    /// actor): duplicate check on the original bytes, the photo cleanup (#20), then the insert
    /// and the normal processing. `importFiles` and `ExternalImport` both end here, so the paths
    /// cannot drift apart. PDFs are never cleaned up.
    /// - Parameters:
    ///   - name: The file name with its extension; it decides PDF or image and becomes the title.
    ///   - origin: Where the file comes from; decides the cleanup mode when `cleanup` is `nil`.
    ///   - cleanup: How a photo is cleaned up; `nil` uses `CleanupMode.mode(for:setting:)`.
    /// - Throws: `ImportError` for an unsupported type or an image that cannot be decoded.
    static func importFile(data: Data, name: String, origin: ImportOrigin = .interactive,
                           cleanup: CleanupMode? = nil, into context: ModelContext) async throws -> FileOutcome {
        try await Log.interval("import") {
            let outcome: FileOutcome
            do {
                outcome = try await importFileUnlogged(data: data, name: name, origin: origin, cleanup: cleanup,
                                                       into: context)
            } catch {
                Log.importing.error("File not imported: \(Log.code(of: error), privacy: .public) \(name, privacy: .private)")
                throw error
            }
            switch outcome {
            case .imported(let document):
                Log.importing.notice("Imported: \(document.source.rawValue, privacy: .public) from \(String(describing: origin), privacy: .public), \(data.count, privacy: .public) bytes, \(name, privacy: .private)")
            case .duplicate:
                Log.importing.notice("Duplicate skipped: from \(String(describing: origin), privacy: .public), \(data.count, privacy: .public) bytes, \(name, privacy: .private)")
            }
            return outcome
        }
    }

    private static func importFileUnlogged(data: Data, name: String, origin: ImportOrigin,
                                           cleanup: CleanupMode?, into context: ModelContext) async throws -> FileOutcome {
        let title = (name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        guard type.conforms(to: .pdf) || type.conforms(to: .image) else { throw ImportError.unsupported(name) }
        if let existing = existingDocument(for: data, in: context) {
            return .duplicate(of: existing)
        }
        let hash = sha256(data)
        let pdfData: Data
        let source: DocumentSource
        if type.conforms(to: .pdf) {
            pdfData = data
            source = .file
        } else {
            let mode = cleanup ?? CleanupMode.mode(for: origin, setting: ProcessingEnvironment.current.cleanupMode())
            guard let converted = await makeImagePDF([data], title: title, originalFileName: name, mode: mode)
            else { throw ImportError.unreadable(title) }
            pdfData = converted
            source = .image
            // Another import may have added the same file while this one was being built.
            if let existing = existingDocument(withHash: hash, in: context) { return .duplicate(of: existing) }
        }
        return .imported(insert(title: title, pdfData: pdfData, source: source, hash: hash,
                                originalFileName: name, context: context))
    }

    /// Builds the PDF for photos in the given mode, off the main actor.
    private static func makeImagePDF(_ items: [Data], title: String, originalFileName: String = "",
                                     mode: CleanupMode) async -> Data? {
        // Read before detaching: `ProcessingEnvironment.current` is `.live` inside `Task.detached`.
        let environment = ProcessingEnvironment.current
        let filter = environment.cleanupFilter()
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            switch mode {
            case .off:
                return PDFBuilder.makePDF(fromImageData: items)
            case .automatic:
                guard let pending = await PendingImport.make(originalData: items, title: title,
                                                             originalFileName: originalFileName, filter: filter,
                                                             environment: environment)
                else { return nil }
                return makeDocumentData(pending.unattended)
            }
        }.value
    }

    /// The cleaned PDF of a pending import: every page is decoded at full resolution from the
    /// original bytes, cleaned up with its settings, added to the PDF and released before the
    /// next one. Inserting is separate (`importCleaned`), so #22's vault import can seal the
    /// data first.
    nonisolated static func makeDocumentData(_ pending: PendingImport) -> Data? {
        PDFBuilder.makePDF(pageCount: pending.originalData.count) { index in
            guard let page = ImageCoding.orientedImage(from: pending.originalData[index],
                                                       maxPixelSize: ImageCoding.pagePixelSize)
            else { return nil }
            let settings = pending.settings.indices.contains(index) ? pending.settings[index] : CleanupSettings(filter: .original)
            return ImageCleanup.apply(settings, to: page) ?? page
        }
    }

    /// Builds the cleaned PDF and inserts it with the **original** hash, so the same photo is
    /// still found as a duplicate. `nil` when the photos cannot be decoded.
    static func importCleaned(_ pending: PendingImport, into context: ModelContext) async -> Document? {
        let data = await Task.detached(priority: .userInitiated) { makeDocumentData(pending) }.value
        guard let data else { return nil }
        return insert(title: pending.title, pdfData: data, source: pending.source, hash: pending.hash,
                      originalFileName: pending.originalFileName, context: context)
    }

    /// Several images (e.g. a camera scan) become one multi-page document.
    @discardableResult
    static func importImages(_ images: [CGImage], source: DocumentSource, into context: ModelContext) -> Document? {
        guard let data = PDFBuilder.makePDF(from: images) else {
            Log.importing.error("Scan not imported: the PDF could not be built from \(images.count, privacy: .public) pages")
            return nil
        }
        Log.importing.notice("Imported: \(source.rawValue, privacy: .public), \(images.count, privacy: .public) pages, \(data.count, privacy: .public) bytes")
        return insert(title: defaultTitle(for: source), pdfData: data, source: source, hash: sha256(data), context: context)
    }

    /// Several photos from the library become one multi-page document.
    /// - Parameter cleanup: How the photos are cleaned up; `nil` uses the setting.
    /// - Returns: The new document, or the existing one if exactly these photos were imported before.
    static func importImageData(_ items: [Data], cleanup: CleanupMode? = nil,
                                into context: ModelContext) async -> (document: Document?, isDuplicate: Bool) {
        let combined = items.reduce(Data(), +)
        if let existing = existingDocument(for: combined, in: context) {
            Log.importing.notice("Duplicate skipped: \(items.count, privacy: .public) photos")
            return (existing, true)
        }
        let hash = sha256(combined)
        let title = defaultTitle(for: .image)
        let mode = cleanup ?? CleanupMode.mode(for: .interactive, setting: ProcessingEnvironment.current.cleanupMode())
        guard let data = await makeImagePDF(items, title: title, mode: mode) else {
            Log.importing.error("Photos not imported: \(items.count, privacy: .public) photos could not be read")
            return (nil, false)
        }
        if let existing = existingDocument(withHash: hash, in: context) {
            Log.importing.notice("Duplicate skipped: \(items.count, privacy: .public) photos")
            return (existing, true)
        }
        Log.importing.notice("Imported: image, \(items.count, privacy: .public) photos, \(data.count, privacy: .public) bytes")
        return (insert(title: title, pdfData: data, source: .image, hash: hash, context: context), false)
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The document that already holds these bytes: first by `contentHash` (the hash of the
    /// originally imported file), then, for PDFs whose stored data was replaced later (text
    /// layer, cleanup) and exported, by comparing the stored PDF of documents with the same size.
    /// Every import path uses this check; #12 and #20 reuse it.
    static func existingDocument(for data: Data, in context: ModelContext) -> Document? {
        let hash = sha256(data)
        if let existing = existingDocument(withHash: hash, in: context) { return existing }
        let size = data.count
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.fileSize == size },
                                                   sortBy: [SortDescriptor(\.createdAt)])
        guard let candidates = try? context.fetch(descriptor) else { return nil }
        return candidates.first { candidate in
            guard let stored = candidate.pdfData, stored.count == size else { return false }
            return sha256(stored) == hash
        }
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
        // Task-locals do not reach into `Task.detached`: capture the environment here, on the
        // caller's side, and pass it on explicitly.
        let environment = ProcessingEnvironment.current
        let mistral = environment.mistralConfig()
        let layerSource: DocumentSource? = environment.textLayerEnabled() ? document.source : nil
        let result = await Task.detached(priority: .utility) {
            await DocumentProcessor.analyze(data, mistral: mistral, textLayerSource: layerSource, environment: environment)
        }.value
        guard document.isAlive else { return }
        document.pageCount = result.pageCount
        document.thumbnailData = result.thumbnail
        document.extractedText = result.text
        document.textSource = result.textSource
        document.processingNote = result.note
        if let searchablePDF = result.searchablePDF {
            replacePDF(of: document, analyzed: data, with: searchablePDF)
        }
        document.fileSize = document.pdfData?.count ?? data.count
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

    /// Replaces the stored PDF with its text-layer version, but only when the stored bytes are
    /// still the ones that were analyzed: a sync, a merge or another edit may have changed
    /// `pdfData` during the analysis, and that newer data wins (the next processing run adds the
    /// layer to it). `contentHash` stays the hash of the original import, so duplicate detection
    /// keeps working; `touch()` makes the folder copy write the new PDF.
    /// #22 adds: never for documents in the vault (`isInVault`).
    /// - Returns: Whether the PDF was replaced.
    @discardableResult
    static func replacePDF(of document: Document, analyzed: Data, with newData: Data) -> Bool {
        guard document.isAlive, let current = document.pdfData,
              current.count == analyzed.count, sha256(current) == sha256(analyzed)
        else { return false }
        document.pdfData = newData
        document.fileSize = newData.count
        document.touch()
        return true
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
