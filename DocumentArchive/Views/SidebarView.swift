import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Binding var selection: SidebarItem?
    @Binding var editorTarget: RuleEditorTarget?
    @Binding var showSettings: Bool
    /// The tag tree with disclosure triangles and drag and drop (macOS, iPad). iPhone shows only
    /// the root tags; their lists push the nested tags (`ContentView`).
    var showsTagTree = true

    @Query(filter: #Predicate<Document> { _ in true }) private var queriedDocuments: [Document]
    private var documents: [Document] { queriedDocuments.filter(\.isAlive) }
    @Query(sort: \DocumentType.name) private var documentTypes: [DocumentType]
    @Query(sort: \Correspondent.name) private var correspondents: [Correspondent]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var queriedSavedViews: [SavedView]
    /// Saved views (#14) in their order.
    private var savedViews: [SavedView] { SavedViewMaintenance.sorted(queriedSavedViews) }

    @State private var pendingDeletion: PendingDeletion?
    /// The tag whose "Move To…" sheet is open.
    @State private var movingTag: Tag?
    /// The saved view editor opened from the sidebar ("+" or a row's "Edit…").
    @State private var viewEditor: SavedViewEditorTarget?
    @State private var showViewsManager = false
    /// Expanded tags of the tree, per window and device (ids separated by commas).
    @SceneStorage("sidebar.expandedTags") private var expandedTagsStorage = ""

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row(.inbox, icon: "tray", count: documents.filter(\.isInbox).count)
                row(.all, icon: "doc.on.doc", count: documents.count)
                row(.favorites, icon: "star", count: documents.filter(\.isFavorite).count)
                row(.recent, icon: "clock", count: nil)
                let duplicateCount = MetadataMaintenance.duplicateDocumentGroups(documents).reduce(0) { $0 + $1.count - 1 }
                if duplicateCount > 0 || selection == .duplicates {
                    row(.duplicates, icon: "doc.on.doc.fill", count: duplicateCount)
                        .foregroundStyle(.orange)
                }
            }

            savedViewSection

            Section {
                ForEach(documentTypes) { type in
                    row(.documentType(type), icon: type.symbol, count: type.documentCount)
                        .contextMenu {
                            Button("Edit…", systemImage: "pencil") { editorTarget = .documentType(type) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = .documentType(type)
                            }
                        }
                }
            } header: {
                sectionHeader(String(localized: "Document Types"), id: "documentType") { editorTarget = .newDocumentType }
            }

            Section {
                ForEach(correspondents) { correspondent in
                    row(.correspondent(correspondent), icon: "person.crop.circle", count: correspondent.documentCount)
                        .contextMenu {
                            Button("Edit…", systemImage: "pencil") { editorTarget = .correspondent(correspondent) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = .correspondent(correspondent)
                            }
                        }
                }
            } header: {
                sectionHeader(String(localized: "Correspondents"), id: "correspondent") { editorTarget = .newCorrespondent }
            }

            tagSection
        }
        .accessibilityIdentifier(AccessibilityID.sidebar)
        .navigationTitle("Document Archive")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        #else
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier(AccessibilityID.settingsButton)
            }
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                SyncStatusView()
                FolderCopyStatusView()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .sheet(item: $movingTag) { tag in
            TagParentPicker(tag: tag)
        }
        .sheet(isPresented: $showViewsManager) {
            SavedViewsManager(selection: $selection)
        }
        .onChange(of: selection) { revealSelectedTag() }
        .deletionConfirmation($pendingDeletion) { $0.perform(in: context, selection: &selection) }
    }

    /// Saved views (#14), after the library. Reordering: dragging on macOS, the "Manage Views"
    /// sheet on iPhone and iPad (the sidebar list is never put into edit mode, which would turn
    /// it into a multi-selection on iOS).
    private var savedViewSection: some View {
        Section {
            let views = savedViews
            let counts = SavedViewMaintenance.counts(of: views, documents: documents, tags: tags,
                                                     correspondents: correspondents, documentTypes: documentTypes)
            ForEach(views) { view in
                savedViewRow(view, count: counts[view.id] ?? 0)
            }
            #if os(macOS)
            .onMove { source, destination in
                SavedViewMaintenance.move(savedViews, fromOffsets: source, toOffset: destination)
                try? context.save()
            }
            #endif
        } header: {
            savedViewHeader
        }
    }

    private func savedViewRow(_ view: SavedView, count: Int) -> some View {
        row(.savedView(view), icon: view.symbol, count: count)
            .contextMenu {
                Button("Edit…", systemImage: "pencil") { viewEditor = .edit(view) }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    let copy = SavedViewMaintenance.duplicate(view, among: savedViews, in: context)
                    try? context.save()
                    selection = .savedView(copy)
                }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = .savedView(view) }
            }
            .savedViewEditor(item: editorBinding(for: view)) { selection = .savedView($0) }
    }

    private var savedViewHeader: some View {
        HStack {
            Text("Views")
            Spacer()
            Menu {
                Button("Manage Views…", systemImage: "list.bullet") { showViewsManager = true }
                    .accessibilityIdentifier(AccessibilityID.manageSavedViews)
                    .disabled(savedViews.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel(String(localized: "More for Views"))
            .accessibilityIdentifier(AccessibilityID.savedViewsMenu)
            Button { viewEditor = .new(name: "", filter: DocumentFilter()) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Views: create new"))
            .accessibilityLabel(String(localized: "Add View"))
            .accessibilityIdentifier(AccessibilityID.sidebarAdd("savedView"))
            .savedViewEditor(item: newEditorBinding) { selection = .savedView($0) }
        }
    }

    /// The editor of one row: presented from that row, so the popover points at it.
    private func editorBinding(for view: SavedView) -> Binding<SavedViewEditorTarget?> {
        Binding {
            if case .edit(let edited) = viewEditor, edited.id == view.id { viewEditor } else { nil }
        } set: { viewEditor = $0 }
    }

    private var newEditorBinding: Binding<SavedViewEditorTarget?> {
        Binding {
            if case .new = viewEditor { viewEditor } else { nil }
        } set: { viewEditor = $0 }
    }

    /// The tags as a tree (#13), roots only on iPhone. Counts include the tags nested in a tag, each document once
    /// (one pass). Dropping a tag on the header makes it a top-level tag.
    private var tagSection: some View {
        Section {
            let counts = TagHierarchy.subtreeCounts(documents: documents)
            let nodes = TagHierarchy.tree(of: tags)
            ForEach(TagTreeRow.visibleRows(nodes, expanded: showsTagTree ? expandedTags.wrappedValue : [])) { entry in
                TagTreeRow(entry: entry, count: counts[entry.id] ?? 0, expanded: expandedTags,
                           showsTree: showsTagTree, allowsDragAndDrop: showsTagTree, actions: tagActions)
            }
        } header: {
            sectionHeader(String(localized: "Tags"), id: "tag") { editorTarget = .newTag }
                .dropDestination(for: TagReference.self) { references, _ in
                    TagHierarchy.moveDropped(references, under: nil, in: context)
                }
        }
    }

    private var tagActions: TagTreeRow.Actions {
        TagTreeRow.Actions(
            edit: { editorTarget = .tag($0) },
            newSubtag: { editorTarget = .newSubtag(of: $0) },
            move: { movingTag = $0 },
            moveToTopLevel: { tag in
                TagHierarchy.move(tag, under: nil)
                try? context.save()
            },
            delete: { pendingDeletion = .tag($0) },
            drop: { references, tag in
                let moved = TagHierarchy.moveDropped(references, under: tag, in: context)
                if moved { expandedTags.wrappedValue.insert(tag.id) }
                return moved
            }
        )
    }

    private var expandedTags: Binding<Set<UUID>> {
        Binding {
            Set(expandedTagsStorage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        } set: { ids in
            expandedTagsStorage = ids.map(\.uuidString).sorted().joined(separator: ",")
        }
    }

    /// A nested tag selected elsewhere (a subfolder chip in the list) is shown: its ancestors
    /// are expanded.
    private func revealSelectedTag() {
        guard showsTagTree, case .tag(let tag) = selection else { return }
        let ancestors = Set(TagHierarchy.ancestors(of: tag).map(\.id))
        if !ancestors.isSubset(of: expandedTags.wrappedValue) {
            expandedTags.wrappedValue.formUnion(ancestors)
        }
    }

    private func row(_ item: SidebarItem, icon: String, count: Int?) -> some View {
        NavigationLink(value: item) {
            HStack {
                Label(item.title, systemImage: icon)
                Spacer()
                if let count { countBadge(count) }
            }
            // "Inbox, 3 documents" instead of the label and a bare number
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue(count.map(DocumentAccessibility.documentCount) ?? "")
        }
        .accessibilityIdentifier(AccessibilityID.sidebarRow(item))
    }

    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String, id: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "\(title): create new"))
            .accessibilityLabel(String(localized: "Add \(title)"))
            .accessibilityIdentifier(AccessibilityID.sidebarAdd(id))
        }
    }

    enum PendingDeletion {
        case tag(Tag), correspondent(Correspondent), documentType(DocumentType), savedView(SavedView)

        /// Without the name once the object is gone (deleted on another device while the dialog
        /// is open).
        var title: String {
            switch self {
            case .tag(let t): String(localized: "Delete tag “\(Self.name(t, t.name))”?")
            case .correspondent(let c): String(localized: "Delete correspondent “\(Self.name(c, c.name))”?")
            case .documentType(let d): String(localized: "Delete document type “\(Self.name(d, d.name))”?")
            case .savedView(let v): String(localized: "Delete view “\(Self.name(v, v.name))”?")
            }
        }

        var message: String {
            if case .savedView = self {
                return String(localized: "Only the view is deleted, on all devices. The documents themselves are kept.")
            }
            if case .tag(let tag) = self, !tag.isDeleted, tag.modelContext != nil, !(tag.children ?? []).isEmpty {
                return String(localized: "The documents themselves are kept. Tags nested in this tag move up one level.")
            }
            return String(localized: "The documents themselves are kept.")
        }

        private static func name(_ model: some PersistentModel, _ name: String) -> String {
            model.isDeleted || model.modelContext == nil ? "" : name
        }
    }

}

