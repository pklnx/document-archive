import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

@Suite @MainActor struct DocumentAccessibilityTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    /// Dates and lists are formatted with this locale; words come from the String Catalog in the
    /// language the tests run in, so the expectations read them the same way.
    let locale = Locale(identifier: "en_US")
    let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!

    init() throws {
        container = try TestSupport.makeContainer()
    }

    private func document(_ title: String) -> Document {
        let document = Document(title: title, pdfData: Data(), source: .file)
        context.insert(document)
        document.documentDate = date
        document.isProcessing = false
        document.isInbox = false
        return document
    }

    @Test func labelNamesEverythingTheRowShows() {
        let document = document("Electricity bill")
        let correspondent = Correspondent(name: "Stadtwerke")
        let type = DocumentType(name: "Invoice")
        let tags = [ArchiveTag(name: "Tax"), ArchiveTag(name: "Home")]
        [correspondent].forEach(context.insert)
        context.insert(type)
        tags.forEach(context.insert)
        document.correspondent = correspondent
        document.documentType = type
        document.tags = tags
        document.isFavorite = true
        document.isInbox = true
        document.isProcessing = true

        let label = DocumentAccessibility.label(for: document, locale: locale)

        let longDate = date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(locale))
        #expect(longDate == "March 9, 2026")
        #expect(label == [
            "Electricity bill", longDate, "Stadtwerke", "Invoice",
            String(localized: "tags: \("Home and Tax")"),
            String(localized: "favorite"), String(localized: "in inbox"), String(localized: "text recognition running"),
        ].joined(separator: ", "))
    }

    @Test func emptyPartsAreLeftOut() {
        let document = document("Letter")
        let label = DocumentAccessibility.label(for: document, locale: locale)
        #expect(label == "Letter, March 9, 2026")
        #expect(!label.contains(", ,") && !label.hasSuffix(", "))
    }

    @Test func untitledDocumentStillHasAName() {
        let label = DocumentAccessibility.label(for: document(""), locale: locale)
        #expect(label.hasPrefix(String(localized: "Untitled document") + ", "))
    }

    @Test func tagListIsALocalizedList() {
        #expect(DocumentAccessibility.tagList([], locale: locale) == nil)
        #expect(DocumentAccessibility.tagList(["Tax"], locale: locale) == "Tax")
        #expect(DocumentAccessibility.tagList(["Car", "Home", "Tax"], locale: locale) == "Car, Home, and Tax")
        #expect(DocumentAccessibility.tagList(["Auto", "Steuer"], locale: Locale(identifier: "de_DE")) == "Auto und Steuer")
    }

    @Test func documentCountUsesSingularForOne() {
        #expect(DocumentAccessibility.documentCount(1) == String(localized: "1 document"))
        #expect(DocumentAccessibility.documentCount(3) == String(localized: "\(3) documents"))
    }
}

@Suite struct ReadableNamesTests {
    @Test func everyPaletteColorHasAName() {
        #expect(ArchiveTag.paletteNames.count == ArchiveTag.palette.count)
        #expect(Set(ArchiveTag.paletteNames).count == ArchiveTag.paletteNames.count)
        #expect(ArchiveTag.paletteNames.allSatisfy { !$0.isEmpty })
        #expect(ArchiveTag.colorName(for: "#ef4444") == ArchiveTag.paletteNames[0], "case does not matter")
        #expect(ArchiveTag.colorName(for: "#123456") == String(localized: "Custom color"))
    }

    @Test func everySymbolChoiceHasAName() {
        #expect(Set(DocumentType.symbolNames.keys) == Set(DocumentType.symbolChoices))
        #expect(Set(DocumentType.symbolNames.values).count == DocumentType.symbolNames.count)
        #expect(DocumentType.symbolName(for: "questionmark") == String(localized: "Symbol"))
    }
}
