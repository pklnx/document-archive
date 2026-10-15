import Foundation
import SwiftData
import SwiftUI

/// Wie ein Tag, Korrespondent oder Dokumenttyp automatisch einem neuen Dokument zugeordnet wird
/// (wie die Zuweisungsregeln in paperless-ngx).
enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case none
    case any
    case all
    case exact
    case regex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Keine automatische Zuordnung"
        case .any: "Eines der Wörter"
        case .all: "Alle Wörter"
        case .exact: "Exakter Ausdruck"
        case .regex: "Regulärer Ausdruck"
        }
    }
}

/// Gemeinsame Eigenschaften von Tag, Korrespondent und Dokumenttyp.
protocol MatchingRule: AnyObject {
    var name: String { get }
    var matchText: String { get }
    var matchMode: MatchMode { get }
}

extension MatchingRule {
    /// Prüft, ob der Dokumenttext zur Regel passt (ohne Groß-/Kleinschreibung und Akzente).
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

    /// Wie gut die Regel passt (0 = gar nicht). Bei „Eines der Wörter“ zählt jedes gefundene Wort.
    func matchScore(text: String) -> Int {
        guard matches(text: text) else { return 0 }
        if matchMode == .any {
            return words(in: matchText.trimmingCharacters(in: .whitespacesAndNewlines))
                .filter { containsWord($0, in: text) }.count
        }
        return 2 // exakte Ausdrücke, Regex und „alle Wörter“ sind spezifischer als ein einzelnes Wort
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

    var documents: [Document]? = []

    init(name: String, colorHex: String = Tag.palette.randomElement()!) {
        self.name = name
        self.colorHex = colorHex
    }

    var color: Color { Color(hex: colorHex) }
    var documentCount: Int { documents?.count ?? 0 }

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

    /// Standard: exakter Ausdruck mit dem Namen ohne Firmenform. „Eines der Wörter“ würde z. B. bei
    /// „Stadtwerke München“ jedes Dokument mit „München“ zuordnen.
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

    /// Startvorgaben, die beim ersten Start angelegt werden.
    static let defaults: [(String, String, String)] = [
        ("Rechnung", "eurosign.circle", "Rechnung Rechnungsnummer Rechnungsdatum Invoice Factura Facture"),
        ("Quittung", "cart", "Quittung Kassenbon Kassenbeleg Kaufbeleg Receipt Zahlungsbestätigung"),
        ("Vertrag", "signature", "Vertrag Vertragsnummer Contract Agreement"),
        ("Kontoauszug", "building.columns", "Kontoauszug Bankauszug Depotauszug"),
        ("Brief", "envelope", ""),
        ("Bescheid", "doc.plaintext", "Bescheid Steuerbescheid"),
        ("Versicherung", "shield", "Versicherungsschein Police Versicherungsnummer"),
        ("Gehaltsabrechnung", "list.bullet.rectangle", "Gehaltsabrechnung Entgeltabrechnung Lohnabrechnung Payslip"),
        ("Arztbrief", "cross.case", "Arztbrief Befund Diagnose"),
    ]

    /// Frühere Standard-Suchbegriffe – unverändert übernommene Typen werden auf die neuen aktualisiert.
    static let legacyDefaults: [String: String] = [
        "Rechnung": "Rechnung Rechnungsnummer Rechnungsdatum",
        "Vertrag": "Vertrag Vertragsnummer",
        "Kontoauszug": "Kontoauszug",
        "Bescheid": "Bescheid",
        "Versicherung": "Versicherungsschein Police",
        "Gehaltsabrechnung": "Gehaltsabrechnung Entgeltabrechnung Lohnabrechnung",
    ]

    /// Aktualisiert Suchbegriffe von Standardtypen, die der Nutzer nicht selbst verändert hat.
    @MainActor
    static func upgradeDefaults(in context: ModelContext) {
        guard let types = try? context.fetch(FetchDescriptor<DocumentType>()) else { return }
        for type in types {
            guard let legacy = legacyDefaults[type.name], type.matchText == legacy,
                  let current = defaults.first(where: { $0.0 == type.name }) else { continue }
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
