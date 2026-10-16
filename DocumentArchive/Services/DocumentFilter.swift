import Foundation
import SwiftData
import Synchronization

/// The criteria of a saved view (#14): tags, correspondents, types, a date range, status flags, a
/// search term and the sort order. No SwiftData dependency: it is stored as JSON in
/// `SavedView.filterJSON` (maintainer decision) and evaluated against a `FilterContext`.
///
/// **Compatibility with other app versions**
/// - Decoding never fails as a whole: each field is decoded on its own, and a field that cannot be
///   decoded (a sort or date range of a newer version) falls back to its default and is listed in
///   `fallbackKeys`. Writing (`json(_:preserving:)`) then keeps the stored raw value unless the
///   field was changed, and keeps keys this version does not know.
/// - References store the id, the name and the normalized merge key (`Ref`). An id that no longer
///   exists (merged by a version without `SavedViewMaintenance`, deleted on another device) is
///   resolved by key; a reference that still cannot be resolved makes its criterion match nothing
///   (an excluded tag is skipped) and sets `FilterContext.hasUnresolvedReferences`. A view is
///   never broadened by a reference this version cannot resolve.
/// - Absolute date ranges are calendar days, compared in the device's calendar.
///
/// The filter works on the list it is given (after any central exclusion, #22); it never fetches
/// documents itself.
struct DocumentFilter: Equatable, Sendable {
    // Setting a field (even to the value it has) marks it as changed by the user: it leaves
    // `fallbackKeys`, so a value of a newer version is replaced, also by this version's default.
    var tags: [Ref] = [] { didSet { touch(.tags) } }
    var tagMode: TagMode = .any { didSet { touch(.tagMode) } }
    /// Whether a tag also matches the tags nested in it. Applies to `excludedTags` as well:
    /// excluding a parent excludes its children.
    var includeSubTags = true { didSet { touch(.includeSubTags) } }
    var excludedTags: [Ref] = [] { didSet { touch(.excludedTags) } }
    /// Any of them.
    var correspondents: [Ref] = [] { didSet { touch(.correspondents) } }
    /// Any of them.
    var documentTypes: [Ref] = [] { didSet { touch(.documentTypes) } }
    var dateField: DateField = .documentDate { didSet { touch(.dateField) } }
    var dateRange: DateRange? { didSet { touch(.dateRange) } }
    /// `nil`: either.
    var inbox: Bool? { didSet { touch(.inbox) } }
    var favorite: Bool? { didSet { touch(.favorite) } }
    var hasASN: Bool? { didSet { touch(.hasASN) } }
    /// Full-text search, the same as the search field (`Document.matches`).
    var query = "" { didSet { touch(.query) } }
    var sort: DocumentSort = .added { didSet { touch(.sort) } }
    var ascending = false { didSet { touch(.ascending) } }

    /// Keys whose stored value could not be decoded (a newer version's value) and that were not
    /// set since. Not encoded. `json(_:preserving:)` keeps the stored raw value of these keys.
    var fallbackKeys: Set<String> = []

    private mutating func touch(_ key: CodingKeys) {
        if !fallbackKeys.isEmpty { fallbackKeys.remove(key.stringValue) }
    }

    var isEmpty: Bool { self == DocumentFilter() }

    // MARK: Types

    /// A tag, correspondent or document type, by id with its name and normalized merge key.
    struct Ref: Codable, Equatable, Hashable {
        var id: UUID
        /// Shown for a reference that can no longer be resolved ("Steuer" (deleted)).
        var name: String
        /// Resolves the reference when the id is gone: the key `MetadataMaintenance` merges
        /// duplicates by (`Ref.key(for:)`).
        var key: String

        init(id: UUID, name: String, key: String) {
            self.id = id
            self.name = name
            self.key = key
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
            key = (try? container.decodeIfPresent(String.self, forKey: .key)) ?? ""
        }
    }

    enum TagMode: String, Codable, CaseIterable {
        case any, all
    }

    enum DateField: String, Codable, CaseIterable {
        case documentDate, createdAt
    }

