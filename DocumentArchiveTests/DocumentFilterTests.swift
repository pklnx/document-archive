import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Saved-view filters (#14): every criterion, date ranges, references, sort and the JSON rules.
/// In-memory store, a fixed `now` and a fixed calendar (Europe/Berlin).
@Suite @MainActor struct DocumentFilterTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    let berlin = Self.calendar("Europe/Berlin")
    /// Sunday, 15 March 2026, 10:00 in Berlin.
    var now: Date { at(2026, 3, 15, hour: 10) }

    init() throws {
        container = try TestSupport.makeContainer()
    }

    // MARK: Helpers

    func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar? = nil) -> Date {
        (calendar ?? berlin).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    func document(_ title: String, tags: [ArchiveTag] = [], correspondent: Correspondent? = nil,
                  type: DocumentType? = nil, date: Date? = nil, createdAt: Date? = nil, inbox: Bool = false,
                  favorite: Bool = false, asn: Int? = nil, text: String = "") -> Document {
        let document = Document(title: title, pdfData: Data(title.utf8), source: .file)
        document.isProcessing = false
        context.insert(document)
        document.tags = tags
        document.correspondent = correspondent
        document.documentType = type
        document.documentDate = date ?? at(2026, 2, 1)
        document.createdAt = createdAt ?? at(2026, 2, 1)
        document.isInbox = inbox
        document.isFavorite = favorite
        document.archiveSerialNumber = asn
        document.extractedText = text
        return document
    }

    func tag(_ name: String, under parent: ArchiveTag? = nil, createdAt: Date = .distantPast) -> ArchiveTag {
        let tag = ArchiveTag(name: name)
        tag.createdAt = createdAt
        context.insert(tag)
        tag.parent = parent
        return tag
    }

    func allDocuments() throws -> [Document] {
        try context.fetch(FetchDescriptor<Document>()).filter(\.isAlive)
    }

    func filterContext(_ filter: DocumentFilter, calendar: Calendar? = nil) -> FilterContext {
        FilterContext(filter: filter, in: context, now: now, calendar: calendar ?? berlin)
    }

    /// Titles of the matching documents, sorted by title.
    func titles(_ filter: DocumentFilter, calendar: Calendar? = nil) throws -> [String] {
        let filterContext = filterContext(filter, calendar: calendar)
        return try allDocuments().filter { filter.matches($0, context: filterContext) }.map(\.title).sorted()
    }

    static func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: Criteria

    @Test func tagsAnyAndAll() throws {
        let tax = tag("Tax")
        let home = tag("Home")
        document("Both", tags: [tax, home])
        document("Tax only", tags: [tax])
        document("Home only", tags: [home])
        document("None")

        var filter = DocumentFilter()
        filter.tags = [.init(tax), .init(home)]
        #expect(try titles(filter) == ["Both", "Home only", "Tax only"])
        filter.tagMode = .all
        #expect(try titles(filter) == ["Both"])
    }

    @Test func excludedTagsAreLeftOut() throws {
        let tax = tag("Tax")
        let done = tag("Done")
        document("Open", tags: [tax])
        document("Closed", tags: [tax, done])
        var filter = DocumentFilter()
        filter.tags = [.init(tax)]
        filter.excludedTags = [.init(done)]
        #expect(try titles(filter) == ["Open"])
    }

    @Test func correspondentsAndTypesMatchAnyOfThem() throws {
        let telekom = Correspondent(name: "Telekom")
        let vodafone = Correspondent(name: "Vodafone")
        let stadtwerke = Correspondent(name: "Stadtwerke")
        let invoice = DocumentType(name: "Invoice")
        let contract = DocumentType(name: "Contract")
        [telekom, vodafone, stadtwerke].forEach(context.insert)
        [invoice, contract].forEach(context.insert)
        document("T invoice", correspondent: telekom, type: invoice)
        document("V contract", correspondent: vodafone, type: contract)
        document("S invoice", correspondent: stadtwerke, type: invoice)
        document("Nothing")

        var filter = DocumentFilter()
        filter.correspondents = [.init(telekom), .init(vodafone)]
        #expect(try titles(filter) == ["T invoice", "V contract"])
        filter = DocumentFilter()
        filter.documentTypes = [.init(invoice)]
        #expect(try titles(filter) == ["S invoice", "T invoice"])
    }

    @Test func inboxTrueFalseAndEither() throws {
        document("New", inbox: true)
        document("Done", inbox: false)
        var filter = DocumentFilter()
        #expect(try titles(filter) == ["Done", "New"])
        filter.inbox = true
        #expect(try titles(filter) == ["New"])
        filter.inbox = false
        #expect(try titles(filter) == ["Done"])
    }

    @Test func favoriteAndASN() throws {
        document("Star", favorite: true)
        document("Numbered", asn: 12)
        document("Plain")
        var filter = DocumentFilter()
        filter.favorite = true
        #expect(try titles(filter) == ["Star"])
        filter.favorite = false
        #expect(try titles(filter) == ["Numbered", "Plain"])
        filter = DocumentFilter()
        filter.hasASN = true
        #expect(try titles(filter) == ["Numbered"])
        filter.hasASN = false
        #expect(try titles(filter) == ["Plain", "Star"])
    }

    @Test func queryMatchesLikeTheSearchField() throws {
        let telekom = Correspondent(name: "Telekom")
        context.insert(telekom)
        document("Bill", correspondent: telekom)
        document("Letter", text: "Ihre Telekom Rechnung")
        document("Other", text: "Stadtwerke")
        document("ASN", asn: 42)
        for query in ["telekom", "rechnung telekom", "ASN42", "", "nothing"] {
            var filter = DocumentFilter()
            filter.query = query
            let expected = try allDocuments().filter { $0.matches(query) }.map(\.title).sorted()
            #expect(try titles(filter) == expected, "query \(query)")
        }
    }

    @Test func dateFieldChoosesIssueDateOrAdded() throws {
        document("Issued 2025, added 2026", date: at(2025, 6, 1), createdAt: at(2026, 1, 5))
        document("Issued 2026, added 2026", date: at(2026, 2, 1), createdAt: at(2026, 2, 1))
        var filter = DocumentFilter()
        filter.dateRange = .year(2025)
        #expect(try titles(filter) == ["Issued 2025, added 2026"])
        filter.dateField = .createdAt
        #expect(try titles(filter).isEmpty)
        filter.dateRange = .thisYear
        #expect(try titles(filter) == ["Issued 2025, added 2026", "Issued 2026, added 2026"])
    }

    /// `now` on 1 January shortly after midnight: "this year" starts that day, "last year" is the
    /// whole previous year, "last 30 days" reaches back into December.
    @Test func relativeRangesAtYearBoundaries() throws {
        document("2024-12-31", date: at(2024, 12, 31, hour: 23))
        document("2025-01-01", date: at(2025, 1, 1, hour: 0))
        document("2025-12-02", date: at(2025, 12, 2))
        document("2025-12-03", date: at(2025, 12, 3))
        document("2025-12-31", date: at(2025, 12, 31, hour: 23))
        document("2026-01-01", date: at(2026, 1, 1, hour: 0))
        let newYear = at(2026, 1, 1, hour: 0) + 1800
        func titles(_ range: DocumentFilter.DateRange) throws -> [String] {
            var filter = DocumentFilter()
            filter.dateRange = range
            let filterContext = FilterContext(filter: filter, in: context, now: newYear, calendar: berlin)
            return try allDocuments().filter { filter.matches($0, context: filterContext) }.map(\.title).sorted()
        }
        #expect(try titles(.thisYear) == ["2026-01-01"])
        #expect(try titles(.lastYear) == ["2025-01-01", "2025-12-02", "2025-12-03", "2025-12-31"])
        #expect(try titles(.year(2024)) == ["2024-12-31"])
        #expect(try titles(.last30Days) == ["2025-12-03", "2025-12-31", "2026-01-01"])
        #expect(try titles(.last12Months) == ["2025-12-02", "2025-12-03", "2025-12-31", "2026-01-01"])
    }

    @Test func absoluteRangeIsInclusiveByDay() throws {
        document("Before", date: at(2026, 1, 9, hour: 23))
        document("First day, midnight", date: at(2026, 1, 10, hour: 0))
        document("Last day, late", date: at(2026, 1, 20, hour: 23))
        document("After", date: at(2026, 1, 21, hour: 0))
        var filter = DocumentFilter()
        filter.dateRange = .absolute(from: .init(year: 2026, month: 1, day: 10), to: .init(year: 2026, month: 1, day: 20))
        #expect(try titles(filter) == ["First day, midnight", "Last day, late"])
        filter.dateRange = .absolute(from: nil, to: .init(year: 2026, month: 1, day: 9))
        #expect(try titles(filter) == ["Before"])
        filter.dateRange = .absolute(from: .init(year: 2026, month: 1, day: 21), to: nil)
        #expect(try titles(filter) == ["After"])
    }

    /// A range picked in Berlin (days from Berlin dates) and evaluated on a device in New York
    /// gives the same documents when they are dated 12:00 local, as imports are.
    @Test func absoluteRangeSurvivesTimeZoneChange() throws {
        var saved = DocumentFilter()
        saved.dateRange = .absolute(from: .init(at(2026, 1, 10, hour: 0), calendar: berlin),
                                    to: .init(at(2026, 1, 20, hour: 0), calendar: berlin))
        let json = DocumentFilter.json(saved, preserving: "{}")
        #expect(try Self.object(json)["dateRange"] as? [String: String]
                == ["kind": "absolute", "from": "2026-01-10", "to": "2026-01-20"])
        let loaded = DocumentFilter.decode(json)

        for zone in ["Europe/Berlin", "America/New_York"] {
            let calendar = Self.calendar(zone)
            for document in try allDocuments() { DocumentDeletion.delete([document], in: context, recorder: nil) }
            for day in [9, 10, 20, 21] {
                document("Day \(day)", date: at(2026, 1, day, hour: 12, calendar: calendar))
            }
            #expect(try titles(loaded, calendar: calendar) == ["Day 10", "Day 20"], "evaluated in \(zone)")
        }
    }

    /// Follow-up from the part 1 review: on a device set to the Japanese (or Buddhist) calendar,
    /// days are still Gregorian (`"2026-03-15"`, not Reiwa year 8), `.year(2025)` means 2025, and
    /// the device's time zone still decides the day.
    @Test(arguments: [Calendar.Identifier.japanese, .buddhist])
    func daysAreGregorianOnANonGregorianDevice(_ identifier: Calendar.Identifier) throws {
        var device = Calendar(identifier: identifier)
        device.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(DocumentFilter.Day(now, calendar: device) == .init(year: 2026, month: 3, day: 15))
        #expect(DocumentFilter.Day(now, calendar: device).string == "2026-03-15")
        #expect(DocumentFilter.Day(year: 2026, month: 3, day: 15).date(calendar: device) == at(2026, 3, 15))
        // Shortly after midnight in Berlin (still the 15th in UTC) is the 16th, whatever the calendar.
        #expect(DocumentFilter.Day(at(2026, 3, 16, hour: 0) + 60, calendar: device) == .init(year: 2026, month: 3, day: 16))

        document("2025", date: at(2025, 6, 1))
        document("2026", date: at(2026, 2, 1))
        document("Last week", date: at(2026, 3, 8))
        var filter = DocumentFilter()
        filter.dateRange = .year(2025)
        #expect(try titles(filter, calendar: device) == ["2025"])
        filter.dateRange = .thisYear
        #expect(try titles(filter, calendar: device) == ["2026", "Last week"])
        filter.dateRange = .last30Days
        #expect(try titles(filter, calendar: device) == ["Last week"])
        filter.dateRange = .absolute(from: .init(year: 2026, month: 1, day: 1), to: .init(year: 2026, month: 2, day: 28))
        #expect(try titles(filter, calendar: device) == ["2026"])
        #expect(filterContext(filter, calendar: device).calendar.identifier == .gregorian)
    }

    /// The bounds are computed once per context, not per document (follow-up from the part 1 review).
    @Test func dateBoundsAreComputedOnceInTheContext() throws {
        var filter = DocumentFilter()
        #expect(filterContext(filter).dateBounds == nil)
        filter.dateRange = .last30Days
        let bounds = try #require(filterContext(filter).dateBounds)
        #expect(bounds.from == .init(year: 2026, month: 2, day: 14))
        #expect(bounds.to == .init(year: 2026, month: 3, day: 15))
        filter.dateRange = .last12Months
        let year = try #require(filterContext(filter).dateBounds)
        #expect(year.from == .init(year: 2025, month: 3, day: 16))
        #expect(year.to == .init(year: 2026, month: 3, day: 15))
    }

    /// "Rechnungen 2026 von Telekom" and "Versicherung, nicht erledigt".
    @Test func combinations() throws {
        let telekom = Correspondent(name: "Telekom")
        let vodafone = Correspondent(name: "Vodafone")
        let invoice = DocumentType(name: "Invoice")
        [telekom, vodafone].forEach(context.insert)
        context.insert(invoice)
        let insurance = tag("Versicherung")
        let car = tag("Auto", under: insurance)
        document("Telekom 2026", correspondent: telekom, type: invoice, date: at(2026, 2, 3))
        document("Telekom 2025", correspondent: telekom, type: invoice, date: at(2025, 12, 30))
        document("Vodafone 2026", correspondent: vodafone, type: invoice, date: at(2026, 1, 3))
        document("Telekom letter 2026", correspondent: telekom, date: at(2026, 1, 3))
        document("Car insurance open", tags: [car], inbox: true)
        document("Insurance done", tags: [insurance], inbox: false)
        document("Open, no insurance", inbox: true)

        var invoices = DocumentFilter()
        invoices.correspondents = [.init(telekom)]
        invoices.documentTypes = [.init(invoice)]
        invoices.dateRange = .year(2026)
        #expect(try titles(invoices) == ["Telekom 2026"])

        var insuranceOpen = DocumentFilter()
        insuranceOpen.tags = [.init(insurance)]
        insuranceOpen.inbox = true
        #expect(try titles(insuranceOpen) == ["Car insurance open"])
    }

    @Test func includeSubTagsOnAndOff() throws {
        let auto = tag("Auto")
        let golf = tag("Golf", under: auto)
        let workshop = tag("Werkstatt", under: golf)
        document("Auto", tags: [auto])
        document("Golf", tags: [golf])
        document("Werkstatt", tags: [workshop])
        var filter = DocumentFilter()
        filter.tags = [.init(auto)]
        #expect(try titles(filter) == ["Auto", "Golf", "Werkstatt"])
        filter.includeSubTags = false
        #expect(try titles(filter) == ["Auto"])
    }

    @Test func excludingParentExcludesChildren() throws {
        let auto = tag("Auto")
        let golf = tag("Golf", under: auto)
        let tax = tag("Steuer")
        document("Golf tax", tags: [golf, tax])
        document("Tax", tags: [tax])
        document("Auto tax", tags: [auto, tax])
        var filter = DocumentFilter()
        filter.tags = [.init(tax)]
        filter.excludedTags = [.init(auto)]
        #expect(try titles(filter) == ["Tax"])
        filter.includeSubTags = false
        #expect(try titles(filter) == ["Golf tax", "Tax"])
    }

    // MARK: Sort

    @Test func everySortMatchesTheSidebarListInBothDirections() throws {
        let a = Correspondent(name: "Allianz")
        let b = Correspondent(name: "Barmer")
        [a, b].forEach(context.insert)
        document("Charlie", correspondent: b, date: at(2026, 1, 3), createdAt: at(2026, 3, 1))
        document("alpha", correspondent: a, date: at(2026, 1, 1), createdAt: at(2026, 3, 3))
        document("Bravo", date: at(2026, 1, 2), createdAt: at(2026, 3, 2))
        document("Bravo", correspondent: a, date: at(2026, 1, 2), createdAt: at(2026, 3, 2))
        let documents = try allDocuments()

        for sort in DocumentSort.allCases {
            var filter = DocumentFilter()
            filter.sort = sort
            filter.ascending = sort.defaultAscending
            let viaFilter = filter.apply(to: documents, context: filterContext(filter)).map(\.id)
            let sidebar = SidebarItem.all.visibleDocuments(in: documents, searchText: "", sort: sort).map(\.id)
            #expect(viaFilter == sidebar, "\(sort)")
            filter.ascending.toggle()
            let reversed = filter.apply(to: documents, context: filterContext(filter)).map(\.id)
            #expect(reversed == sidebar.reversed(), "\(sort) reversed")
        }
        let byTitle = DocumentSort.title.sort(documents, ascending: true).map(\.title)
        #expect(byTitle == ["alpha", "Bravo", "Bravo", "Charlie"])
        let byDate = DocumentSort.documentDate.sort(documents, ascending: false).map(\.title)
        #expect(byDate.first == "Charlie")
        #expect(byDate.last == "alpha")
        let added = DocumentSort.added.sort(documents, ascending: false).map(\.title)
        #expect(added.first == "alpha")
    }

    // MARK: References

    /// An older app version merged "steuer" into "Steuer" without the hook: the id is gone and
    /// the reference resolves by its key.
    @Test func danglingRefResolvesByName() throws {
        let keeper = tag("Steuer", createdAt: .distantPast)
        let duplicate = tag("steuer", createdAt: Date())
        let documentOfDuplicate = document("Tax return", tags: [duplicate])
        document("Other")
        var filter = DocumentFilter()
        filter.tags = [.init(duplicate)]

        // What a version without `SavedViewMaintenance` does.
        documentOfDuplicate.tags = [keeper]
        context.delete(duplicate)
        try context.save()

        let filterContext = filterContext(filter)
        #expect(!filterContext.hasUnresolvedReferences)
        #expect(try titles(filter) == ["Tax return"])
    }

    /// Review round 2: a tag moved to another parent and then merged by an older version no
    /// longer matches the stored key. The reference stays unresolved; the view is never broadened.
    @Test func movedTagMergedByOlderVersionStaysUnresolved() throws {
        let auto = tag("Auto")
        let moved = tag("Steuer", under: auto, createdAt: Date())
        let root = tag("Steuer", createdAt: .distantPast)
        document("Tax", tags: [moved])
        document("Other")
        var filter = DocumentFilter()
        filter.tags = [.init(moved)]
        #expect(filter.tags[0].key == "auto › steuer")

        moved.parent = nil  // moved on another device
        for document in moved.documents ?? [] { document.tags = [root] }
        context.delete(moved)  // merged into the root "Steuer" by an older version
        try context.save()

        #expect(filterContext(filter).hasUnresolvedReferences)
        #expect(try titles(filter).isEmpty)
    }

    @Test func unresolvedRefMatchesNothing() throws {
        let tax = tag("Tax")
        let correspondent = Correspondent(name: "Telekom")
        context.insert(correspondent)
        document("Tax", tags: [tax], correspondent: correspondent)
        let gone = DocumentFilter.Ref(id: UUID(), name: "Gone", key: "gone")
        for mode in DocumentFilter.TagMode.allCases {
            var filter = DocumentFilter()
            filter.tagMode = mode
            filter.tags = [.init(tax), gone]
            #expect(try titles(filter).isEmpty, "\(mode)")
        }
        var filter = DocumentFilter()
        filter.correspondents = [.init(correspondent), gone]
        #expect(try titles(filter).isEmpty)
        filter = DocumentFilter()
        filter.documentTypes = [gone]
        #expect(try titles(filter).isEmpty)
    }

    @Test func unresolvedExcludeIsSkipped() throws {
        let tax = tag("Tax")
        document("Tax", tags: [tax])
        document("Untagged")
        var filter = DocumentFilter()
        filter.excludedTags = [.init(id: UUID(), name: "Gone", key: "gone")]
        #expect(try titles(filter) == ["Tax", "Untagged"])
        filter.excludedTags.append(.init(tax))
        #expect(try titles(filter) == ["Untagged"])
    }

    @Test func unresolvedSetsBannerFlag() throws {
        let tax = tag("Tax")
        var filter = DocumentFilter()
        filter.tags = [.init(tax)]
        #expect(!filterContext(filter).hasUnresolvedReferences)
        let gone = DocumentFilter.Ref(id: UUID(), name: "Gone", key: "gone")
        filter.excludedTags = [gone]
        let flagged = filterContext(filter)
        #expect(flagged.hasUnresolvedReferences)
        #expect(flagged.unresolved == [gone.id])

        // References a newer version wrote in a form this one cannot read count as unresolved.
        let unreadable = DocumentFilter.decode(#"{"correspondents":[{"name":"no id"}]}"#)
        #expect(unreadable.fallbackKeys == ["correspondents"])
        #expect(filterContext(unreadable).hasUnresolvedReferences)
        document("Any")
        #expect(try titles(unreadable).isEmpty)
    }

    /// Saving a view after another change (as the editor will) keeps an unresolved reference; it
    /// is removed only explicitly.
    @Test func editorSaveKeepsUnresolvedRef() throws {
        let gone = DocumentFilter.Ref(id: UUID(), name: "Steuer", key: "steuer")
        var filter = DocumentFilter()
        filter.tags = [gone]
        let view = SavedView(name: "Taxes", filter: filter)
        context.insert(view)

        var edited = view.filter
        edited.query = "2026"
        view.filter = edited
        view.name = "Taxes 2026"
        #expect(view.filter.tags == [gone])

        edited.tags.removeAll { $0.id == gone.id }
        view.filter = edited
        #expect(view.filter.tags.isEmpty)
    }

    /// The merge hook rewrites references for every kind, including name and key, and keeps
    /// one reference when the view already referred to the keeper.
    @Test func replaceRewritesRefsThroughTheMergeHook() throws {
        let keeperTag = tag("Tax", createdAt: .distantPast)
        let duplicateTag = tag("tax", createdAt: Date())
        let otherTag = tag("Home")
        let keeperCorrespondent = Correspondent(name: "Telekom Deutschland GmbH")
        keeperCorrespondent.createdAt = .distantPast
        let duplicateCorrespondent = Correspondent(name: "Telekom Deutschland")
        let keeperType = DocumentType(name: "Invoice")
        keeperType.createdAt = .distantPast
        let duplicateType = DocumentType(name: "invoice")
        [keeperCorrespondent, duplicateCorrespondent].forEach(context.insert)
        [keeperType, duplicateType].forEach(context.insert)

        var filter = DocumentFilter()
        filter.tags = [.init(duplicateTag), .init(keeperTag)]
        filter.excludedTags = [.init(duplicateTag), .init(otherTag)]
        filter.correspondents = [.init(duplicateCorrespondent)]
        filter.documentTypes = [.init(duplicateType)]
        let view = SavedView(name: "View", filter: filter)
        let untouched = SavedView(name: "Untouched", filter: { var f = DocumentFilter(); f.tags = [.init(otherTag)]; return f }())
        context.insert(view)
        context.insert(untouched)
        try context.save()
        let untouchedJSON = untouched.filterJSON

        #expect(MetadataMaintenance.mergeDuplicates(in: context, recorder: nil) == 3)

        let merged = view.filter
        #expect(merged.tags == [.init(keeperTag)])
        #expect(merged.excludedTags == [.init(keeperTag), .init(otherTag)])
        #expect(merged.correspondents == [.init(keeperCorrespondent)])
        #expect(merged.correspondents.first?.name == "Telekom Deutschland GmbH")
        #expect(merged.documentTypes == [.init(keeperType)])
        #expect(untouched.filterJSON == untouchedJSON)
        #expect(!filterContext(merged).hasUnresolvedReferences)
    }

    // MARK: JSON

    @Test func codableRoundTripAndEmptyObject() throws {
        let tax = tag("Tax")
        var filter = DocumentFilter()
        filter.tags = [.init(tax)]
        filter.tagMode = .all
        filter.includeSubTags = false
        filter.excludedTags = [.init(id: UUID(), name: "X", key: "x")]
        filter.correspondents = [.init(id: UUID(), name: "C", key: "c")]
        filter.documentTypes = [.init(id: UUID(), name: "T", key: "t")]
        filter.dateField = .createdAt
        filter.dateRange = .absolute(from: .init(year: 2026, month: 1, day: 1), to: nil)
        filter.inbox = false
        filter.favorite = true
        filter.hasASN = true
        filter.query = "Rechnung"
        filter.sort = .title
        filter.ascending = true
        #expect(DocumentFilter.decode(DocumentFilter.json(filter, preserving: "{}")) == filter)
        for range: DocumentFilter.DateRange in [.thisYear, .lastYear, .last30Days, .last12Months, .year(2024),
                                               .absolute(from: nil, to: .init(year: 2026, month: 12, day: 31))] {
            var withRange = DocumentFilter()
            withRange.dateRange = range
            #expect(DocumentFilter.decode(DocumentFilter.json(withRange, preserving: "{}")) == withRange)
        }

        #expect(DocumentFilter.decode("{}") == DocumentFilter())
        #expect(DocumentFilter.decode("{}").isEmpty)
        #expect(DocumentFilter.decode("not json") == DocumentFilter())
        #expect(DocumentFilter.decode(#"{"inbox":null}"#) == DocumentFilter())
    }

    @Test func clearedFieldIsRemoved() throws {
        var filter = DocumentFilter()
        filter.inbox = true
        filter.dateRange = .thisYear
        let first = DocumentFilter.json(filter, preserving: #"{"future":1}"#)
        #expect(try Self.object(first)["inbox"] as? Bool == true)
        filter.inbox = nil
        filter.dateRange = nil
        let second = try Self.object(DocumentFilter.json(filter, preserving: first))
        #expect(second["inbox"] == nil)
        #expect(second["dateRange"] == nil)
        #expect(second["future"] as? Int == 1)
    }

    @Test func unknownKeyIsKept() throws {
        let stored = #"{"deadline":{"within":30},"query":"old"}"#
        var filter = DocumentFilter.decode(stored)
        #expect(filter.query == "old")
        filter.query = "new"
        let object = try Self.object(DocumentFilter.json(filter, preserving: stored))
        #expect(object["query"] as? String == "new")
        #expect((object["deadline"] as? [String: Int])?["within"] == 30)
    }

    /// `"sort":"future"` falls back to `.added`; saving after another edit keeps `"future"`, and
    /// only choosing a sort replaces it.
    @Test func unknownSortValueFallsBackAndIsPreserved() throws {
        let view = SavedView(name: "From a newer version")
        view.filterJSON = #"{"ascending":true,"sort":"future","query":"x"}"#
        context.insert(view)
        #expect(view.filter.sort == .added)
        #expect(view.filter.fallbackKeys == ["sort"])
        #expect(view.filter.ascending)

        view.name = "Renamed"
        var filter = view.filter
        filter.query = "y"
        view.filter = filter
        #expect(try Self.object(view.filterJSON)["sort"] as? String == "future")
        #expect(view.filter.query == "y")

        view.setSort(.title, ascending: true)
        #expect(try Self.object(view.filterJSON)["sort"] as? String == "title")
        #expect(view.filter.fallbackKeys.isEmpty)
    }

    @Test func unknownDateRangeCaseFallsBack() throws {
        let stored = #"{"dateRange":{"kind":"nextQuarter"},"inbox":true}"#
        let filter = DocumentFilter.decode(stored)
        #expect(filter.dateRange == nil)
        #expect(filter.inbox == true)
        #expect(filter.fallbackKeys == ["dateRange"])

        var edited = filter
        edited.inbox = false
        let kept = try Self.object(DocumentFilter.json(edited, preserving: stored))
        #expect((kept["dateRange"] as? [String: String])?["kind"] == "nextQuarter")
        #expect(kept["inbox"] as? Bool == false)

        edited.dateRange = .lastYear
        let replaced = try Self.object(DocumentFilter.json(edited, preserving: stored))
        #expect((replaced["dateRange"] as? [String: String])?["kind"] == "lastYear")
    }

    /// Follow-up from the part 1 review: a field that fell back can be set to the value it fell
    /// back to (the user picks "Added" for a newer version's sort, or clears its date range).
    /// Changing only the direction keeps the newer sort.
    @Test func fallenBackFieldCanBeSetToItsDefault() throws {
        let view = SavedView(name: "From a newer version")
        view.filterJSON = #"{"ascending":true,"dateRange":{"kind":"nextQuarter"},"sort":"future"}"#
        context.insert(view)
        #expect(view.filter.fallbackKeys == ["dateRange", "sort"])

        view.setAscending(false)
        var object = try Self.object(view.filterJSON)
        #expect(object["sort"] as? String == "future")
        #expect(object["ascending"] as? Bool == false)

        view.setSort(.added, ascending: false)
        object = try Self.object(view.filterJSON)
        #expect(object["sort"] as? String == "added")
        #expect((object["dateRange"] as? [String: String])?["kind"] == "nextQuarter")

        var filter = view.filter
        #expect(filter.fallbackKeys == ["dateRange"])
        filter.dateRange = nil
        #expect(filter.fallbackKeys.isEmpty)
        view.filter = filter
        #expect(try Self.object(view.filterJSON)["dateRange"] == nil)
    }

    // MARK: Editor and sidebar

    /// The editor shows references resolved by key as the live object (so the picker marks it)
    /// and keeps unresolved ones; untouched fields keep a newer version's value.
    @Test func editorResolvesReferencesToLiveObjects() throws {
        let tax = tag("Steuer")
        let telekom = Correspondent(name: "Telekom")
        context.insert(telekom)
        let byKey = DocumentFilter.Ref(id: UUID(), name: "steuer", key: "steuer")
        let gone = DocumentFilter.Ref(id: UUID(), name: "Gone", key: "gone")
        var stored = DocumentFilter.decode(#"{"sort":"future"}"#)
        stored.tags = [byKey, gone]
        stored.correspondents = [.init(telekom)]

        let edited = stored.resolvingReferences(tags: [tax], correspondents: [telekom], documentTypes: [])
        #expect(edited.tags == [.init(tax), gone])
        #expect(edited.correspondents == [.init(telekom)])
        #expect(edited.fallbackKeys == ["sort"])
        #expect(DocumentFilter.json(edited, preserving: #"{"sort":"future"}"#).contains(#""sort":"future""#))

        // Two references that resolve to the same tag become one.
        var twice = DocumentFilter()
        twice.tags = [byKey, .init(tax)]
        #expect(twice.resolvingReferences(tags: [tax], correspondents: [], documentTypes: []).tags == [.init(tax)])
    }

    /// "Save as View" from each sidebar list gives a filter that shows the same documents as the
    /// list (with its search text and sort). "Recently Added" uses the real date, so this test does too.
    @Test func saveAsViewPrefillMatchesTheList() throws {
        let now = Date()
        let telekom = Correspondent(name: "Telekom")
        let invoice = DocumentType(name: "Invoice")
        context.insert(telekom)
        context.insert(invoice)
        let auto = tag("Auto")
        let golf = tag("Golf", under: auto)
        document("Inbox invoice", correspondent: telekom, type: invoice, createdAt: now - 86_400, inbox: true,
                 text: "Rechnung")
        document("Golf", tags: [golf], createdAt: now - 40 * 86_400, favorite: true, text: "Werkstatt")
        document("Auto", tags: [auto], text: "Rechnung Werkstatt")
        document("Plain", createdAt: now - 2 * 86_400)
        let documents = try allDocuments()

        let items: [SidebarItem] = [.all, .inbox, .favorites, .recent, .documentType(invoice), .correspondent(telekom),
                                    .tag(auto)]
        for item in items {
            for search in ["", "Rechnung"] {
                let prefill = item.savedViewPrefill(searchText: search, sort: .title)
                let list = item.visibleDocuments(in: documents, searchText: search, sort: .title).map(\.title)
                let viaFilter = prefill.filter.apply(to: documents, context: FilterContext(filter: prefill.filter, in: context))
                    .map(\.title)
                #expect(viaFilter == list, "\(item.title), search “\(search)”")
            }
        }
        #expect(SidebarItem.inbox.savedViewPrefill(searchText: "", sort: .added).name == SidebarItem.inbox.title)
        #expect(SidebarItem.all.savedViewPrefill(searchText: "", sort: .added).name == "")
        #expect(SidebarItem.all.savedViewPrefill(searchText: " Rechnung ", sort: .added).name == "Rechnung")
        #expect(SidebarItem.tag(auto).savedViewPrefill(searchText: "", sort: .added).filter.tags == [.init(auto)])

        // A saved view is copied, its search term combined with the search text.
        var werkstatt = DocumentFilter()
        werkstatt.query = "Werkstatt"
        werkstatt.sort = .title
        werkstatt.ascending = true
        let view = SavedView(name: "Workshop", filter: werkstatt)
        context.insert(view)
        let copy = SidebarItem.savedView(view).savedViewPrefill(searchText: "Rechnung", sort: .added)
        #expect(copy.filter.query == "Werkstatt Rechnung")
        #expect(copy.filter.sort == .title)
        #expect(copy.name == SavedViewMaintenance.copyName(of: view))
        #expect(copy.filter.apply(to: documents, context: FilterContext(filter: copy.filter, in: context)).map(\.title) == ["Auto"])
    }

    /// Moved from part 1: the sidebar entry of a saved view includes exactly the documents its
    /// filter matches, and its list is the filter's result in the view's sort, narrowed by the search.
    @Test func savedViewSidebarItemIncludesEqualsFilterMatches() throws {
        let insurance = tag("Versicherung")
        let car = tag("Auto", under: insurance)
        let telekom = Correspondent(name: "Telekom")
        context.insert(telekom)
        document("Car open", tags: [car], date: at(2026, 1, 5), inbox: true)
        document("Insurance done", tags: [insurance], date: at(2025, 5, 1))
        document("Telekom", correspondent: telekom, date: at(2026, 2, 1), favorite: true, text: "Rechnung")
        document("Plain", date: at(2026, 3, 1), asn: 3)
        let documents = try allDocuments()

        var filters: [DocumentFilter] = [DocumentFilter()]
        var byTag = DocumentFilter()
        byTag.tags = [.init(insurance)]
        byTag.inbox = true
        filters.append(byTag)
        var byYear = DocumentFilter()
        byYear.dateRange = .thisYear
        byYear.excludedTags = [.init(insurance)]
        byYear.sort = .title
        byYear.ascending = true
        filters.append(byYear)
        var byCorrespondent = DocumentFilter()
        byCorrespondent.correspondents = [.init(telekom), .init(id: UUID(), name: "Gone", key: "gone")]
        filters.append(byCorrespondent)

        for filter in filters {
            let view = SavedView(name: "View", filter: filter)
            context.insert(view)
            let item = SidebarItem.savedView(view)
            let filterContext = FilterContext(filter: filter, in: context)
            for document in documents {
                #expect(item.includes(document) == filter.matches(document, context: filterContext), "\(document.title)")
            }
            #expect(item.visibleDocuments(in: documents, searchText: "", sort: .added).map(\.id)
                    == filter.apply(to: documents, context: filterContext).map(\.id))
            let searched = item.visibleDocuments(in: documents, searchText: "Rechnung", sort: .added)
            #expect(searched.map(\.id) == filter.apply(to: documents, context: filterContext).filter { $0.matches("Rechnung") }.map(\.id))
        }

        let deleted = SavedView(name: "Deleted")
        context.insert(deleted)
        try context.save()
        MetadataDeletion.delete(deleted, in: context, recorder: nil)
        try context.save()
        #expect(documents.allSatisfy { !SidebarItem.savedView(deleted).includes($0) })
        #expect(SidebarItem.savedView(deleted).visibleDocuments(in: documents, searchText: "", sort: .added).isEmpty)
    }

    @Test func sidebarCountsMatchTheFilters() throws {
        let tax = tag("Tax")
        document("Tax 1", tags: [tax])
        document("Tax 2", tags: [tax], inbox: true)
        document("Other", inbox: true)
        var taxes = DocumentFilter()
        taxes.tags = [.init(tax)]
        var inbox = DocumentFilter()
        inbox.inbox = true
        let views = [SavedView(name: "Taxes", filter: taxes), SavedView(name: "Inbox", filter: inbox),
                     SavedView(name: "Everything")]
        views.forEach(context.insert)
        let counts = SavedViewMaintenance.counts(of: views, documents: try allDocuments(), tags: [tax],
                                                 correspondents: [], documentTypes: [], now: now)
        #expect(views.map { counts[$0.id] } == [2, 2, 3])
    }

    /// "Duplicate" copies the stored JSON exactly (also a newer version's keys) and adds the copy
    /// at the end.
    @Test func duplicateCopiesTheStoredFilter() throws {
        let view = SavedView(name: "Original", symbol: "star", sortIndex: 3)
        view.filterJSON = #"{"deadline":{"within":30},"sort":"future"}"#
        context.insert(view)
        let other = SavedView(name: "Other", sortIndex: 5)
        context.insert(other)
        let copy = SavedViewMaintenance.duplicate(view, among: [view, other], in: context)
        #expect(copy.filterJSON == view.filterJSON)
        #expect(copy.symbol == "star")
        #expect(copy.name == SavedViewMaintenance.copyName(of: view))
        #expect(copy.id != view.id)
        #expect(copy.sortIndex == 6)
    }

    // MARK: SavedView

    @Test func savedViewWritesOnlyOnChange() throws {
        var filter = DocumentFilter()
        filter.sort = .title
        filter.ascending = true
        let view = SavedView(name: "View", filter: filter)
        context.insert(view)
        try context.save()
        let json = view.filterJSON

        view.setSort(.title, ascending: true)
        view.filter = view.filter
        #expect(view.filterJSON == json)
        #expect(!context.hasChanges)

        view.setSort(.title, ascending: false)
        #expect(view.filterJSON != json)
        #expect(context.hasChanges)
    }

    @Test func reorderRenumbersAndTiesAreStable() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let views = (0..<4).map { index in
            let view = SavedView(name: "V\(index)", sortIndex: 0)
            view.createdAt = date.addingTimeInterval(Double(index))
            context.insert(view)
            return view
        }
        // Equal sortIndex (two devices): ordered by createdAt.
        #expect(SavedViewMaintenance.sorted(views.reversed()).map(\.name) == ["V0", "V1", "V2", "V3"])
        // Equal sortIndex and createdAt: by id.
        let twinA = SavedView(name: "Twin A", sortIndex: 9)
        let twinB = SavedView(name: "Twin B", sortIndex: 9)
        twinA.createdAt = date
        twinB.createdAt = date
        let expectedTwins = [twinA, twinB].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.name)
        #expect(SavedViewMaintenance.sorted([twinB, twinA]).map(\.name) == expectedTwins)
        #expect(SavedViewMaintenance.sorted([twinA, twinB]).map(\.name) == expectedTwins)

        // Move V3 to the top: everything is renumbered 0…n.
        SavedViewMaintenance.move(views, fromOffsets: [3], toOffset: 0)
        #expect(SavedViewMaintenance.sorted(views).map(\.name) == ["V3", "V0", "V1", "V2"])
        #expect(SavedViewMaintenance.sorted(views).map(\.sortIndex) == [0, 1, 2, 3])
        SavedViewMaintenance.move(views, fromOffsets: [0], toOffset: 4)
        #expect(SavedViewMaintenance.sorted(views).map(\.name) == ["V0", "V1", "V2", "V3"])
        #expect(SavedViewMaintenance.nextSortIndex(after: views) == 4)
    }

    @Test func decodeCacheReturnsTheSameInstance() {
        let cache = DocumentFilterCache()
        let json = #"{"query":"cached"}"#
        let first = cache.entry(for: json)
        #expect(cache.entry(for: json) === first)
        #expect(cache.entry(for: #"{"query":"other"}"#) !== first)
        #expect(first.filter.query == "cached")
    }

    /// Deleting a view goes through `MetadataDeletion`, so the folder copy writes a tombstone.
    @Test func deletingAViewRecordsATombstone() throws {
        let recorder = RecordedDeletions()
        let view = SavedView(name: "Old")
        context.insert(view)
        try context.save()
        MetadataDeletion.delete(view, in: context, recorder: recorder)
        try context.save()
        #expect(recorder.records.map(\.kind) == [.savedView])
        #expect(recorder.records.first?.id == view.id)
        #expect(try context.fetch(FetchDescriptor<SavedView>()).isEmpty)
    }
}
