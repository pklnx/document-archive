import Foundation
import SwiftData
import SwiftUI

/// How a tag, correspondent or document type is assigned to a new document automatically
/// (like the matching rules in paperless-ngx).
///
/// **Frozen:** never add a case. It is stored in synced models, and an older app version cannot
/// decode a value it does not know.
enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case none
    case any
    case all
    case exact
    case regex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "No automatic assignment")
        case .any: String(localized: "Any of the words")
        case .all: String(localized: "All words")
        case .exact: String(localized: "Exact phrase")
        case .regex: String(localized: "Regular expression")
        }
    }
}

/// What tags, correspondents and document types have in common.
protocol MatchingRule: AnyObject {
    var name: String { get }
    var matchText: String { get }
    var matchMode: MatchMode { get }
}

extension MatchingRule {
    /// Whether the document text matches the rule (ignoring case and diacritics).
    func matches(text: String) -> Bool {
        let pattern = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !text.isEmpty else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch matchMode {
        case .none:
            return false
        case .any:
            return words(in: pattern).contains { containsWord($0, in: text) }
        case .all:
            return words(in: pattern).allSatisfy { containsWord($0, in: text) }
        case .exact:
            return text.range(of: pattern, options: options) != nil
        case .regex:
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// How well the rule matches (0 = not at all). For "any of the words", every word found counts.
    func matchScore(text: String) -> Int {
        guard matches(text: text) else { return 0 }
        if matchMode == .any {
            return words(in: matchText.trimmingCharacters(in: .whitespacesAndNewlines))
                .filter { containsWord($0, in: text) }.count
        }
        return 2 // exact phrases, regexes and "all words" are more specific than a single word
    }

    private func words(in pattern: String) -> [String] {
        pattern.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    private func containsWord(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return text.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                          options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }
}

@Model
final class Tag: MatchingRule {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#3B82F6"
    var matchText: String = ""
    var matchMode: MatchMode = MatchMode.any
    var createdAt: Date = Date()
    /// SF Symbol shown for the tag (#13). Older versions ignore it.
    var symbol: String = "tag.fill"

    var documents: [Document]? = []

    /// The tag this one is nested in (#13); `nil` for a root. Older versions ignore it and show a
    /// flat list. Deleting a parent there nullifies `parent`, so its children become roots.
    /// Never set it directly from the UI: `TagHierarchy.move(_:under:)` refuses cycles.
    var parent: Tag?
    /// The inverse of `parent`. Siblings are shown alphabetically (no sort index).
    @Relationship(deleteRule: .nullify, inverse: \Tag.parent)
    var children: [Tag]? = []

    init(name: String, colorHex: String = Tag.palette.randomElement()!) {
        self.name = name
        self.colorHex = colorHex
    }

    var color: Color { Color(hex: colorHex) }
    var documentCount: Int { documents?.count ?? 0 }

    /// Symbols offered in the tag editor (#13); the first is the default.
    static let symbolChoices = [
        "tag.fill", "folder.fill", "star.fill", "heart.fill", "flag.fill", "bookmark.fill",
        "house.fill", "car.fill", "briefcase.fill", "cross.case.fill", "eurosign.circle.fill", "building.columns.fill",
        "graduationcap.fill", "airplane", "cart.fill", "bolt.fill", "pawprint.fill", "leaf.fill",
    ]

    static let palette = [
        "#EF4444", "#F97316", "#EAB308", "#22C55E", "#14B8A6",
        "#3B82F6", "#6366F1", "#A855F7", "#EC4899", "#64748B",
    ]
}

@Model
final class Correspondent: MatchingRule {
    var id: UUID = UUID()
    var name: String = ""
    var matchText: String = ""
    var matchMode: MatchMode = MatchMode.any
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Document.correspondent)
    var documents: [Document]? = []

    /// Default: exact phrase with the name without its legal form. "Any of the words" would, for
    /// "Stadtwerke München", assign every document that mentions "München".
    init(name: String) {
        self.name = name
        self.matchText = SenderDetector.coreName(name)
        self.matchMode = .exact
    }

    var documentCount: Int { documents?.count ?? 0 }
}

@Model
final class DocumentType: MatchingRule {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "doc.text"
    var matchText: String = ""
    var matchMode: MatchMode = MatchMode.any
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Document.documentType)
    var documents: [Document]? = []

    init(name: String, symbol: String = "doc.text", matchText: String = "") {
        self.name = name
        self.symbol = symbol
        self.matchText = matchText
    }

    var documentCount: Int { documents?.count ?? 0 }

    static let symbolChoices = [
        "doc.text", "eurosign.circle", "doc.plaintext", "envelope", "signature", "list.bullet.rectangle",
        "building.columns", "cross.case", "house", "car", "shield", "person.text.rectangle",
        "graduationcap", "briefcase", "cart", "bolt", "phone", "airplane",
    ]

    /// Recommended types the user can create in the settings: (name, symbol, match words).
    /// Names follow the app language; the match words cover German and English documents,
    /// because they must match the documents' language, not the UI's.
    static var defaults: [(String, String, String)] {
        [
            (String(localized: "Invoice"), "eurosign.circle",
             "Rechnung Rechnungsnummer Rechnungsdatum Invoice Factura Facture"),
            (String(localized: "Receipt"), "cart",
             "Quittung Kassenbon Kassenbeleg Kaufbeleg Receipt Zahlungsbestätigung"),
            (String(localized: "Contract"), "signature", "Vertrag Vertragsnummer Contract Agreement"),
            (String(localized: "Bank statement"), "building.columns", "Kontoauszug Bankauszug Depotauszug"),
            (String(localized: "Letter"), "envelope", ""),
            (String(localized: "Notice"), "doc.plaintext", "Bescheid Steuerbescheid"),
            (String(localized: "Insurance"), "shield", "Versicherungsschein Police Versicherungsnummer"),
            (String(localized: "Payslip"), "list.bullet.rectangle",
             "Gehaltsabrechnung Entgeltabrechnung Lohnabrechnung Payslip"),
            (String(localized: "Medical letter"), "cross.case", "Arztbrief Befund Diagnose"),
        ]
    }

    /// Match words of earlier versions, keyed by the German type name used then, with the symbol
    /// that identifies the current default. Types the user left unchanged get the new words.
    static let legacyDefaults: [String: (symbol: String, matchText: String)] = [
        "Rechnung": ("eurosign.circle", "Rechnung Rechnungsnummer Rechnungsdatum"),
        "Vertrag": ("signature", "Vertrag Vertragsnummer"),
        "Kontoauszug": ("building.columns", "Kontoauszug"),
        "Bescheid": ("doc.plaintext", "Bescheid"),
        "Versicherung": ("shield", "Versicherungsschein Police"),
        "Gehaltsabrechnung": ("list.bullet.rectangle", "Gehaltsabrechnung Entgeltabrechnung Lohnabrechnung"),
    ]

    /// Updates the match words of default types the user has not changed.
    @MainActor
    static func upgradeDefaults(in context: ModelContext) {
        guard let types = try? context.fetch(FetchDescriptor<DocumentType>()) else { return }
        for type in types {
            guard let legacy = legacyDefaults[type.name], type.matchText == legacy.matchText,
                  let current = defaults.first(where: { $0.1 == legacy.symbol }) else { continue }
            type.matchText = current.2
        }
        try? context.save()
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0x3B82F6
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