    /// The calendar days are counted in: always Gregorian (a `"yyyy-MM-dd"` day must mean the same
    /// date on a device set to the Japanese or Buddhist calendar), in the time zone of `calendar`
    /// (the device's), so a day is still the day the user sees on this device.
    static func dayCalendar(_ calendar: Calendar = .current) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// A calendar day, stored as `"yyyy-MM-dd"` in the Gregorian calendar. The same day on every
    /// device, whatever its time zone or calendar.
    struct Day: Codable, Equatable, Hashable, Comparable {
        var year: Int
        var month: Int
        var day: Int

        init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// The day `date` falls on in the time zone of `calendar` (the device's), counted in the
        /// Gregorian calendar (`dayCalendar`), whatever calendar the device uses.
        init(_ date: Date, calendar: Calendar = .current) {
            let parts = DocumentFilter.dayCalendar(calendar).dateComponents([.year, .month, .day], from: date)
            self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        }

        /// Noon of the day in the time zone of `calendar`, for date pickers.
        func date(calendar: Calendar = .current) -> Date {
            DocumentFilter.dayCalendar(calendar).date(from: DateComponents(year: year, month: month, day: day, hour: 12))
                ?? Date()
        }

        init?(_ string: String) {
            let parts = string.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
            self.init(year: year, month: month, day: day)
        }

        var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let day = Day(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day \(text)")
            }
            self = day
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(string)
        }

        static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    /// Stored as `{"kind": "absolute", "from": "2026-01-01", "to": "2026-12-31"}`,
    /// `{"kind": "year", "year": 2025}` or `{"kind": "thisYear"}`. An unknown kind fails to decode
    /// and the filter falls back to no date range (keeping the stored value).
    enum DateRange: Codable, Equatable, Hashable {
        /// Both bounds inclusive; `nil` is open.
        case absolute(from: Day?, to: Day?)
        case thisYear
        case lastYear
        /// Today and the 29 days before it.
        case last30Days
        /// Today and the days back to (excluding) the same day 12 months ago.
        case last12Months
        case year(Int)

        private enum CodingKeys: String, CodingKey { case kind, from, to, year }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "absolute":
                self = .absolute(from: try container.decodeIfPresent(Day.self, forKey: .from),
                                 to: try container.decodeIfPresent(Day.self, forKey: .to))
            case "thisYear": self = .thisYear
            case "lastYear": self = .lastYear
            case "last30Days": self = .last30Days
            case "last12Months": self = .last12Months
            case "year": self = .year(try container.decode(Int.self, forKey: .year))
            case let kind:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                       debugDescription: "Unknown date range \(kind)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .absolute(let from, let to):
                try container.encode("absolute", forKey: .kind)
                try container.encodeIfPresent(from, forKey: .from)
                try container.encodeIfPresent(to, forKey: .to)
            case .thisYear: try container.encode("thisYear", forKey: .kind)
            case .lastYear: try container.encode("lastYear", forKey: .kind)
            case .last30Days: try container.encode("last30Days", forKey: .kind)
            case .last12Months: try container.encode("last12Months", forKey: .kind)
            case .year(let year):
                try container.encode("year", forKey: .kind)
                try container.encode(year, forKey: .year)
            }
        }

        /// The first and last day of the range (inclusive), relative to `today`. Days are counted in
        /// the Gregorian calendar (`dayCalendar`), whatever calendar is passed in.
        func bounds(today: Day, calendar: Calendar) -> (from: Day?, to: Day?) {
            let calendar = DocumentFilter.dayCalendar(calendar)
            func shifted(_ component: Calendar.Component, by value: Int) -> Day {
                let start = calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day))
                    ?? Date()
                let date = calendar.date(byAdding: component, value: value, to: start) ?? start
                return Day(date, calendar: calendar)
            }
            switch self {
            case .absolute(let from, let to):
                return (from, to)
            case .thisYear:
                return (Day(year: today.year, month: 1, day: 1), Day(year: today.year, month: 12, day: 31))
            case .lastYear:
                return (Day(year: today.year - 1, month: 1, day: 1), Day(year: today.year - 1, month: 12, day: 31))
            case .year(let year):
                return (Day(year: year, month: 1, day: 1), Day(year: year, month: 12, day: 31))
            case .last30Days:
                return (shifted(.day, by: -29), today)
            case .last12Months:
                let yearAgo = calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day))
                    .flatMap { calendar.date(byAdding: .month, value: -12, to: $0) }
                    .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
                return (yearAgo.map { Day($0, calendar: calendar) } ?? shifted(.year, by: -1), today)
            }
        }
    }

    // MARK: Matching

    /// Whether the document passes every criterion. `context` must be built for this filter.
    func matches(_ document: Document, context: FilterContext) -> Bool {
        guard document.isAlive else { return false }
        let tagIDs = Set((document.tags ?? []).filter { !$0.isDeleted }.map(\.id))
        if let required = context.requiredTags {
            // `nil` sets: an unresolved reference makes the criterion match nothing.
            guard let sets = required else { return false }
            let matched = tagMode == .any ? sets.contains { !$0.isDisjoint(with: tagIDs) }
                                          : sets.allSatisfy { !$0.isDisjoint(with: tagIDs) }
            guard matched else { return false }
        }
        if !context.excludedTagIDs.isDisjoint(with: tagIDs) { return false }
        if let allowed = context.correspondentIDs {
            guard let ids = allowed, let id = document.correspondent?.id, ids.contains(id) else { return false }
        }
        if let allowed = context.documentTypeIDs {
            guard let ids = allowed, let id = document.documentType?.id, ids.contains(id) else { return false }
        }
        if let bounds = context.dateBounds {
            let date = dateField == .documentDate ? document.documentDate : document.createdAt
            let day = Day(date, calendar: context.calendar)
            if let from = bounds.from, day < from { return false }
            if let to = bounds.to, to < day { return false }
        }
        if let inbox, document.isInbox != inbox { return false }
        if let favorite, document.isFavorite != favorite { return false }
        if let hasASN, (document.archiveSerialNumber != nil) != hasASN { return false }
        return document.matches(query)
    }

    /// The documents that match, in the filter's sort order. `documents` is the base list (after
    /// the central exclusions); nothing is fetched.
    func apply(to documents: [Document], context: FilterContext) -> [Document] {
        sort.sort(documents.filter { matches($0, context: context) }, ascending: ascending)
    }
}

