import Foundation
import SwiftData

/// Ordnet neuen Dokumenten anhand ihres Textes automatisch Korrespondent, Dokumenttyp,
/// Tags, Titel und Ausstellungsdatum zu – wie die automatische Zuweisung in paperless-ngx.
///
/// Reihenfolge:
/// 1. Korrespondent über deine Regeln (exakte Namen sind am zuverlässigsten)
/// 2. Mistral (falls eingerichtet): Korrespondent, Dokumenttyp, Tags, Titel, Datum
/// 3. Deine Regeln für Typ und Tags, falls noch offen
/// 4. Lokale Heuristiken: Absendererkennung und Datumserkennung
@MainActor
enum AutoClassifier {
    /// Einstellung: Unbekannte Absender automatisch als neuen Korrespondenten anlegen.
    static let autoCreateCorrespondentsKey = "autoCreateCorrespondents"

    static var autoCreateCorrespondents: Bool {
        UserDefaults.standard.object(forKey: autoCreateCorrespondentsKey) as? Bool ?? true
    }

    /// Was bei einer Zuordnung geändert wurde – für die Rückmeldung in der Oberfläche.
    struct Outcome {
        var changes: [String] = []
        var isComplete = false
        var usedAI = false
        var aiError: String?

        var summary: String {
            var lines = changes
            if let aiError { lines.append("⚠︎ \(aiError)") }
            if changes.isEmpty {
                lines.insert(isComplete
                    ? "Korrespondent und Dokumenttyp sind bereits zugeordnet. Manuell gesetzte Felder werden nicht überschrieben."
                    : "Nichts Neues erkannt. Lege Korrespondenten, Dokumenttypen oder Tags an oder richte Mistral in den Einstellungen ein.",
                    at: 0)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Füllt nur leere Felder; manuell gesetzte Zuordnungen bleiben unangetastet.
    @discardableResult
    static func classify(_ document: Document, context: ModelContext) async -> Outcome {
        var outcome = Outcome()
        let text = document.title + "\n" + document.extractedText
        var correspondents = fetchCorrespondents(context)
        let types = (try? context.fetch(FetchDescriptor<DocumentType>())) ?? []
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let dateIsUntouched = Calendar.current.isDate(document.documentDate, inSameDayAs: document.createdAt)

        // 1. Korrespondent über Regeln
        if document.correspondent == nil, let match = bestMatch(in: correspondents, text: text) {
            document.correspondent = match
            outcome.changes.append("Korrespondent: \(match.name)")
        }

        // 2. Mistral
        if let config = MistralConfig.current(), config.useLLM, !document.extractedText.isEmpty {
            do {
                let suggestion = try await MistralClient(config: config).classify(
                    text: document.extractedText,
                    fileName: document.originalFileName,
                    correspondents: correspondents.map(\.name),
                    documentTypes: types.map(\.name),
                    tags: tags.map(\.name)
                )
                guard !document.isDeleted else { return outcome }
                outcome.usedAI = true
                // Während des Wartens auf Mistral können parallel importierte Dokumente Korrespondenten
                // angelegt haben – daher die Liste neu laden, sonst entstehen Duplikate.
                correspondents = fetchCorrespondents(context)
                if document.correspondent == nil, let match = bestMatch(in: correspondents, text: text) {
                    document.correspondent = match
                    outcome.changes.append("Korrespondent: \(match.name)")
                }
                apply(suggestion, to: document, correspondents: correspondents, types: types, tags: tags,
                      dateIsUntouched: dateIsUntouched, context: context, outcome: &outcome)
            } catch {
                outcome.aiError = error.localizedDescription
            }
        }

        // 3. Regeln für Typ und Tags
        if document.documentType == nil, let match = bestMatch(in: types, text: text) {
            document.documentType = match
            outcome.changes.append("Dokumenttyp: \(match.name)")
        }
        for tag in tags where tag.matches(text: text) && !document.hasTag(tag) {
            document.toggleTag(tag)
            outcome.changes.append("Tag: \(tag.name)")
        }

        // 4. Heuristiken
        correspondents = fetchCorrespondents(context)
        if document.correspondent == nil, autoCreateCorrespondents,
           let detected = SenderDetector.detect(in: document.extractedText) {
            let (correspondent, isNew) = findOrCreateCorrespondent(named: detected.name, matchText: detected.matchText,
                                                                   among: correspondents, context: context)
            document.correspondent = correspondent
            outcome.changes.append(isNew ? "Neuer Korrespondent: \(correspondent.name)" : "Korrespondent: \(correspondent.name)")
        }
        if dateIsUntouched, Calendar.current.isDate(document.documentDate, inSameDayAs: document.createdAt),
           let date = DateDetector.firstDate(in: document.extractedText),
           !Calendar.current.isDate(date, inSameDayAs: document.documentDate) {
            document.documentDate = date
            outcome.changes.append("Datum: \(date.formatted(date: .long, time: .omitted))")
        }
        // Gescannte Dokumente ohne KI-Titel bekommen „Typ Korrespondent“ statt „Scan 15.10.2026 …“
        if document.source != .file, document.hasAutomaticTitle {
            let parts = [document.documentType?.name, document.correspondent?.name].compactMap { $0 }
            if !parts.isEmpty {
                document.title = parts.joined(separator: " ")
                outcome.changes.append("Titel: \(document.title)")
            }
        }

        if !outcome.changes.isEmpty { document.touch() }
        outcome.isComplete = document.correspondent != nil && document.documentType != nil
        return outcome
    }

    private static func apply(_ suggestion: MistralClient.Suggestion, to document: Document,
                              correspondents: [Correspondent], types: [DocumentType], tags: [Tag],
                              dateIsUntouched: Bool, context: ModelContext, outcome: inout Outcome) {
        if document.correspondent == nil, let name = suggestion.correspondent?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let core = SenderDetector.coreName(name)
            let existing = correspondents.first { sameName($0.name, name) || sameName(SenderDetector.coreName($0.name), core) }
            if let existing {
                document.correspondent = existing
                outcome.changes.append("Korrespondent (KI): \(existing.name)")
            } else if autoCreateCorrespondents {
                let (created, _) = findOrCreateCorrespondent(named: name, matchText: core, among: correspondents, context: context)
                document.correspondent = created
                outcome.changes.append("Neuer Korrespondent (KI): \(created.name)")
            }
        }
        if document.documentType == nil, let name = suggestion.documentType,
           let type = types.first(where: { sameName($0.name, name) }) {
            document.documentType = type
            outcome.changes.append("Dokumenttyp (KI): \(type.name)")
        }
        for name in suggestion.tags ?? [] {
            if let tag = tags.first(where: { sameName($0.name, name) }), !document.hasTag(tag) {
                document.toggleTag(tag)
                outcome.changes.append("Tag (KI): \(tag.name)")
            }
        }
        if dateIsUntouched, let date = suggestion.parsedDate,
           !Calendar.current.isDate(date, inSameDayAs: document.documentDate) {
            document.documentDate = date
            outcome.changes.append("Datum (KI): \(date.formatted(date: .long, time: .omitted))")
        }
        if document.hasAutomaticTitle, let title = suggestion.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, title != document.title {
            document.title = String(title.prefix(120))
            outcome.changes.append("Titel (KI): \(document.title)")
        }
    }

    private static func findOrCreateCorrespondent(named name: String, matchText: String, among existing: [Correspondent],
                                                  context: ModelContext) -> (Correspondent, isNew: Bool) {
        if let match = existing.first(where: { sameName($0.name, name) || sameName(SenderDetector.coreName($0.name), matchText) }) {
            return (match, false)
        }
        let new = Correspondent(name: name)
        new.matchText = matchText
        new.matchMode = .exact
        context.insert(new)
        try? context.save()
        return (new, true)
    }

    private static func fetchCorrespondents(_ context: ModelContext) -> [Correspondent] {
        (try? context.fetch(FetchDescriptor<Correspondent>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Bei mehreren Treffern gewinnt die Regel mit den meisten passenden Suchbegriffen.
    private static func bestMatch<T: MatchingRule>(in rules: [T], text: String) -> T? {
        rules.map { ($0, $0.matchScore(text: text)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}

/// Erkennt den Absender eines Dokuments, wenn noch kein passender Korrespondent existiert.
/// 1. Zeile mit Firmenform (GmbH, AG, Inc., PBC …), außerhalb des Empfängerblocks
/// 2. Sonst die Domain der ersten geschäftlichen E-Mail- oder Web-Adresse
enum SenderDetector {
    struct Sender: Equatable {
        var name: String
        /// Name ohne Firmenform – wird als exakter Suchbegriff für künftige Dokumente verwendet
        var matchText: String
    }

    private static let legalForm = #"(?:GmbH\s*&\s*Co\.?\s*KG(?:aA)?|gGmbH|GmbH|mbH|AG|SE|KGaA|KG|OHG|UG(?:\s*\(haftungsbeschränkt\))?|GbR|e\.\s?V\.|eG|Inc\.?|LLC|L\.L\.C\.|Ltd\.?|Limited|PBC|Corp\.?|Corporation|PLC|plc|S\.A\.|SA|S\.?A\.?R\.?L\.?|B\.V\.|BV|N\.V\.|AB|ApS|A/S|Oy|S\.p\.A\.|S\.r\.l\.)"#

    /// Schlüsselwörter, nach denen Empfängeradressen folgen – diese Zeilen sind nicht der Absender.
    private static let recipientMarkers = [
        "bill to", "billed to", "ship to", "sold to", "invoice to", "customer",
        "rechnungsempfänger", "rechnungsadresse", "lieferadresse", "empfänger", "kunde:", "an:",
    ]

    private static let freemailDomains: Set<String> = [
        "gmail", "googlemail", "web", "gmx", "mail", "outlook", "hotmail", "live", "icloud", "me", "mac",
        "yahoo", "t-online", "posteo", "aol", "freenet", "arcor", "proton", "protonmail", "mailbox", "online",
    ]

    static func detect(in text: String) -> Sender? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var skipUntil = -1
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if recipientMarkers.contains(where: { lower.hasPrefix($0) }) {
                skipUntil = index + 5 // Empfängerblock (Name + Adresse) überspringen
                continue
            }
            guard index > skipUntil, line.count <= 90, let name = companyName(in: line) else { continue }
            return Sender(name: name, matchText: coreName(name))
        }

        if let domain = firstBusinessDomain(in: text) {
            let name = domain.prefix(1).uppercased() + domain.dropFirst()
            return Sender(name: name, matchText: name)
        }
        return nil
    }

    /// „Anthropic, PBC @anthropic“ → „Anthropic, PBC“
    static func companyName(in line: String) -> String? {
        let pattern = #"^([\p{L}\p{N}][\p{L}\p{N}&.,'’\- ]{1,60}?[,\s]\s*"# + legalForm + #")(?=$|[\s,;·|•/@()])"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let name = String(line[range]).trimmingCharacters(in: .whitespaces)
        // Zeilen wie „Sitz der Gesellschaft …“ oder Bankverbindungen ausschließen
        let lower = name.lowercased()
        let excluded = ["sitz", "registergericht", "amtsgericht", "geschäftsführ", "bank", "iban", "vat", "ust"]
        guard !excluded.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return name
    }

    /// Name ohne Firmenform: „Stadtwerke München GmbH“ → „Stadtwerke München“
    static func coreName(_ name: String) -> String {
        let stripped = name.replacingOccurrences(of: #"[,\s]+"# + legalForm + #"\s*$"#, with: "", options: .regularExpression)
        let trimmed = stripped.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
        return trimmed.isEmpty ? name : trimmed
    }

    private static func firstBusinessDomain(in text: String) -> String? {
        let pattern = #"(?:[A-Za-z0-9._%+-]+@|www\.)([A-Za-z0-9-]+)\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let domain = nsText.substring(with: match.range(at: 1)).lowercased()
            if !freemailDomains.contains(domain), domain.count > 2 { return domain }
        }
        return nil
    }
}

/// Findet das erste plausible Datum in einem deutschen oder englischen Text.
enum DateDetector {
    private static let months: [String: Int] = [
        "januar": 1, "jänner": 1, "jan": 1, "january": 1,
        "februar": 2, "feb": 2, "february": 2,
        "märz": 3, "maerz": 3, "mär": 3, "mar": 3, "march": 3,
        "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juni": 6, "jun": 6, "june": 6,
        "juli": 7, "jul": 7, "july": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "oktober": 10, "okt": 10, "oct": 10, "october": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "dez": 12, "dec": 12, "december": 12,
    ]

    // Swift-Regex unterstützt kein Lookbehind, daher die Gruppe `(?:^|…)` als Vorbedingung
    private static let numeric = /(?:^|[^\d.])(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})(?!\d)/
    private static let iso = /(?:^|\D)(\d{4})-(\d{2})-(\d{2})(?!\d)/
    private static let written = /(?i)(?:^|\D)(\d{1,2})\.?\s+([a-zäöü]{3,9})\.?\s+(\d{4})(?!\d)/
    /// Englisch: „October 3, 2026“ oder „Oct 3 2026“
    private static let writtenUS = /(?i)([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)/

    static func firstDate(in text: String) -> Date? {
        var candidates: [(position: String.Index, date: Date)] = []

        for match in text.matches(of: numeric) {
            var year = Int(match.3) ?? 0
            if year < 100 { year += year > 50 ? 1900 : 2000 }
            if let date = make(Int(match.1), Int(match.2), year) {
                candidates.append((match.range.lowerBound, date))
            }
        }
        for match in text.matches(of: iso) {
            if let date = make(Int(match.3), Int(match.2), Int(match.1)) {
                candidates.append((match.range.lowerBound, date))
            }
        }
        for match in text.matches(of: written) {
            if let month = months[String(match.2).lowercased()],
               let date = make(Int(match.1), month, Int(match.3)) {
                candidates.append((match.range.lowerBound, date))
            }
        }
        for match in text.matches(of: writtenUS) {
            if let month = months[String(match.1).lowercased()],
               let date = make(Int(match.2), month, Int(match.3)) {
                candidates.append((match.range.lowerBound, date))
            }
        }
        return candidates.min { $0.position < $1.position }?.date
    }

    private static func make(_ day: Int?, _ month: Int?, _ year: Int?) -> Date? {
        guard let day, let month, let year,
              (1...31).contains(day), (1...12).contains(month), (1950...2100).contains(year)
        else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: 12)
        components.calendar = Calendar(identifier: .gregorian)
        guard let date = components.date, components.isValidDate,
              date <= Date().addingTimeInterval(60 * 60 * 24 * 365) // max. ein Jahr in der Zukunft
        else { return nil }
        return date
    }
}
