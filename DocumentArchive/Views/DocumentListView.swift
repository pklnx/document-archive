import SwiftData
import SwiftUI

extension SidebarItem {
    /// The documents the list shows for this sidebar entry, search text and sort order.
    /// `ContentView` resolves the selection against exactly this list (see `DocumentSelection`).
    @MainActor func visibleDocuments(in allDocuments: [Document], searchText: String, sort: DocumentSort) -> [Document] {
        let allDocuments = allDocuments.filter(\.isAlive)
        if self == .duplicates {
            // Show duplicates grouped, each with the original (oldest) first
            return MetadataMaintenance.duplicateDocumentGroups(allDocuments)
                .flatMap { $0 }
                .filter { $0.matches(searchText) }
        }
        if case .savedView(let view) = self {
            // The view's own sort (saved into the view); the search field narrows it further.
            guard let (filter, context) = view.filterAndContext() else { return [] }
            return filter.apply(to: allDocuments.filter { $0.matches(searchText) }, context: context)
        }
        let includes = documentFilter()
        let filtered = allDocuments.filter { includes($0) && $0.matches(searchText) }
        return sort.sort(filtered, ascending: sort.defaultAscending)
    }
}

struct DocumentListView<ImportMenu: View>: View {
    @Environment(\.modelContext) private var context
    @Environment(BulkActionCoordinator.self) private var bulkActions: BulkActionCoordinator?
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    let filter: SidebarItem
    let searchText: String
    /// The visible documents, in list order (`SidebarItem.visibleDocuments`).
    let documents: [Document]
    @Binding var selection: Set<Document.ID>
    /// iOS edit mode: the bulk actions go into a bottom toolbar (iPhone, narrow iPad windows),
    /// because no detail column with `BulkActionsView` is shown beside the list.
    var showsBulkToolbar = false
    @ViewBuilder var importMenu: () -> ImportMenu
    var onDropFiles: ([ImportedFile]) -> Void
    /// A tag's list (#13): the tags nested directly in it, shown as chips above the documents.
    var subfolders: [SubfolderChip] = []
    /// Regular width: a chip selects its tag in the sidebar. `nil` (iPhone): chips are
    /// `NavigationLink(value: Tag)`, pushed by the content column's `NavigationStack`.
    var openSubfolder: ((Tag) -> Void)?
    /// The saved view editor of the list in front (#14): "Save as View…" (also ⌥⌘S), "Edit
    /// View…" and the banner. `nil` for lists behind it (iPhone's stack).
    var viewEditor: Binding<SavedViewEditorTarget?>?
    /// A view was saved in the editor: show it.
    var openView: (SavedView) -> Void = { _ in }

    @AppStorage("documentSort") private var sort: DocumentSort = .added
    @State private var isDropTargeted = false
    @State private var documentToDelete: Document?
    @State private var confirmRemoveDuplicates = false

    private var selectedDocuments: [Document] { DocumentSelection.resolve(selection, in: documents) }