// MARK: - Context

/// Everything a filter needs besides the documents, built once per view and render: `now`, the
/// calendar, the date bounds, and the references resolved to live ids (tag subtrees included).
struct FilterContext {
    let now: Date
    /// Gregorian, in the device's time zone (`DocumentFilter.dayCalendar`).
    let calendar: Calendar
    /// The date range's first and last day (inclusive), computed once; `nil`: no date criterion.
    let dateBounds: (from: DocumentFilter.Day?, to: DocumentFilter.Day?)?
    /// `nil`: no tag criterion. `.some(nil)`: a reference could not be resolved (matches nothing).
    /// Otherwise one id set per referenced tag (with its subtree when `includeSubTags`).
    let requiredTags: [Set<UUID>]??
    /// Resolved excluded tags with their subtrees; unresolved ones are skipped.
    let excludedTagIDs: Set<UUID>
    let correspondentIDs: Set<UUID>??
    let documentTypeIDs: Set<UUID>??
    /// Drives the banner "This view refers to deleted items".
    let hasUnresolvedReferences: Bool
    /// The references that could not be resolved, for the editor ("(deleted)").
    let unresolved: Set<UUID>

    /// - Parameters:
    ///   - tags, correspondents, documentTypes: the live objects (deleted ones are ignored); only
    ///     the kinds the filter refers to are used.
    ///   - calendar: the device's calendar; only its time zone is used (`DocumentFilter.dayCalendar`).
    @MainActor
    init(filter: DocumentFilter, tags: [Tag], correspondents: [Correspondent], documentTypes: [DocumentType],
         now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        let calendar = DocumentFilter.dayCalendar(calendar)
        self.calendar = calendar
        dateBounds = filter.dateRange.map { $0.bounds(today: DocumentFilter.Day(now, calendar: calendar), calendar: calendar) }
        var unresolved = Set<UUID>()

        // Keys (tag paths) are computed only for the kinds the filter refers to.
        let liveTags = filter.tags.isEmpty && filter.excludedTags.isEmpty ? [] : tags.filter { !$0.isDeleted }
        let tagResolver = Resolver(liveTags, id: \.id, createdAt: \.createdAt, key: DocumentFilter.Ref.key(for:))
        func tagSet(_ ref: DocumentFilter.Ref) -> Set<UUID>? {
            guard let tag = tagResolver.resolve(ref) else {
                unresolved.insert(ref.id)
                return nil
            }
            return filter.includeSubTags ? TagHierarchy.subtreeIDs(of: tag) : [tag.id]
        }

        if filter.tags.isEmpty && !filter.fallbackKeys.contains("tags") {
            requiredTags = .none
        } else {
            let sets = filter.tags.map(tagSet)
            let complete = !filter.fallbackKeys.contains("tags") && !sets.contains { $0 == nil }
            requiredTags = .some(complete ? sets.compactMap { $0 } : nil)
        }
        excludedTagIDs = filter.excludedTags.compactMap(tagSet).reduce(into: Set<UUID>()) { $0.formUnion($1) }

        func ids<T>(_ refs: [DocumentFilter.Ref], fieldKey: String, resolver: Resolver<T>,
                    id: (T) -> UUID) -> Set<UUID>?? {
            if refs.isEmpty && !filter.fallbackKeys.contains(fieldKey) { return .none }
            var result = Set<UUID>()
            var complete = !filter.fallbackKeys.contains(fieldKey)
            for ref in refs {
                if let object = resolver.resolve(ref) {
                    result.insert(id(object))
                } else {
                    unresolved.insert(ref.id)
                    complete = false
                }
            }
            return .some(complete ? result : nil)
        }
        correspondentIDs = ids(filter.correspondents, fieldKey: "correspondents",
                               resolver: Resolver(filter.correspondents.isEmpty ? [] : correspondents.filter { !$0.isDeleted }, id: \.id,
                                                  createdAt: \.createdAt, key: DocumentFilter.Ref.key(for:)),
                               id: \.id)
        documentTypeIDs = ids(filter.documentTypes, fieldKey: "documentTypes",
                              resolver: Resolver(filter.documentTypes.isEmpty ? [] : documentTypes.filter { !$0.isDeleted }, id: \.id,
                                                 createdAt: \.createdAt, key: DocumentFilter.Ref.key(for:)),
                              id: \.id)

        self.unresolved = unresolved
        let undecodableReferences = !filter.fallbackKeys.isDisjoint(with: DocumentFilter.referenceKeys)
        hasUnresolvedReferences = !unresolved.isEmpty || undecodableReferences
    }

