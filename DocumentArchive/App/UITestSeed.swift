#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import SwiftData
import SwiftUI

/// Sample data for UI tests (launch argument `-UITestSeed`, see `StoreChoice`).
///
/// Only in DEBUG builds. Everything is generated, nothing is read from disk, and the documents are
/// already processed, so no text recognition or Mistral call is started.
@MainActor
enum UITestSeed {
    struct SampleDocument {
        let title: String
        let correspondent: String
        let type: String
        let tags: [String]
        var isInbox = true
        var isFavorite = false
        var notes = ""
    }

    static let correspondents = ["Stadtwerke Musterstadt", "Musterbank AG", "Dr. Erika Beispiel"]
    static let documentTypes = [("Invoice", "doc.text"), ("Letter", "envelope")]
    static let tags = [("Tax", "#22C55E"), ("Important", "#EF4444"), ("Auto", "#3B82F6"), ("Golf", "#3B82F6")]
    /// Nested tags (#13): child → parent, so the UI tests can open "Auto › Golf".
    static let tagParents = ["Golf": "Auto"]
    /// A saved view (#14): the documents tagged "Tax".
    static let savedViewName = "Taxes"
    /// Markdown notes (#19) on the first document: heading, emphasis, a link and tasks.
    static let sampleNotes = """
        ## Payment
        **Due** by the 30th, see the [customer portal](https://example.com/portal).
        - [x] Meter reading sent
        - [ ] Check the bill
        """

    static let documents = [
        SampleDocument(title: "Electricity bill March", correspondent: correspondents[0], type: "Invoice", tags: ["Tax"],
                       notes: sampleNotes),
        SampleDocument(title: "Account statement", correspondent: correspondents[1], type: "Letter", tags: [],
                       isInbox: false),
        SampleDocument(title: "Medical invoice", correspondent: correspondents[2], type: "Invoice",
                       tags: ["Tax", "Important"], isFavorite: true),
        SampleDocument(title: "Credit card terms", correspondent: correspondents[1], type: "Letter", tags: ["Important"],
                       isInbox: false),
        SampleDocument(title: "Water bill", correspondent: correspondents[0], type: "Invoice", tags: []),
        SampleDocument(title: "Car insurance", correspondent: correspondents[1], type: "Letter", tags: ["Auto"],
                       isInbox: false),
        SampleDocument(title: "Golf inspection", correspondent: correspondents[2], type: "Invoice", tags: ["Golf"],
                       isInbox: false),
    ]

    static func fill(_ context: ModelContext) {
        let correspondentsByName = Dictionary(uniqueKeysWithValues: correspondents.map { ($0, Correspondent(name: $0)) })
        let typesByName = Dictionary(uniqueKeysWithValues: documentTypes.map { ($0.0, DocumentType(name: $0.0, symbol: $0.1)) })
        let tagsByName = Dictionary(uniqueKeysWithValues: tags.map { ($0.0, Tag(name: $0.0, colorHex: $0.1)) })
        correspondentsByName.values.forEach(context.insert)
        typesByName.values.forEach(context.insert)
        tagsByName.values.forEach(context.insert)
        for (child, parent) in tagParents {
            tagsByName[child]?.parent = tagsByName[parent]
        }

        for (index, sample) in documents.enumerated() {
            let lines = [sample.correspondent, sample.title, "Sample document \(index + 1)"]
            let page = renderPage(lines: lines)
            let pdfData = PDFBuilder.makePDF(from: [page]) ?? Data()
            let document = Document(title: sample.title, pdfData: pdfData, source: .file)
            // Spread the dates, so the list order is stable: the first sample is the newest.
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(index) * 86_400)
            document.createdAt = date
            document.modifiedAt = date
            document.documentDate = date
            document.pageCount = 1
            document.extractedText = lines.joined(separator: "\n")
            document.textSource = "PDF-Text"
            document.thumbnailData = ImageCoding.jpegData(from: page, maxPixelSize: 300, quality: 0.7)
            document.contentHash = DocumentImporter.sha256(pdfData)
            document.isInbox = sample.isInbox
            document.isFavorite = sample.isFavorite
            document.notes = sample.notes
            document.isProcessing = false
            context.insert(document)
            document.correspondent = correspondentsByName[sample.correspondent]
            document.documentType = typesByName[sample.type]
            document.tags = sample.tags.compactMap { tagsByName[$0] }
        }

        var taxes = DocumentFilter()
        taxes.tags = tagsByName["Tax"].map { [DocumentFilter.Ref($0)] } ?? []
        taxes.sort = .title
        taxes.ascending = true
        context.insert(SavedView(name: savedViewName, symbol: "eurosign.circle", filter: taxes, sortIndex: 0))
        try? context.save()
    }

    /// A small white page with the given lines, like a scanned letter.
    private static func renderPage(lines: [String], width: Int = 620, height: Int = 877) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 60, y: height - 100 - index * 36)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }
}

/// An invisible element that tells a UI test something happened in the app that it cannot see
/// otherwise (an action ran although no dialog appeared). Only in DEBUG builds started with
/// `-UITestSeed`; nothing for VoiceOver users.
struct UITestMarker: View {
    let id: String
    let isShown: Bool

    private static let isUITestRun = ProcessInfo.processInfo.arguments.contains(StoreChoice.uiTestSeedArgument)

    var body: some View {
        if isShown, Self.isUITestRun {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: id))
                .accessibilityIdentifier(id)
        }
    }
}
#endif
