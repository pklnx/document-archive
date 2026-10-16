import SwiftData
import SwiftUI

/// What the saved view editor (#14) works on.
enum SavedViewEditorTarget: Identifiable {
    /// A new view: "+" in the sidebar (empty) or "Save as View…" (filled from the list in front).
    case new(name: String, filter: DocumentFilter)
    case edit(SavedView)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let view): "edit-\(view.id)"
        }
    }

    /// The edited view, `nil` for a new one.
    var view: SavedView? {
        if case .edit(let view) = self { view } else { nil }
    }
}

extension SidebarItem {
    /// "Save as View": a new view's name and filter from the list in front, its search text and
    /// sort. Built-in lists become the matching criteria; a saved view is copied, with the search
    /// text added to its search term (both must match, like the list shows).
    @MainActor
    func savedViewPrefill(searchText: String, sort: DocumentSort) -> (name: String, filter: DocumentFilter) {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var filter = DocumentFilter()
        filter.sort = sort
        filter.ascending = sort.defaultAscending
        var name = title
        switch self {
        case .all, .duplicates:
            name = ""
        case .inbox:
            filter.inbox = true
        case .favorites:
            filter.favorite = true
        case .recent:
            filter.dateField = .createdAt
            filter.dateRange = .last30Days
        case .documentType(let type):
            filter.documentTypes = [DocumentFilter.Ref(type)]
        case .correspondent(let correspondent):
            filter.correspondents = [DocumentFilter.Ref(correspondent)]
        case .tag(let tag):
            filter.tags = [DocumentFilter.Ref(tag)]
        case .savedView(let view):
            filter = view.filter
            filter.fallbackKeys = []
            name = SavedViewMaintenance.copyName(of: view)
        }
        if !search.isEmpty {
            filter.query = [filter.query, search].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = search }
        }
        return (name, filter)
    }
}

extension View {
    /// Presents the saved view editor: a popover on macOS and in regular width on iPad, a sheet on
    /// iPhone (the popover adapts). `onSave` receives the saved view.
    func savedViewEditor(item: Binding<SavedViewEditorTarget?>, onSave: @escaping (SavedView) -> Void = { _ in }) -> some View {
        popover(item: item) { target in
            SavedViewEditor(target: target, onSave: onSave)
                .presentationCompactAdaptation(.sheet)
        }
    }
}