    /// Fetches only the kinds the filter refers to (tags, correspondents, types) from
    /// `modelContext`, never the documents.
    @MainActor
    init(filter: DocumentFilter, in modelContext: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        func fetch<T: PersistentModel>(_ type: T.Type, if needed: Bool) -> [T] {
            needed ? (try? modelContext.fetch(FetchDescriptor<T>())) ?? [] : []
        }
        self.init(filter: filter,
                  tags: fetch(Tag.self, if: !filter.tags.isEmpty || !filter.excludedTags.isEmpty),
                  correspondents: fetch(Correspondent.self, if: !filter.correspondents.isEmpty),
                  documentTypes: fetch(DocumentType.self, if: !filter.documentTypes.isEmpty),
                  now: now, calendar: calendar)
    }

    /// Resolution order: id → normalized key (the oldest object wins, like merges) → unresolved.
    fileprivate struct Resolver<T> {
        let byID: [UUID: T]
        let byKey: [String: T]

        @MainActor
        init(_ objects: [T], id: (T) -> UUID, createdAt: (T) -> Date, key: (T) -> String) {
            var byID: [UUID: T] = [:]
            var byKey: [String: T] = [:]
            for object in MetadataMaintenance.keeperOrder(objects, createdAt: createdAt, id: id) {
                byID[id(object)] = object
                let k = key(object)
                if !k.isEmpty, byKey[k] == nil { byKey[k] = object }
            }
            self.byID = byID
            self.byKey = byKey
        }

        func resolve(_ ref: DocumentFilter.Ref) -> T? {
            byID[ref.id] ?? (ref.key.isEmpty ? nil : byKey[ref.key])
        }
    }
}

// MARK: - Editing