extension SidebarView.PendingDeletion {
    /// Deletes the confirmed object (through `TagHierarchy` / `MetadataDeletion`, so the folder
    /// copy records it) and shows "All Documents" instead when it was shown. Nothing happens
    /// for a saved view that is already gone (deleted on another device while the dialog was
    /// open).
    @MainActor func perform(in context: ModelContext, selection: inout SidebarItem?) {
        switch self {
        case .tag(let tag):
            if selection == .tag(tag) { selection = .all }
            TagHierarchy.delete(tag, in: context, recorder: DocumentDeletion.recorder())
        case .correspondent(let correspondent):
            if selection == .correspondent(correspondent) { selection = .all }
            MetadataDeletion.delete(correspondent, in: context, recorder: DocumentDeletion.recorder())
        case .documentType(let type):
            if selection == .documentType(type) { selection = .all }
            MetadataDeletion.delete(type, in: context, recorder: DocumentDeletion.recorder())
        case .savedView(let view):
            guard !view.isDeleted, view.modelContext != nil else { return }
            if selection == .savedView(view) { selection = .all }
            MetadataDeletion.delete(view, in: context, recorder: DocumentDeletion.recorder())
        }
        try? context.save()
    }
}

extension View {
    /// The confirmation before deleting a tag, correspondent, document type or saved view: the
    /// sidebar and the "Manage Views" sheet ask the same way (the deletion reaches all devices
    /// and cannot be undone).
    func deletionConfirmation(_ pending: Binding<SidebarView.PendingDeletion?>,
                              perform: @escaping (SidebarView.PendingDeletion) -> Void) -> some View {
        confirmationDialog(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(presenting: pending),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { deletion in
            Button("Delete", role: .destructive) { perform(deletion) }
                .accessibilityIdentifier(AccessibilityID.deletionConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
    }
}

struct SyncStatusView: View {
    private var monitor = SyncMonitor.shared

    var body: some View {
        HStack(spacing: 6) {
            switch monitor.state {
            case _ where !monitor.isCloudKitEnabled:
                Image(systemName: "externaldrive")
                Text("Stored locally only – no iCloud sync")
            case _ where !monitor.isICloudSignedIn:
                Image(systemName: "icloud.slash")
                Text("Not signed in to iCloud")
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case .failed:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                Text("Sync error – see Settings")
            case .succeeded(let date):
                Image(systemName: "checkmark.icloud")
                Text("Synced \(date.formatted(.relative(presentation: .named)))")
            case .idle:
                Image(systemName: "icloud")
                Text("iCloud – waiting for the first sync")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