/// Creating and editing a saved view: name, symbol and every `DocumentFilter` criterion, with a
/// live count. Fields the user does not change keep their stored value, also values of a newer
/// app version (`DocumentFilter.fallbackKeys`); references to deleted items are shown as deleted
/// and removed only by the user.
struct SavedViewEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let target: SavedViewEditorTarget
    var onSave: (SavedView) -> Void = { _ in }

    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \Correspondent.name) private var correspondents: [Correspondent]
    @Query(sort: \DocumentType.name) private var documentTypes: [DocumentType]
    @Query(filter: #Predicate<Document> { _ in true }) private var documents: [Document]
    @Query private var savedViews: [SavedView]

    @State private var name = ""
    @State private var symbol = SavedView.defaultSymbol
    @State private var filter = DocumentFilter()
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            let filterContext = FilterContext(filter: filter, tags: tags, correspondents: correspondents,
                                              documentTypes: documentTypes)
            Form {
                nameSection(filterContext)
                SavedViewSymbolPicker(symbol: $symbol)
                tagSection(filterContext)
                referenceSection(filterContext)
                SavedViewDateSection(filter: $filter)
                SavedViewStatusSection(filter: $filter)
                sortSection
                if !filter.fallbackKeys.isEmpty {
                    Section {
                        Text("Some settings of this view were made in a newer version of the app. They are kept unless you change them here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier(AccessibilityID.savedViewEditor)
            .navigationTitle(target.view == nil ? Text("New View") : Text("Edit View"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.savedViewEditorCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier(AccessibilityID.savedViewEditorSave)
                }
            }
        }
        .frame(idealWidth: 440, idealHeight: 640)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .onAppear(perform: load)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Sections

    private func nameSection(_ filterContext: FilterContext) -> some View {
        Section {
            TextField("Name", text: $name)
                .accessibilityIdentifier(AccessibilityID.savedViewEditorName)
            TextField("Search term", text: $filter.query, prompt: Text("Words in the text, title or notes"))
                .autocorrectionDisabled()
        } footer: {
            let count = documents.reduce(0) { $0 + ($1.isAlive && filter.matches($1, context: filterContext) ? 1 : 0) }
            Text("Matches \(DocumentAccessibility.documentCount(count))")
                .accessibilityIdentifier(AccessibilityID.savedViewEditorCount)
        }
    }

    @ViewBuilder
    private func tagSection(_ filterContext: FilterContext) -> some View {
        Section("Tags") {
            NavigationLink {
                ReferencePicker(title: String(localized: "Tags"), options: tagOptions, selection: $filter.tags)
            } label: {
                LabeledContent("Tags", value: summary(filter.tags, filterContext))
            }
            deletedRows(filter.tags, filterContext) { id in filter.tags.removeAll { $0.id == id } }
            if filter.tags.count > 1 {
                Picker("Documents need", selection: choice(\.tagMode, .tagMode)) {
                    fallbackChoice(DocumentFilter.TagMode.self, .tagMode)
                    Text("Any of these tags").tag(DocumentFilter.TagMode?.some(.any))
                    Text("All of these tags").tag(DocumentFilter.TagMode?.some(.all))
                }
            }
            NavigationLink {
                ReferencePicker(title: String(localized: "Excluded Tags"), options: tagOptions,
                                selection: $filter.excludedTags)
            } label: {
                LabeledContent("Excluded tags", value: summary(filter.excludedTags, filterContext))
            }
            deletedRows(filter.excludedTags, filterContext) { id in filter.excludedTags.removeAll { $0.id == id } }
            Toggle("Include nested tags (also when excluding)", isOn: $filter.includeSubTags)
        }
    }

    @ViewBuilder
    private func referenceSection(_ filterContext: FilterContext) -> some View {
        Section {
            NavigationLink {
                ReferencePicker(title: String(localized: "Correspondents"),
                                options: correspondents.filter { !$0.isDeleted }.map { .init($0) },
                                selection: $filter.correspondents)
            } label: {
                LabeledContent("Correspondents", value: summary(filter.correspondents, filterContext))
            }
            deletedRows(filter.correspondents, filterContext) { id in filter.correspondents.removeAll { $0.id == id } }
            NavigationLink {
                ReferencePicker(title: String(localized: "Document Types"),
                                options: documentTypes.filter { !$0.isDeleted }.map { .init($0) },
                                selection: $filter.documentTypes)
            } label: {
                LabeledContent("Document types", value: summary(filter.documentTypes, filterContext))
            }
            deletedRows(filter.documentTypes, filterContext) { id in filter.documentTypes.removeAll { $0.id == id } }
        } footer: {
            Text("A document matches one of the chosen correspondents and one of the chosen types.")
        }
    }

    private var sortSection: some View {
        Section("Sort") {
            Picker("Sort by", selection: sortChoice) {
                fallbackChoice(DocumentSort.self, .sort)
                ForEach(DocumentSort.allCases) { Text($0.label).tag(DocumentSort?.some($0)) }
            }
            Picker("Order", selection: choice(\.ascending, .ascending)) {
                fallbackChoice(Bool.self, .ascending)
                Text("Ascending").tag(Bool?.some(true))
                Text("Descending").tag(Bool?.some(false))
            }
        }
    }

    /// Choosing a sort also sets its usual direction, like the sidebar lists.
    private var sortChoice: Binding<DocumentSort?> {
        Binding {
            filter.fallbackKeys.contains("sort") ? nil : filter.sort
        } set: { sort in
            guard let sort else { return }
            filter.sort = sort
            filter.ascending = sort.defaultAscending
        }
    }

    // MARK: Helpers

    private var tagOptions: [ReferencePicker.Option] {
        TagHierarchy.flattened(tags.filter { !$0.isDeleted }).map { ReferencePicker.Option($0.tag, depth: $0.depth) }
    }

    /// "Tax, Insurance", "None", or "2 chosen" for longer lists.
    private func summary(_ refs: [DocumentFilter.Ref], _ filterContext: FilterContext) -> String {
        let live = refs.filter { !filterContext.unresolved.contains($0.id) }
        if live.isEmpty { return String(localized: "None") }
        if live.count > 2 { return String(localized: "\(live.count) chosen") }
        return live.map(\.name).joined(separator: ", ")
    }

    /// One row per reference that can no longer be resolved, with a button that removes it.
    @ViewBuilder
    private func deletedRows(_ refs: [DocumentFilter.Ref], _ filterContext: FilterContext,
                             remove: @escaping (UUID) -> Void) -> some View {
        ForEach(refs.filter { filterContext.unresolved.contains($0.id) }, id: \.id) { ref in
            HStack {
                Label {
                    Text("“\(ref.name)” (deleted)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                Button("Remove", role: .destructive) { remove(ref.id) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Remove “\(ref.name)”"))
            }
        }
    }

    private func choice<T: Hashable>(_ keyPath: WritableKeyPath<DocumentFilter, T>,
                                     _ key: DocumentFilter.CodingKeys) -> Binding<T?> {
        SavedViewEditor.choice($filter, keyPath, key)
    }

    /// A picker value that shows a newer version's value as its own choice (`nil`), so choosing
    /// any value replaces it, also the value this version fell back to.
    static func choice<T: Hashable>(_ filter: Binding<DocumentFilter>, _ keyPath: WritableKeyPath<DocumentFilter, T>,
                                    _ key: DocumentFilter.CodingKeys) -> Binding<T?> {
        Binding {
            filter.wrappedValue.fallbackKeys.contains(key.stringValue) ? nil : filter.wrappedValue[keyPath: keyPath]
        } set: { value in
            if let value { filter.wrappedValue[keyPath: keyPath] = value }
        }
    }

    @ViewBuilder
    private func fallbackChoice<T: Hashable>(_ type: T.Type, _ key: DocumentFilter.CodingKeys) -> some View {
        SavedViewEditor.fallbackChoice(type, shown: filter.fallbackKeys.contains(key.stringValue))
    }

    @ViewBuilder
    static func fallbackChoice<T: Hashable>(_ type: T.Type, shown: Bool) -> some View {
        if shown {
            Text("Set by a newer app version").tag(T?.none)
        }
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        switch target {
        case .new(let name, let filter):
            self.name = name
            self.filter = filter
        case .edit(let view):
            guard !view.isDeleted, view.modelContext != nil else { return }
            name = view.name
            symbol = view.symbol
            filter = view.filter.resolvingReferences(tags: tags, correspondents: correspondents,
                                                     documentTypes: documentTypes)
        }
    }

    private func save() {
        let view: SavedView
        switch target {
        case .new:
            view = SavedView(name: trimmedName, symbol: symbol, filter: filter,
                             sortIndex: SavedViewMaintenance.nextSortIndex(after: savedViews))
            context.insert(view)
        case .edit(let edited):
            // Deleted on another device while the editor was open: nothing to save into.
            guard !edited.isDeleted, edited.modelContext != nil else { dismiss(); return }
            view = edited
            if view.name != trimmedName { view.name = trimmedName }
            if view.symbol != symbol { view.symbol = symbol }
            view.filter = filter
        }
        try? context.save()
        onSave(view)
        dismiss()
    }
}

// MARK: - Parts

/// The symbol grid, like the tag and document type editors.
private struct SavedViewSymbolPicker: View {
    @Binding var symbol: String

    var body: some View {
        Section("Symbol") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(SavedView.symbolChoices, id: \.self) { choice in
                    symbolButton(choice)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func symbolButton(_ choice: String) -> some View {
        Image(systemName: choice)
            .font(.title3)
            .frame(width: 36, height: 36)
            .background(choice == symbol ? Color.accentColor.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                // Not by color alone: the chosen symbol also gets a border.
                if choice == symbol {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { symbol = choice }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(choice == symbol ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(SavedView.symbolName(for: choice))
            .accessibilityAction { symbol = choice }
    }
}

/// The date criterion: which date, and a relative or absolute period.
private struct SavedViewDateSection: View {
    @Binding var filter: DocumentFilter

    /// The period choices of the picker; `year` and `custom` show more controls.
    enum Period: Hashable {
        case any, thisYear, lastYear, last30Days, last12Months, year, custom
    }

    var body: some View {
        Section {
            Picker("Period", selection: period) {
                SavedViewEditor.fallbackChoice(Period.self, shown: filter.fallbackKeys.contains("dateRange"))
                Text("Any time").tag(Period?.some(.any))
                Text("This year").tag(Period?.some(.thisYear))
                Text("Last year").tag(Period?.some(.lastYear))
                Text("Last 30 days").tag(Period?.some(.last30Days))
                Text("Last 12 months").tag(Period?.some(.last12Months))
                Text("A specific year").tag(Period?.some(.year))
                Text("From – to").tag(Period?.some(.custom))
            }
            if filter.dateRange != nil {
                Picker("Date", selection: SavedViewEditor.choice($filter, \.dateField, .dateField)) {
                    SavedViewEditor.fallbackChoice(DocumentFilter.DateField.self,
                                                   shown: filter.fallbackKeys.contains("dateField"))
                    Text("Issue date").tag(DocumentFilter.DateField?.some(.documentDate))
                    Text("Added").tag(DocumentFilter.DateField?.some(.createdAt))
                }
            }
            if case .year(let year) = filter.dateRange {
                Stepper(value: Binding { year } set: { filter.dateRange = .year($0) }, in: 1900...2200) {
                    LabeledContent("Year", value: String(year))
                }
            }
            if case .absolute(let from, let to) = filter.dateRange {
                dayRow(String(localized: "From"), day: from) { filter.dateRange = .absolute(from: $0, to: to) }
                dayRow(String(localized: "To"), day: to) { filter.dateRange = .absolute(from: from, to: $0) }
            }
        } header: {
            Text("Date")
        } footer: {
            Text("Both days are included. Relative periods end today.")
        }
    }

    /// An optional day: a switch, and a date picker while it is on.
    @ViewBuilder
    private func dayRow(_ title: String, day: DocumentFilter.Day?,
                        set: @escaping (DocumentFilter.Day?) -> Void) -> some View {
        Toggle(title, isOn: Binding { day != nil } set: { isOn in
            set(isOn ? DocumentFilter.Day(Date()) : nil)
        })
        if let day {
            DatePicker(title, selection: Binding { day.date() } set: { set(DocumentFilter.Day($0)) },
                       displayedComponents: .date)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private var period: Binding<Period?> {
        Binding {
            if filter.fallbackKeys.contains("dateRange") { return nil }
            switch filter.dateRange {
            case nil: return .any
            case .thisYear: return .thisYear
            case .lastYear: return .lastYear
            case .last30Days: return .last30Days
            case .last12Months: return .last12Months
            case .year: return .year
            case .absolute: return .custom
            }
        } set: { period in
            guard let period else { return }
            switch period {
            case .any: filter.dateRange = nil
            case .thisYear: filter.dateRange = .thisYear
            case .lastYear: filter.dateRange = .lastYear
            case .last30Days: filter.dateRange = .last30Days
            case .last12Months: filter.dateRange = .last12Months
            case .year: filter.dateRange = .year(DocumentFilter.Day(Date()).year)
            case .custom: filter.dateRange = .absolute(from: DocumentFilter.Day(Date()), to: nil)
            }
        }
    }
}

/// Inbox, favorite and ASN: each "any", yes or no.
private struct SavedViewStatusSection: View {
    @Binding var filter: DocumentFilter

    var body: some View {
        Section("Status") {
            statusPicker("Inbox", \.inbox, .inbox, yes: "In the inbox", no: "Not in the inbox")
            statusPicker("Favorite", \.favorite, .favorite, yes: "Favorites only", no: "No favorites")
            statusPicker("ASN", \.hasASN, .hasASN, yes: "With number", no: "Without number")
        }
    }

    private func statusPicker(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<DocumentFilter, Bool?>,
                              _ key: DocumentFilter.CodingKeys, yes: LocalizedStringKey,
                              no: LocalizedStringKey) -> some View {
        Picker(title, selection: SavedViewEditor.choice($filter, keyPath, key)) {
            SavedViewEditor.fallbackChoice(Bool?.self, shown: filter.fallbackKeys.contains(key.stringValue))
            Text("Any").tag(Bool??.some(nil))
            Text(yes).tag(Bool??.some(true))
            Text(no).tag(Bool??.some(false))
        }
    }
}

/// A searchable multi-select list of tags (as a tree), correspondents or document types.
struct ReferencePicker: View {
    struct Option: Identifiable {
        let ref: DocumentFilter.Ref
        /// Shown for VoiceOver and searched: the tag path, or the name.
        let label: String
        let depth: Int
        var id: UUID { ref.id }

        @MainActor init(_ tag: Tag, depth: Int) {
            ref = DocumentFilter.Ref(tag)
            label = TagHierarchy.displayPath(of: tag)
            self.depth = depth
        }

        @MainActor init(_ correspondent: Correspondent) {
            ref = DocumentFilter.Ref(correspondent)
            label = correspondent.name
            depth = 0
        }

        @MainActor init(_ type: DocumentType) {
            ref = DocumentFilter.Ref(type)
            label = type.name
            depth = 0
        }
    }

    let title: String
    let options: [Option]
    @Binding var selection: [DocumentFilter.Ref]
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(visibleOptions) { option in
                row(option)
            }
        }
        .overlay {
            if options.isEmpty {
                ContentUnavailableView("Nothing to Choose", systemImage: "list.bullet",
                                       description: Text("Create entries in the sidebar first."))
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(title)
    }

    /// While searching, the matching entries without indentation.
    private var visibleOptions: [Option] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return options }
        return options.filter { $0.label.localizedStandardContains(query) }
    }

    private func row(_ option: Option) -> some View {
        let isSelected = selection.contains { $0.id == option.id }
        let indent = searchText.isEmpty ? CGFloat(option.depth) * 16 : 0
        return Button {
            if isSelected {
                selection.removeAll { $0.id == option.id }
            } else {
                selection.append(option.ref)
            }
        } label: {
            HStack {
                Text(searchText.isEmpty ? option.ref.name : option.label)
                    .foregroundStyle(.primary)
                    .padding(.leading, indent)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: option.label))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
