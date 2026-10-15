import CoreGraphics
import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Legt neue Dokumente an und stößt die Hintergrundverarbeitung an:
/// Vorschaubild, Texterkennung und anschließend die automatische Zuordnung.
@MainActor
enum DocumentImporter {
    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "„\(name)“ konnte nicht gelesen werden."
            case .unsupported(let name): "„\(name)“ ist kein PDF oder Bild."
            }
        }
    }

    static let importableTypes: [UTType] = [.pdf, .image]

    struct ImportResult {
        var imported: [Document] = []
        /// Dateien, die bereits im Archiv liegen (identischer Inhalt) – mit dem vorhandenen Dokument.
        var duplicates: [(fileName: String, existing: Document)] = []
        var errors: [Error] = []
    }

    /// Importiert Dateien (PDFs und Bilder). Jede Datei wird ein eigenes Dokument.
    /// Dateien mit identischem Inhalt wie ein vorhandenes Dokument werden übersprungen.
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

    /// Mehrere Bilder (z. B. Kamera-Scan) werden zu einem mehrseitigen Dokument.
    @discardableResult
    static func importImages(_ images: [CGImage], source: DocumentSource, into context: ModelContext) -> Document? {
        guard let data = PDFBuilder.makePDF(from: images) else { return nil }
        return insert(title: defaultTitle(for: source), pdfData: data, source: source, hash: sha256(data), context: context)
    }

    /// Mehrere Fotos aus der Mediathek werden zu einem mehrseitigen Dokument.
    /// - Returns: Das neue Dokument bzw. das vorhandene, falls genau diese Fotos schon importiert wurden.
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

    /// Ergänzt den Fingerabdruck bei Dokumenten, die vor Einführung der Duplikaterkennung importiert wurden.
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
        case .scan: return "Scan \(date)"
        case .image: return "Foto \(date)"
        case .file: return "Dokument \(date)"
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

    /// Erzeugt Vorschaubild und Volltext im Hintergrund und speichert das Ergebnis.
    /// - Parameter classify: Nach der Texterkennung automatisch Korrespondent, Typ, Tags und Datum zuordnen.
    static func process(_ document: Document, context: ModelContext, classify: Bool) {
        guard let data = document.pdfData else { return }
        document.isProcessing = true
        let mistral = MistralConfig.current()
        Task {
            let result = await Task.detached(priority: .utility) {
                await DocumentProcessor.analyze(data, mistral: mistral)
            }.value
            guard !document.isDeleted else { return }
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
            guard !document.isDeleted else { return }
            document.isProcessing = false
            try? context.save()
        }
    }

    /// Setzt unterbrochene Verarbeitungen fort (z. B. wenn die App währenddessen beendet wurde).
    static func resumePendingProcessing(in context: ModelContext) {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.isProcessing })
        guard let pending = try? context.fetch(descriptor) else { return }
        for document in pending where document.pdfData != nil {
            process(document, context: context, classify: document.isInbox)
        }
    }
}