extension DocumentFilter {
    /// For the editor: every reference that resolves (by id or by key) is replaced by the live
    /// object's current id, name and key, so the pickers show it as chosen. References that do not
    /// resolve stay as they are (shown as deleted, removed only by the user). A field is set only
    /// when something changed, so a newer version's value in an untouched field is kept.
    @MainActor
    func resolvingReferences(tags: [Tag], correspondents: [Correspondent], documentTypes: [DocumentType]) -> DocumentFilter {
        var result = self
        let tagResolver = FilterContext.Resolver(tags.filter { !$0.isDeleted }, id: \.id, createdAt: \.createdAt,
                                                 key: Ref.key(for:))
        let correspondentResolver = FilterContext.Resolver(correspondents.filter { !$0.isDeleted }, id: \.id,
                                                           createdAt: \.createdAt, key: Ref.key(for:))
        let typeResolver = FilterContext.Resolver(documentTypes.filter { !$0.isDeleted }, id: \.id,
                                                  createdAt: \.createdAt, key: Ref.key(for:))
        func live<T>(_ refs: [Ref], _ resolver: FilterContext.Resolver<T>, _ makeRef: (T) -> Ref) -> [Ref] {
            var seen = Set<UUID>()
            return refs.map { ref in resolver.resolve(ref).map(makeRef) ?? ref }.filter { seen.insert($0.id).inserted }
        }
        let tagRefs = live(self.tags, tagResolver, Ref.init(_:) as (Tag) -> Ref)
        if tagRefs != self.tags { result.tags = tagRefs }
        let excluded = live(excludedTags, tagResolver, Ref.init(_:) as (Tag) -> Ref)
        if excluded != excludedTags { result.excludedTags = excluded }
        let correspondentRefs = live(self.correspondents, correspondentResolver, Ref.init(_:) as (Correspondent) -> Ref)
        if correspondentRefs != self.correspondents { result.correspondents = correspondentRefs }
        let typeRefs = live(self.documentTypes, typeResolver, Ref.init(_:) as (DocumentType) -> Ref)
        if typeRefs != self.documentTypes { result.documentTypes = typeRefs }
        return result
    }
}

// MARK: - References

extension DocumentFilter.Ref {
    @MainActor init(_ tag: Tag) {
        self.init(id: tag.id, name: tag.name, key: Self.key(for: tag))
    }

    @MainActor init(_ correspondent: Correspondent) {
        self.init(id: correspondent.id, name: correspondent.name, key: Self.key(for: correspondent))
    }

    @MainActor init(_ type: DocumentType) {
        self.init(id: type.id, name: type.name, key: Self.key(for: type))
    }

    /// The parent path and the name, normalized: "auto › golf". A tag moved to another parent
    /// gets a new key, so a reference to it that lost its id stays unresolved (never broadened).
    @MainActor static func key(for tag: Tag) -> String {
        TagHierarchy.path(of: tag).map { MetadataMaintenance.normalized($0.name) }.joined(separator: TagHierarchy.separator)
    }

    /// The normalized core name ("Telekom Deutschland GmbH" → "telekom deutschland"), the key
    /// `mergeDuplicates` merges correspondents by.
    @MainActor static func key(for correspondent: Correspondent) -> String {
        MetadataMaintenance.normalized(SenderDetector.coreName(correspondent.name))
    }

    @MainActor static func key(for type: DocumentType) -> String {
        MetadataMaintenance.normalized(type.name)
    }
}

// MARK: - JSON