    var body: some View {
        List(selection: $selection) {
            if let view = unresolvedView {
                UnresolvedReferencesBanner { viewEditor?.wrappedValue = .edit(view) }
                    .listRowSeparator(.hidden)
            }
            // A row without a selection tag: never selected, scrolls with the list, so the large
            // title stays visible above it.
            if !subfolders.isEmpty, !isEditing {
                SubfolderBar(subfolders: subfolders, open: openSubfolder)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            ForEach(documents) { document in
                DocumentRow(document: document)
                    .accessibilityIdentifier(AccessibilityID.documentRow(document.title))
                    #if os(macOS)
                    // iOS offers the swipe actions to VoiceOver; macOS has no swipe, so name them.
                    .accessibilityAction(named: document.isInbox ? Text("Mark as Done") : Text("Move to Inbox")) {
                        document.isInbox.toggle()
                        document.touch()
                    }
                    .accessibilityAction(named: document.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites")) {
                        document.isFavorite.toggle()
                        document.touch()
                    }
                    .accessibilityAction(named: Text("Delete")) { documentToDelete = document }
                    #endif
                    .swipeActions(edge: .leading) {
                        Button {
                            document.isInbox.toggle()
                            document.touch()
                        } label: {
                            Label(document.isInbox ? "Mark Done" : "Inbox",
                                  systemImage: document.isInbox ? "tray.and.arrow.up" : "tray.and.arrow.down")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { documentToDelete = document } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier(AccessibilityID.deleteSwipe)
                        Button {
                            document.isFavorite.toggle()
                            document.touch()
                        } label: {
                            Label("Favorite", systemImage: document.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    // The PDF is read only when the drag is dropped (#19).
                    .draggable(document.transfer(named: document.exportFileName))
            }
        }
        // One menu for the row under the pointer or the whole selection.
        .contextMenu(forSelectionType: Document.ID.self) { ids in
            let documents = DocumentSelection.resolve(ids, in: documents)
            if documents.count == 1, let document = documents.first {
                contextMenu(for: document)
            } else if documents.count > 1 {
                BulkActionsMenu(documents: documents)
            }
        }
        #if os(macOS)
        // ⌫ only reaches the list while it has the focus, never a text field of the inspector.
        .onDeleteCommand {
            let documents = selectedDocuments
            if !documents.isEmpty { bulkActions?.requestDelete(documents) }
        }
        #endif
        .accessibilityIdentifier(AccessibilityID.documentList)
        .overlay {
            if documents.isEmpty { emptyState }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let bulkActions, let progress = bulkActions.progress {
                BulkProgressView(progress: progress) { bulkActions.cancelReanalysis() }
            }
        }
        .dropDestination(for: ImportedFile.self) { files, _ in
            onDropFiles(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle(filter.title)
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        .navigationSubtitle(selection.count > 1 ? Text("\(selectedDocuments.count) of \(documents.count) selected")
                                                : Text("\(documents.count) documents"))
        #endif
        .toolbar { toolbar }
        .confirmationDialog("Remove duplicates?", isPresented: $confirmRemoveDuplicates, titleVisibility: .visible) {
            Button("Delete Duplicates", role: .destructive) {
                selection = []
                MetadataMaintenance.removeDuplicateDocuments(in: context)
            }
        } message: {
            Text("For every identical file, the document imported first is kept. Missing details such as tags or notes are taken over from the duplicates.")
        }
        .confirmationDialog("Delete document?", isPresented: Binding(presenting: $documentToDelete),
                            titleVisibility: .visible, presenting: documentToDelete) { document in
            Button("Delete", role: .destructive) { delete(document) }
                .accessibilityIdentifier(AccessibilityID.deleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { document in
            Text(DocumentDetailView.deleteMessage(for: document))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        if isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { setEditing(false) }
                    .accessibilityIdentifier(AccessibilityID.selectButton)
            }
            ToolbarItem(placement: .topBarLeading) {
                let allSelected = !documents.isEmpty && selectedDocuments.count == documents.count
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(documents.map(\.id))
                }
                .accessibilityIdentifier(AccessibilityID.selectAll)
            }
            if showsBulkToolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    let documents = selectedDocuments
                    BulkTagsMenu(documents: documents)
                    Spacer()
                    BulkInboxButton(documents: documents)
                    Spacer()
                    Menu {
                        BulkActionsMenu(documents: documents, part: .more)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier(AccessibilityID.bulkMore)
                    .disabled(documents.isEmpty)
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                importMenu()
                    .accessibilityIdentifier(AccessibilityID.importMenu)
            }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            importMenu()
                .accessibilityIdentifier(AccessibilityID.importMenu)
        }
        #endif
        if filter == .duplicates, !documents.isEmpty, !isEditing {
            ToolbarItem {
                Button("Remove Duplicates", systemImage: "trash.slash") { confirmRemoveDuplicates = true }
            }
        }
        if !isEditing {
            ToolbarItem {
                // One menu for the sort and "Save as View…", so narrow columns (iPad) keep their
                // buttons in the toolbar. The editor points at this menu.
                Menu {
                    sortMenu
                    if filter != .duplicates, let viewEditor {
                        Divider()
                        savedViewButton(viewEditor)
                    }
                } label: {
                    Label("Sort and Views", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier(AccessibilityID.listOptions)
                .savedViewEditor(item: viewEditor ?? .constant(nil), onSave: openView)
            }
        }
        #if os(iOS)
        if !isEditing, !documents.isEmpty {
            ToolbarItem {
                Button("Select") { setEditing(true) }
                    .accessibilityIdentifier(AccessibilityID.selectButton)
            }
        }
        #endif
    }

    /// The sidebar lists share one sort setting; a saved view's sort is saved into the view
    /// (maintainer decision), with its direction.
    @ViewBuilder
    private var sortMenu: some View {
        if case .savedView(let view) = filter, !view.isDeleted, view.modelContext != nil {
            let fellBack = view.filter.fallbackKeys
            Picker("Sort by", selection: Binding<DocumentSort?> {
                fellBack.contains("sort") ? nil : view.filter.sort
            } set: { sort in
                guard let sort else { return }
                view.setSort(sort, ascending: sort.defaultAscending)
                try? context.save()
            }) {
                SavedViewEditor.fallbackChoice(DocumentSort.self, shown: fellBack.contains("sort"))
                ForEach(DocumentSort.allCases) { Text($0.label).tag(DocumentSort?.some($0)) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding<Bool?> {
                fellBack.contains("ascending") ? nil : view.filter.ascending
            } set: { ascending in
                guard let ascending else { return }
                view.setAscending(ascending)
                try? context.save()
            }) {
                SavedViewEditor.fallbackChoice(Bool.self, shown: fellBack.contains("ascending"))
                Text("Ascending").tag(Bool?.some(true))
                Text("Descending").tag(Bool?.some(false))
            }
            .pickerStyle(.inline)
        } else {
            Picker("Sort by", selection: $sort) {
                ForEach(DocumentSort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }

    /// "Edit View…" for a saved view, otherwise "Save as View…" filled from this list, its search
    /// and sort.
    @ViewBuilder
    private func savedViewButton(_ viewEditor: Binding<SavedViewEditorTarget?>) -> some View {
        if case .savedView(let view) = filter {
            Button("Edit View…", systemImage: "slider.horizontal.3") { viewEditor.wrappedValue = .edit(view) }
                .accessibilityIdentifier(AccessibilityID.editView)
        } else {
            Button("Save as View…", systemImage: "rectangle.stack.badge.plus") {
                let prefill = filter.savedViewPrefill(searchText: searchText, sort: sort)
                viewEditor.wrappedValue = .new(name: prefill.name, filter: prefill.filter)
            }
            .accessibilityIdentifier(AccessibilityID.saveAsView)
        }
    }

    /// The saved view in front when it refers to items that no longer exist (banner).
    private var unresolvedView: SavedView? {
        guard case .savedView(let view) = filter, viewEditor != nil,
              let (_, filterContext) = view.filterAndContext(), filterContext.hasUnresolvedReferences else { return nil }
        return view
    }

    private var isEditing: Bool {
        #if os(iOS)
        editMode?.wrappedValue.isEditing == true
        #else
        false
        #endif
    }

    #if os(iOS)
    /// "Select" enters edit mode (checkmarks, bottom toolbar on iPhone); "Done" leaves it and
    /// ends the selection.
    private func setEditing(_ editing: Bool) {
        if !editing { selection = [] }
        withAnimation { editMode?.wrappedValue = editing ? .active : .inactive }
    }
    #endif

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if filter == .duplicates {
            ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                                   description: Text("Every file is in your archive only once."))
        } else if case .savedView = filter {
            ContentUnavailableView("No Matching Documents", systemImage: SavedView.defaultSymbol,
                                   description: Text("No document matches the criteria of this view."))
        } else if filter == .inbox {
            ContentUnavailableView("Inbox Empty", systemImage: "tray",
                                   description: Text("New documents appear here until you mark them as done."))
        } else {
            ContentUnavailableView {
                Label("No Documents", systemImage: "doc.on.doc")
            } description: {
                #if os(iOS)
                Text("Scan a document with the camera or import a PDF.")
                #else
                Text("Drag PDFs or images here or import them with ⌘O.")
                #endif
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for document: Document) -> some View {
        Button(document.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: document.isFavorite ? "star.slash" : "star") {
            document.isFavorite.toggle()
            document.touch()
        }
        Button(document.isInbox ? "Mark as Done" : "Move to Inbox",
               systemImage: document.isInbox ? "tray.and.arrow.up" : "tray.and.arrow.down") {
            document.isInbox.toggle()
            document.touch()
        }
        if let transfer = document.transfer {
            ShareLink(item: transfer, preview: SharePreview(document.title)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        DocumentActionItems(document: document)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { documentToDelete = document }
    }

    private func delete(_ document: Document) {
        guard document.isAlive else { return }
        selection.remove(document.id)
        DocumentDeletion.delete([document], in: context)
    }
}

struct DocumentRow: View {
    let document: Document

    var body: some View {
        if document.isAlive {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(data: document.thumbnailData, isProcessing: document.isProcessing)
                .frame(width: 48, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(2)
                    if document.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !document.sortedTags.isEmpty {
                    TagChipsView(tags: document.sortedTags, compact: true)
                }
                if document.isProcessing {
                    Text("Text recognition running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if document.isInbox {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        // One element for VoiceOver; the label names everything the row shows.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DocumentAccessibility.label(for: document))
    }

    private var subtitle: String {
        var parts: [String] = [document.documentDate.formatted(date: .abbreviated, time: .omitted)]
        if let correspondent = document.correspondent { parts.append(correspondent.name) }
        if let type = document.documentType { parts.append(type.name) }
        return parts.joined(separator: " · ")
    }
}

/// "This view refers to deleted items – Edit View" above a saved view's documents (#14): a
/// reference that cannot be resolved makes its criterion match nothing, never more.
struct UnresolvedReferencesBanner: View {
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("This view refers to deleted items, so it may show fewer documents.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit View", action: edit)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.unresolvedBanner)
    }
}

/// A tag nested in the tag whose list is shown, with its document count.
struct SubfolderChip: Identifiable {
    let tag: Tag
    let count: Int
    var id: UUID { tag.id }

    /// The tags nested directly in the filter's tag, alphabetical, each with the documents of its
    /// subtree (one pass over `documents`). Empty for other filters and tags without nested tags.
    @MainActor
    static func chips(of filter: SidebarItem, in documents: [Document]) -> [SubfolderChip] {
        guard case .tag(let tag) = filter, TagHierarchy.isAlive(tag), !(tag.children ?? []).isEmpty else { return [] }
        let counts = TagHierarchy.subtreeCounts(documents: documents.filter(\.isAlive))
        let children = (tag.children ?? []).filter { TagHierarchy.isAlive($0) && $0.id != tag.id }
        return TagHierarchy.sortedByName(children).map { SubfolderChip(tag: $0, count: counts[$0.id] ?? 0) }
    }
}

/// "Subfolders": one chip per tag nested in the list's tag (#13), like folders above the files.
struct SubfolderBar: View {
    let subfolders: [SubfolderChip]
    /// `nil`: the chips push the tag (`NavigationLink(value: Tag)`).
    let open: ((Tag) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Subfolders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(subfolders) { chip in
                    if let open {
                        Button { open(chip.tag) } label: { label(chip) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.subfolderChip(chip.tag.name))
                    } else {
                        NavigationLink(value: chip.tag) { label(chip) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.subfolderChip(chip.tag.name))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.subfolders)
    }

    private func label(_ chip: SubfolderChip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: chip.tag.symbol)
                .foregroundStyle(chip.tag.color)
                .accessibilityHidden(true)
            Text(chip.tag.name)
                .foregroundStyle(.primary)
            if chip.count > 0 {
                Text("\(chip.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
        .contentShape(Capsule())
        // "Auto › Golf, 3 documents", a button.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TagHierarchy.displayPath(of: chip.tag))
        .accessibilityValue(DocumentAccessibility.documentCount(chip.count))
        .accessibilityAddTraits(.isButton)
    }
}

struct ThumbnailView: View {
    let data: Data?
    var isProcessing: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.background.secondary)
            if let data, let image = ImageCoding.cgImage(from: data) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if isProcessing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

struct TagChipsView: View {
    let tags: [Tag]
    var compact = false

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags) { tag in
                TagChip(tag: tag, compact: compact)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Tags: \(DocumentAccessibility.tagList(tags.map(TagHierarchy.displayPath)) ?? "")"))
    }
}

struct TagChip: View {
    let tag: Tag
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let dark = colorScheme == .dark
        Text(tag.name)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 4)
            // Opaque, so the chip reads the same on a selected row (accent or grey) as on a normal one.
            .background(Color(ColorContrast.chipBackground(tagHex: tag.colorHex, dark: dark)), in: Capsule())
            // The tag color itself is too light for small text (yellow, teal); this one is
            // adjusted to 4.5:1 on the chip background.
            .foregroundStyle(Color(ColorContrast.chipText(tagHex: tag.colorHex, dark: dark)))
            .overlay {
                if colorSchemeContrast == .increased {
                    Capsule().strokeBorder(Color(ColorContrast.chipBorder(tagHex: tag.colorHex, dark: dark)), lineWidth: 1)
                }
            }
            // The chip shows the tag's own name; the whole path ("Auto › Golf") on hover and for
            // VoiceOver (#13).
            .help(TagHierarchy.displayPath(of: tag))
            .accessibilityLabel(Text(verbatim: TagHierarchy.displayPath(of: tag)))
    }
}

extension Color {
    init(_ rgb: ColorContrast.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// A simple flow layout that wraps its elements into lines (for tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews: subviews, width: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), positions)
    }
}
