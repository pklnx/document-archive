import Foundation
import os
import SwiftData

/// Assigns correspondent, document type, tags, title and issue date to new documents from
/// their text, like the automatic matching in paperless-ngx.
///
/// Order:
/// 1. Correspondent through the user's rules (exact names are the most reliable)
/// 2. Mistral (if set up): correspondent, document type, tags, title, date
/// 3. The user's rules for type and tags, if still empty
/// 4. Local heuristics: sender detection and date detection
@MainActor
enum AutoClassifier {
    /// Setting: create unknown senders as new correspondents automatically.
    // nonisolated: also read by `LegacyMigration.settingKeys`, which is not on the main actor.
    nonisolated static let autoCreateCorrespondentsKey = "autoCreateCorrespondents"

    /// Read from `ProcessingEnvironment.current.defaults`; tests use a throwaway suite.
    static var autoCreateCorrespondents: Bool {
        ProcessingEnvironment.current.defaults.object(forKey: autoCreateCorrespondentsKey) as? Bool ?? true
    }

    /// What an assignment run changed, for the feedback in the UI.
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
                    ? String(localized: "Correspondent and document type are already assigned. Fields set by hand are not overwritten.")
                    : String(localized: "Nothing new found. Create correspondents, document types or tags, or set up Mistral in the settings."),
                    at: 0)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Only fills empty fields; assignments made by hand stay untouched.
    @discardableResult
    static func classify(_ document: Document, context: ModelContext) async -> Outcome {
        await Log.interval("classify") { await classifyUnlogged(document, context: context) }
    }

    private static func classifyUnlogged(_ document: Document, context: ModelContext) async -> Outcome {
        var outcome = Outcome()
        let text = document.title + "\n" + document.extractedText
        var correspondents = fetchCorrespondents(context)
        let types = (try? context.fetch(FetchDescriptor<DocumentType>())) ?? []
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let dateIsUntouched = Calendar.current.isDate(document.documentDate, inSameDayAs: document.createdAt)

        // 1. Correspondent through rules
        if document.correspondent == nil, let match = bestMatch(in: correspondents, text: text) {
            document.correspondent = match
            outcome.changes.append(String(localized: "Correspondent: \(match.name)"))
        }

        // 2. Mistral
        let environment = ProcessingEnvironment.current
        if let config = environment.mistralConfig(), config.useLLM, !document.extractedText.isEmpty {
            do {
                let suggestion = try await MistralClient(config: config, environment: environment).classify(
                    text: document.extractedText,
                    fileName: document.originalFileName,
                    correspondents: correspondents.map(\.name),
                    documentTypes: types.map(\.name),
                    tags: TagHierarchy.sortedByPath(tags).map(TagHierarchy.displayPath(of:))
                )
                guard !document.isDeleted else { return outcome }
                outcome.usedAI = true
                // While waiting for Mistral, documents imported in parallel may have created
                // correspondents, so reload the list; otherwise duplicates appear.
                correspondents = fetchCorrespondents(context)
                if document.correspondent == nil, let match = bestMatch(in: correspondents, text: text) {
                    document.correspondent = match
                    outcome.changes.append(String(localized: "Correspondent: \(match.name)"))
                }
                apply(suggestion, to: document, correspondents: correspondents, types: types, tags: tags,
                      dateIsUntouched: dateIsUntouched, context: context, outcome: &outcome)
            } catch {
                Log.mistral.error("Classification failed, using the local rules: \(Log.code(of: error), privacy: .public)")
                outcome.aiError = error.localizedDescription
            }
        }

        // 3. Rules for type and tags
        if document.documentType == nil, let match = bestMatch(in: types, text: text) {
            document.documentType = match
            outcome.changes.append(String(localized: "Document type: \(match.name)"))
        }
        for tag in tags where tag.matches(text: text) && !document.hasTag(tag) {
            document.toggleTag(tag)
            outcome.changes.append(String(localized: "Tag: \(tag.name)"))
        }

        // 4. Heuristics
        correspondents = fetchCorrespondents(context)
        if document.correspondent == nil, autoCreateCorrespondents,
           let detected = SenderDetector.detect(in: document.extractedText) {
            let (correspondent, isNew) = findOrCreateCorrespondent(named: detected.name, matchText: detected.matchText,
                                                                   among: correspondents, context: context)
            document.correspondent = correspondent
            outcome.changes.append(isNew ? String(localized: "New correspondent: \(correspondent.name)")
                                         : String(localized: "Correspondent: \(correspondent.name)"))
        }
        if dateIsUntouched, Calendar.current.isDate(document.documentDate, inSameDayAs: document.createdAt),
           let date = DateDetector.firstDate(in: document.extractedText),
           !Calendar.current.isDate(date, inSameDayAs: document.documentDate) {
            document.documentDate = date
            outcome.changes.append(String(localized: "Date: \(date.formatted(date: .long, time: .omitted))"))
        }
        // Scans without an AI title get "Type Correspondent" instead of "Scan 15.10.2026 …"
        if document.source != .file, document.hasAutomaticTitle {
            let parts = [document.documentType?.name, document.correspondent?.name].compactMap { $0 }
            if !parts.isEmpty {
                document.title = parts.joined(separator: " ")
                outcome.changes.append(String(localized: "Title: \(document.title)"))
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
                outcome.changes.append(String(localized: "Correspondent (AI): \(existing.name)"))
            } else if autoCreateCorrespondents {
                let (created, _) = findOrCreateCorrespondent(named: name, matchText: core, among: correspondents, context: context)
                document.correspondent = created
                outcome.changes.append(String(localized: "New correspondent (AI): \(created.name)"))
            }
        }
        if document.documentType == nil, let name = suggestion.documentType,
           let type = types.first(where: { sameName($0.name, name) }) {
            document.documentType = type
            outcome.changes.append(String(localized: "Document type (AI): \(type.name)"))
        }
        let byPath = tagsByPath(tags)
        for name in suggestion.tags ?? [] {
            if let tag = tag(forSuggested: name, byPath: byPath, among: tags), !document.hasTag(tag) {
                document.toggleTag(tag)
                outcome.changes.append(String(localized: "Tag (AI): \(tag.name)"))
            }
        }
        if dateIsUntouched, let date = suggestion.parsedDate,
           !Calendar.current.isDate(date, inSameDayAs: document.documentDate) {
            document.documentDate = date
            outcome.changes.append(String(localized: "Date (AI): \(date.formatted(date: .long, time: .omitted))"))
        }
        if document.hasAutomaticTitle, let title = suggestion.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, title != document.title {
            document.title = String(title.prefix(120))
            outcome.changes.append(String(localized: "Title (AI): \(document.title)"))
        }
    }

    /// Tags by normalized display path. Two tags can share a path (duplicates before a merge, or a
    /// tag literally named "Auto › Golf"); the oldest wins (`createdAt`, then `id`), never a crash.
    static func tagsByPath(_ tags: [Tag]) -> [String: Tag] {
        let ordered = MetadataMaintenance.keeperOrder(tags, createdAt: \.createdAt, id: \.id)
        return Dictionary(ordered.map { (pathKey(TagHierarchy.displayPath(of: $0)), $0) },
                          uniquingKeysWith: { oldest, _ in oldest })
    }

    /// A suggested tag: by its path, otherwise by its last name when exactly one tag has that name.
    static func tag(forSuggested suggestion: String, byPath: [String: Tag], among tags: [Tag]) -> Tag? {
        if let tag = byPath[pathKey(suggestion)] { return tag }
        let leaf = suggestion.components(separatedBy: TagHierarchy.separator.trimmingCharacters(in: .whitespaces))
            .last?.trimmingCharacters(in: .whitespaces) ?? suggestion
        let named = tags.filter { sameName($0.name, leaf) }
        return named.count == 1 ? named[0] : nil
    }

    private static func pathKey(_ path: String) -> String {
        path.components(separatedBy: TagHierarchy.separator.trimmingCharacters(in: .whitespaces))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: TagHierarchy.separator)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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

    /// With several matches, the rule with the most matching words wins.
    private static func bestMatch<T: MatchingRule>(in rules: [T], text: String) -> T? {
        rules.map { ($0, $0.matchScore(text: text)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}

/// Detects the sender of a document when no matching correspondent exists yet.
/// 1. A line with a legal form (GmbH, AG, Inc., PBC, …) outside the recipient block
/// 2. Otherwise the domain of the first business e-mail or web address
enum SenderDetector {
    struct Sender: Equatable {
        var name: String
        /// Name without the legal form; used as the exact match phrase for future documents
        var matchText: String
    }

    private static let legalForm = #"(?:GmbH\s*&\s*Co\.?\s*KG(?:aA)?|gGmbH|GmbH|mbH|AG|SE|KGaA|KG|OHG|UG(?:\s*\(haftungsbeschränkt\))?|GbR|e\.\s?V\.|eG|Inc\.?|LLC|L\.L\.C\.|Ltd\.?|Limited|PBC|Corp\.?|Corporation|PLC|plc|S\.A\.|SA|S\.?A\.?R\.?L\.?|B\.V\.|BV|N\.V\.|AB|ApS|A/S|Oy|S\.p\.A\.|S\.r\.l\.)"#

    /// Keywords followed by the recipient's address; those lines are not the sender.
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
                skipUntil = index + 5 // skip the recipient block (name and address)
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

    /// "Anthropic, PBC @anthropic" → "Anthropic, PBC"
    static func companyName(in line: String) -> String? {
        let pattern = #"^([\p{L}\p{N}][\p{L}\p{N}&.,'’\- ]{1,60}?[,\s]\s*"# + legalForm + #")(?=$|[\s,;·|•/@()])"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let name = String(line[range]).trimmingCharacters(in: .whitespaces)
        // Skip lines such as "Sitz der Gesellschaft …" (registered office) or bank details
        let lower = name.lowercased()
        let excluded = ["sitz", "registergericht", "amtsgericht", "geschäftsführ", "bank", "iban", "vat", "ust"]
        guard !excluded.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return name
    }

    /// Name without the legal form: "Stadtwerke München GmbH" → "Stadtwerke München"
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

/// Finds the first plausible date in a German or English text.
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

    // Swift Regex has no lookbehind, hence the group `(?:^|…)` as a precondition
    private static let numeric = /(?:^|[^\d.])(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})(?!\d)/
    private static let iso = /(?:^|\D)(\d{4})-(\d{2})-(\d{2})(?!\d)/
    private static let written = /(?i)(?:^|\D)(\d{1,2})\.?\s+([a-zäöü]{3,9})\.?\s+(\d{4})(?!\d)/
    /// English: "October 3, 2026" or "Oct 3 2026"
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
              date <= Date().addingTimeInterval(60 * 60 * 24 * 365) // at most one year in the future
        else { return nil }
        return date
    }
}
