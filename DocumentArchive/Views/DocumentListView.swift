import SwiftData
import SwiftUI

enum DocumentSort: String, CaseIterable, Identifiable {
    case added, documentDate, title, correspondent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .added: String(localized: "Added")
        case .documentDate: String(localized: "Issue date")
        case .title: String(localized: "Title")
        case .correspondent: String(localized: "Correspondent")
        }
    }
}

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
        let filtered = allDocuments.filter { includes($0) && $0.matches(searchText) }
        switch sort {
        case .added:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .documentDate:
            return filtered.sorted { $0.documentDate > $1.documentDate }
        case .title:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .correspondent:
            return filtered.sorted {
                ($0.correspondent?.name ?? "~").localizedStandardCompare($1.correspondent?.name ?? "~") == .orderedAscending
            }
        }
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

    @AppStorage("documentSort") private var sort: DocumentSort = .added
    @State private var isDropTargeted = false
    @State private var documentToDelete: Document?
    @State private var confirmRemoveDuplicates = false

    private var selectedDocuments: [Document] { DocumentSelection.resolve(selection, in: documents) }

    var body: some View {
        List(selection: $selection) {
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
                    .draggable(document.transfer ?? PDFTransfer(data: Data(), fileName: String(localized: "Document") + ".pdf"))
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
            Text("“\(document.isAlive ? document.title : "")” will be deleted on all devices.")
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
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(DocumentSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
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
        Button("Delete", systemImage: "trash", role: .destructive) {
            MenuPresentation.afterMenuCloses { documentToDelete = document }
        }
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
        .accessibilityLabel(String(localized: "Tags: \(DocumentAccessibility.tagList(tags.map(\.name)) ?? "")"))
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