extension DocumentFilter: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case tags, tagMode, includeSubTags, excludedTags, correspondents, documentTypes
        case dateField, dateRange, inbox, favorite, hasASN, query, sort, ascending
    }

    /// The keys this version writes. Every other key in stored JSON belongs to a newer version.
    static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
    /// Keys holding references; one that cannot be decoded counts as unresolved.
    static let referenceKeys: Set<String> = ["tags", "excludedTags", "correspondents", "documentTypes"]

    /// Decodes each field on its own; a field that fails keeps its default and is recorded in
    /// `fallbackKeys`. A missing key is simply the default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var fallbacks = Set<String>()
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            guard container.contains(key) else { return fallback }
            if (try? container.decodeNil(forKey: key)) == true { return fallback }
            if let value = try? container.decode(T.self, forKey: key) { return value }
            fallbacks.insert(key.stringValue)
            return fallback
        }
        self.init()
        tags = field(.tags, [])
        tagMode = field(.tagMode, .any)
        includeSubTags = field(.includeSubTags, true)
        excludedTags = field(.excludedTags, [])
        correspondents = field(.correspondents, [])
        documentTypes = field(.documentTypes, [])
        dateField = field(.dateField, .documentDate)
        dateRange = field(.dateRange, nil as DateRange?)
        inbox = field(.inbox, nil as Bool?)
        favorite = field(.favorite, nil as Bool?)
        hasASN = field(.hasASN, nil as Bool?)
        query = field(.query, "")
        sort = field(.sort, .added)
        ascending = field(.ascending, false)
        fallbackKeys = fallbacks
    }

    /// `nil` optionals are left out, so clearing a field removes its key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tags, forKey: .tags)
        try container.encode(tagMode, forKey: .tagMode)
        try container.encode(includeSubTags, forKey: .includeSubTags)
        try container.encode(excludedTags, forKey: .excludedTags)
        try container.encode(correspondents, forKey: .correspondents)
        try container.encode(documentTypes, forKey: .documentTypes)
        try container.encode(dateField, forKey: .dateField)
        try container.encodeIfPresent(dateRange, forKey: .dateRange)
        try container.encodeIfPresent(inbox, forKey: .inbox)
        try container.encodeIfPresent(favorite, forKey: .favorite)
        try container.encodeIfPresent(hasASN, forKey: .hasASN)
        try container.encode(query, forKey: .query)
        try container.encode(sort, forKey: .sort)
        try container.encode(ascending, forKey: .ascending)
    }

    /// Never fails: invalid JSON or a non-object gives the empty filter.
    static func decode(_ json: String) -> DocumentFilter {
        (try? JSONDecoder().decode(DocumentFilter.self, from: Data(json.utf8))) ?? DocumentFilter()
    }

    /// The JSON to store for `filter`, on top of the stored `existing` JSON:
    /// - every key this version knows is replaced by the new encoding, and removed when the new
    ///   encoding leaves it out (a cleared field);
    /// - keys this version does not know are kept;
    /// - a field that fell back when `existing` was decoded keeps its stored raw value while it
    ///   is still in `filter.fallbackKeys`, that is, until the field is set. Setting it replaces
    ///   the raw value, also with the value the field fell back to (the user chose "Added" for a
    ///   newer version's sort, or cleared its date range). A filter built from scratch has no
    ///   fallback keys and replaces every field.
    ///
    /// Sorted keys, so equal content gives an equal string.
    static func json(_ filter: DocumentFilter, preserving existing: String) -> String {
        let stored = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any] ?? [:]
        let new = object(filter)
        var result = stored.filter { !knownKeys.contains($0.key) }
        for (key, value) in new { result[key] = value }
        for key in filter.fallbackKeys {
            if let raw = stored[key] { result[key] = raw }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else { return existing }
        return string
    }

    private static func object(_ filter: DocumentFilter) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(filter) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

// MARK: - Decode cache

/// Decoded filters by `filterJSON` string, so a sidebar render decodes each view once and not once
/// per document. Thread-safe (`Mutex`). `shared` is the only instance the views use.
///
/// Holds at most `limit` entries. When it is full, it removes **everything** before adding the
/// next one; unlike `NSCache`, which it replaced, it has no other eviction (`NSCache` gave no
/// ordering either). Saved views are few, so this only happens with many changed filters.
final class DocumentFilterCache: Sendable {
    static let shared = DocumentFilterCache()

    /// One decoded filter; the same instance for the same JSON while it is cached.
    final class Entry: Sendable {
        let filter: DocumentFilter
        init(_ filter: DocumentFilter) { self.filter = filter }
    }

    static let limit = 500

    private let entries = Mutex<[String: Entry]>([:])

    func entry(for json: String) -> Entry {
        if let entry = entries.withLock({ $0[json] }) { return entry }
        // Decoded outside the lock; when two callers race, the first stored entry wins.
        let decoded = Entry(DocumentFilter.decode(json))
        return entries.withLock { entries in
            if let entry = entries[json] { return entry }
            if entries.count >= Self.limit { entries.removeAll() }
            entries[json] = decoded
            return decoded
        }
    }

    func filter(for json: String) -> DocumentFilter {
        entry(for: json).filter
    }

    /// The number of cached entries (for tests).
    var count: Int { entries.withLock { $0.count } }
}
