import PhotosUI
import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case inbox
    case all
    case favorites
    case recent
    case duplicates
    case documentType(DocumentType)
    case correspondent(Correspondent)
    case tag(Tag)

    var title: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .all: String(localized: "All Documents")
        case .favorites: String(localized: "Favorites")
        case .recent: String(localized: "Recently Added")
        case .duplicates: String(localized: "Duplicates")
        case .documentType(let type): type.name
        case .correspondent(let correspondent): correspondent.name
        case .tag(let tag): tag.name
        }
    }

    func includes(_ document: Document) -> Bool {
        documentFilter()(document)
    }

    /// The test `includes` applies, prepared once for a whole list: a tag's subtree is computed
    /// once, not per document. A tag includes the documents of the tags nested in it.
    func documentFilter() -> (Document) -> Bool {
        if case .tag(let tag) = self {
            let ids = TagHierarchy.subtreeIDs(of: tag)
            return { document in document.tags?.contains { ids.contains($0.id) } ?? false }
        }
        return { document in self.matchesWithoutTags(document) }
    }

    private func matchesWithoutTags(_ document: Document) -> Bool {
        switch self {
        case .inbox: document.isInbox
        case .all: true
        case .favorites: document.isFavorite
        case .recent: document.createdAt > Date().addingTimeInterval(-60 * 60 * 24 * 30)
        case .duplicates: false // needs all documents, see DocumentListView
        case .documentType(let type): document.documentType?.id == type.id
        case .correspondent(let correspondent): document.correspondent?.id == correspondent.id
        case .tag(let tag): document.hasTag(tag) // handled by `documentFilter`
        }
    }
}

/// Which editor for tags, correspondents or document types is open.
enum RuleEditorTarget: Identifiable {
    case newTag, newCorrespondent, newDocumentType
    /// A new tag nested in the given one ("New Subtag…" in the sidebar).
    case newSubtag(of: Tag)
    case tag(Tag), correspondent(Correspondent), documentType(DocumentType)

    var id: String {
        switch self {
        case .newTag: "new-tag"
        case .newSubtag(let parent): "new-tag-in-\(parent.id)"
        case .newCorrespondent: "new-correspondent"
        case .newDocumentType: "new-type"
        case .tag(let t): "tag-\(t.id)"
        case .correspondent(let c): "correspondent-\(c.id)"
        case .documentType(let d): "type-\(d.id)"
        }
    }
}

/// Which columns an iPad shows around the open document (regular width only; iPhone and macOS
/// leave this to the system).
enum SplitLayout {
    /// Narrower windows show the list over the document instead of beside it.
    static let sideBySideMinimumWidth: CGFloat = 1000

    /// Narrow windows (iPad mini, iPad Air in portrait) show only the document; the list stays
    /// one tap away (`showList`). Wider windows keep the list beside the document.
    static func columnsAfterOpeningDocument(windowWidth: CGFloat) -> NavigationSplitViewVisibility {
        windowWidth < sideBySideMinimumWidth ? .detailOnly : .doubleColumn
    }

    /// The open document was closed (deleted): if only the document column was shown, nothing
    /// but an empty column would be left, so the list comes back. Other choices stay.
    static func columnsAfterClosingDocument(_ current: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        current == .detailOnly ? .doubleColumn : current
    }

    /// The window width changed while a document is open (rotation, Stage Manager). The columns
    /// are chosen again only when the width crosses `sideBySideMinimumWidth`, so a smaller resize
    /// keeps what the user chose. `nil`: keep the current columns.
    static func columnsAfterResize(from oldWidth: CGFloat, to newWidth: CGFloat) -> NavigationSplitViewVisibility? {
        guard (oldWidth < sideBySideMinimumWidth) != (newWidth < sideBySideMinimumWidth) else { return nil }
        return columnsAfterOpeningDocument(windowWidth: newWidth)
    }
}

/// iPhone drill-down through nested tags (#13): the content column's `NavigationStack` path.
enum TagNavigation {
    /// Whether the pushed tags still belong below the sidebar's selection: the first is nested
    /// directly in the selected tag and each further one in the one before. Otherwise (another
    /// sidebar entry, a tag moved elsewhere) the path is dropped. An empty path always fits.
    static func path(_ path: [Tag], continues selection: SidebarItem?) -> Bool {
        guard let first = path.first else { return true }
        guard case .tag(let root) = selection, first.parent?.id == root.id else { return false }
        return zip(path, path.dropFirst()).allSatisfy { parent, child in child.parent?.id == parent.id }
    }
}

struct ImportNotice {
    var title: String
    var message: String
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \Document.createdAt, order: .reverse) private var allDocuments: [Document]
    @AppStorage("documentSort") private var sort: DocumentSort = .added

    @State private var sidebarSelection: SidebarItem? = .all
    /// The selected documents (see `DocumentSelection` for the rules).
    @State private var selection: Set<Document.ID> = []
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var bulkActions = BulkActionCoordinator()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var windowWidth: CGFloat = 0
    @State private var editMode = EditMode.inactive
    /// iPhone (#13): the nested tags pushed from a tag's list onto the content column's
    /// `NavigationStack`, deepest last. The native back button returns to the parent tag.
    @State private var tagPath: [Tag] = []
    #endif

    @State private var showFileImporter = false
    @State private var showScanner = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var editorTarget: RuleEditorTarget?
    @State private var importNotice: ImportNotice?
    private let externalImport = ExternalImport.shared

    /// What the list in front shows; the selection only ever refers to these documents.
    private var visibleDocuments: [Document] {
        documents(for: listFilter)
    }

    private func documents(for filter: SidebarItem) -> [Document] {
        filter.visibleDocuments(in: allDocuments, searchText: searchText, sort: sort)
    }

    /// The filter of the list in front: on iPhone the deepest pushed tag, otherwise the
    /// sidebar's choice.
    private var listFilter: SidebarItem {
        #if os(iOS)
        if isCompact, let tag = tagPath.last { return .tag(tag) }
        #endif
        return sidebarSelection ?? .all
    }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        // Split into parts: one long modifier chain is too much for the type checker of older
        // Xcode versions (CI).
        externalFiles(dialogs(presentations(selectionTracking(splitView))))
    }

    @ViewBuilder
    private var splitView: some View {
        let visibleDocuments = visibleDocuments
        let selectedDocuments = DocumentSelection.resolve(selection, in: visibleDocuments)
        // The open document stays open while an edit hides it from the list (see DocumentSelection).
        let openDocument = DocumentSelection.openDocument(selection, in: allDocuments)
            ?? (selectedDocuments.count == 1 ? selectedDocuments.first : nil)
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection, editorTarget: $editorTarget, showSettings: $showSettings,
                        showsTagTree: !isCompact)
        } content: {
            contentColumn(visibleDocuments: visibleDocuments)
        } detail: {
            Group {
                if let document = openDocument {
                    DocumentDetailView(document: document, editorTarget: $editorTarget) {
                        selection.remove(document.id)
                    }
                    .id(document.id)
                } else if selectedDocuments.count > 1 {
                    BulkActionsView(documents: selectedDocuments)
                } else {
                    ContentUnavailableView("No Document Selected", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Select a document on the left or add a new one."))
                }
            }
            #if os(iOS)
            // On the whole column, so the way back is also there when the open document is gone
            // (deleted in another window or by sync) and only the empty state is left.
            .toolbar {
                if showsListButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Show List", systemImage: "sidebar.leading") { columnVisibility = .doubleColumn }
                            .accessibilityIdentifier(AccessibilityID.showList)
                    }
                }
            }
            // Our own button instead of the system one: iPadOS 26 showed no sidebar button
            // at all for an opened document, so there was no way back to the list.
            .toolbar(removing: showsListButton ? .sidebarToggle : nil)
            #endif
        }
    }

    /// The document list; on iPhone inside its own `NavigationStack`, which pushes the lists of
    /// nested tags (subfolder chips) with `navigationDestination(for: Tag.self)` (#13).
    @ViewBuilder
    private func contentColumn(visibleDocuments: [Document]) -> some View {
        #if os(iOS)
        if isCompact {
            NavigationStack(path: $tagPath) {
                documentList(sidebarSelection ?? .all, documents: tagPath.isEmpty ? visibleDocuments : nil)
                    .navigationDestination(for: Tag.self) { tag in
                        documentList(.tag(tag), documents: tagPath.last?.id == tag.id ? visibleDocuments : nil)
                            // Like the list it was pushed from (a pushed list defaults to inset grouped).
                            .listStyle(.plain)
                    }
            }
        } else {
            documentList(listFilter, documents: visibleDocuments)
        }
        #else
        documentList(listFilter, documents: visibleDocuments)
        #endif
    }

    /// One list. `documents`: the visible documents when this is the list in front; lists below
    /// it on the iPhone's stack compute their own.
    private func documentList(_ filter: SidebarItem, documents: [Document]?) -> some View {
        DocumentListView(
            filter: filter,
            searchText: searchText,
            documents: documents ?? self.documents(for: filter),
            selection: listSelection,
            showsBulkToolbar: showsBulkToolbar,
            importMenu: { importMenu },
            onDropFiles: { report(DocumentImporter.importDropped($0, into: context)) },
            subfolders: SubfolderChip.chips(of: filter, in: allDocuments),
            openSubfolder: isCompact ? nil : { sidebarSelection = .tag($0) }
        )
        .searchable(text: $searchText, prompt: "Search full text")
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
    }

    /// Keeps the selection and the iPad columns in step with what the list shows.
    private func selectionTracking(_ content: some View) -> some View {
        content
        .environment(bulkActions)
        .onChange(of: sidebarSelection) {
            selection = []
            #if os(iOS)
            editMode = .inactive
            if !TagNavigation.path(tagPath, continues: sidebarSelection) { tagPath = [] }
            #endif
        }
        #if os(iOS)
        // Another list in front on iPhone (a nested tag pushed or popped): like a sidebar change.
        .onChange(of: tagPath) {
            selection = []
            editMode = .inactive
        }
        // iPhone and iPad windows can change between compact and regular width (Split View,
        // Plus/Max iPhones in landscape): the tag in front stays in front.
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            if sizeClass == .compact, case .tag(let tag) = sidebarSelection, tag.parent != nil {
                let path = TagHierarchy.path(of: tag)
                tagPath = Array(path.dropFirst())
                sidebarSelection = path.first.map(SidebarItem.tag)
            } else if sizeClass != .compact, let tag = tagPath.last {
                sidebarSelection = .tag(tag)
            }
        }
        #endif
        // Search text, sync or an action changed what is visible: nothing hidden stays selected.
        .onChange(of: visibleDocuments.map(\.id)) {
            prune(keepingOpen: true)
        }
        // A new search closes an open document it hides.
        .onChange(of: searchText) {
            prune(keepingOpen: false)
        }
        #if os(iOS)
        .onChange(of: editMode.isEditing) { _, isEditing in
            guard isEditing else { return }
            let pruned = DocumentSelection.enteringEditMode(selection, visible: visibleDocuments)
            if pruned != selection { selection = pruned }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onChange(of: openDocumentID) {
            guard horizontalSizeClass == .regular, !editMode.isEditing else { return }
            if openDocumentID != nil {
                bringOpenDocumentToFront()
            } else {
                columnVisibility = SplitLayout.columnsAfterClosingDocument(columnVisibility)
            }
        }
        .onChange(of: windowWidth) { oldWidth, newWidth in
            guard horizontalSizeClass == .regular, openDocumentID != nil,
                  let columns = SplitLayout.columnsAfterResize(from: oldWidth, to: newWidth) else { return }
            columnVisibility = columns
        }
        #endif
    }

    /// Import pickers, the scanner and the sheets.
    private func presentations(_ content: some View) -> some View {
        content
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: DocumentImporter.importableTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): importNotice = ImportNotice(title: String(localized: "Import failed"), message: error.localizedDescription)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { pages in
                showScanner = false
                let result = ScanImport.importScan(pages, into: context)
                importNotice = result.notice
                if case .imported(let document, _) = result {
                    select(document)
                }
            } onCancel: {
                showScanner = false
            } onError: { error in
                showScanner = false
                importNotice = ImportNotice(title: String(localized: "Scan failed"), message: error.localizedDescription)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .accessibilityIdentifier(AccessibilityID.settings)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                                .accessibilityIdentifier(AccessibilityID.settingsDone)
                        }
                    }
            }
        }
        #endif
        .sheet(item: $editorTarget) { target in
            RuleEditorView(target: target)
        }
    }

    /// Confirmations, notices, menu actions and launch work.
    private func dialogs(_ content: some View) -> some View {
        content
        .confirmationDialog(Text(deleteTitle), isPresented: Binding(presenting: $bulkActions.pendingDelete),
                            titleVisibility: .visible, presenting: bulkActions.pendingDelete) { request in
            Button("Delete", role: .destructive) { deleteConfirmed(request) }
                .accessibilityIdentifier(AccessibilityID.bulkDeleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(Self.deleteMessage(for: request.documents))
        }
        .confirmationDialog(Text(reanalysisTitle), isPresented: Binding(presenting: $bulkActions.pendingReanalysis),
                            titleVisibility: .visible, presenting: bulkActions.pendingReanalysis) { request in
            Button("Analyze Again") {
                bulkActions.startReanalysis(DocumentSelection.resolve(Set(request.documents.map(\.id)), in: visibleDocuments),
                                            context: context)
            }
            .accessibilityIdentifier(AccessibilityID.bulkReanalyzeConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(Self.reanalysisMessage(usesMistral: MistralConfig.current().map { $0.useOCR || $0.useLLM } ?? false))
        }
        .alert(importNotice?.title ?? "", isPresented: Binding(presenting: $importNotice), presenting: importNotice) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
        .focusedSceneValue(\.appActions, AppActions(
            importFiles: { showFileImporter = true },
            newTag: { editorTarget = .newTag },
            newCorrespondent: { editorTarget = .newCorrespondent },
            newDocumentType: { editorTarget = .newDocumentType },
            showSettings: { showSettings = true }
        ))
        // The folder copy catches up with changes made while the app was in the background.
        .onChange(of: scenePhase) {
            if scenePhase == .active { ArchiveMirrorController.shared.syncNow() }
        }
        .task {
            DocumentType.upgradeDefaults(in: context)
            MetadataMaintenance.mergeDuplicates(in: context)
            DocumentImporter.backfillHashes(in: context)
            DocumentImporter.resumePendingProcessing(in: context)
        }
    }

    /// Files opened from other apps ("Open with", the Dock icon, "Open in…"): this window receives
    /// them instead of a new one, imports them through `ExternalImport` and shows the result like
    /// an import from the file dialog.
    private func externalFiles(_ content: some View) -> some View {
        content
        .onOpenURL { OpenURLHandler.handle($0) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onChange(of: externalImport.pendingResult != nil) { _, hasResult in
            if hasResult { showExternalImportResult() }
        }
        .onAppear {
            // Files opened at launch waited for the archive; they are imported now.
            externalImport.context = context
            showExternalImportResult()
        }
    }

    private func showExternalImportResult() {
        if let result = externalImport.takeResult() { report(result) }
    }

    /// The list's selection. Tapping the document that is already open sets the same value,
    /// so `onChange(of: openDocumentID)` does not fire; on iPad it must still bring the
    /// document back to the front when the list was laid over it (Show List in a narrow window).
    private var listSelection: Binding<Set<Document.ID>> {
        Binding<Set<Document.ID>>(get: { selection }, set: { (newSelection: Set<Document.ID>) in
            #if os(iOS)
            if newSelection.count == 1, newSelection == selection, horizontalSizeClass == .regular, !editMode.isEditing {
                bringOpenDocumentToFront()
            }
            #endif
            // Adding rows to a hidden open document must not keep it in the bulk selection.
            selection = DocumentSelection.fromList(newSelection, visible: visibleDocuments)
        })
    }

    /// Removes hidden documents from the selection. `keepingOpen`: the open document stays,
    /// because the list changed through an edit (not in edit mode, where bulk rules apply).
    private func prune(keepingOpen: Bool) {
        var open: Document?
        if keepingOpen {
            #if os(iOS)
            if !editMode.isEditing { open = DocumentSelection.openDocument(selection, in: allDocuments) }
            #else
            open = DocumentSelection.openDocument(selection, in: allDocuments)
            #endif
        }
        let pruned = DocumentSelection.pruned(selection, to: visibleDocuments, keepingOpen: open)
        if pruned != selection { selection = pruned }
    }

    /// The one selected document, which the detail column shows; `nil` for none or several.
    private var openDocumentID: Document.ID? {
        selection.count == 1 ? selection.first : nil
    }

    private var deleteTitle: String {
        let count = bulkActions.pendingDelete?.documents.count ?? 0
        return count == 1 ? String(localized: "Delete document?") : String(localized: "Delete \(count) documents?")
    }

    static func deleteMessage(for documents: [Document]) -> String {
        if documents.count == 1, let document = documents.first {
            return String(localized: "“\(document.isAlive ? document.title : "")” will be deleted on all devices.")
        }
        return String(localized: "\(documents.count) documents will be deleted on all devices.")
    }

    private var reanalysisTitle: String {
        let count = bulkActions.pendingReanalysis?.documents.count ?? 0
        return count == 1 ? String(localized: "Analyze 1 document again?")
                          : String(localized: "Analyze \(count) documents again?")
    }

    static func reanalysisMessage(usesMistral: Bool) -> String {
        let text = String(localized: "Text recognition and automatic assignment run again, one document after another. Correspondent, type, tags and date may change.")
        guard usesMistral else { return text }
        return text + " " + String(localized: "As set in the settings, the documents are sent to Mistral AI.")
    }

    /// Deletes what is still selected and visible of the confirmed documents.
    private func deleteConfirmed(_ request: BulkRequest) {
        let documents = DocumentSelection.resolve(Set(request.documents.map(\.id)), in: visibleDocuments)
        selection.subtract(documents.map(\.id))
        DocumentDeletion.delete(documents, in: context)
    }

    private var showsBulkToolbar: Bool {
        #if os(iOS)
        // Wide iPad windows show `BulkActionsView` beside the list instead.
        horizontalSizeClass == .compact || windowWidth < SplitLayout.sideBySideMinimumWidth
        #else
        false
        #endif
    }

    #if os(iOS)
    /// Only the document is shown on an iPad: offer the way back to the list. On iPhone the
    /// navigation bar's back button does that.
    private var showsListButton: Bool {
        horizontalSizeClass == .regular && columnVisibility == .detailOnly
    }

    /// The opened document comes to the front. Forcing all columns kept the list laid over the
    /// document in portrait (iPad mini), and the first tap only closed the list.
    private func bringOpenDocumentToFront() {
        columnVisibility = SplitLayout.columnsAfterOpeningDocument(windowWidth: windowWidth)
    }
    #endif

    @ViewBuilder
    private var importMenu: some View {
        Menu {
            #if os(iOS)
            if DocumentScannerView.isSupported {
                Button("Scan Document", systemImage: "doc.viewfinder") { showScanner = true }
            }
            #endif
            Button("Import from Files", systemImage: "folder") { showFileImporter = true }
            Button("Import from Photos", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
        } label: {
            Label("Add", systemImage: "plus")
        } primaryAction: {
            #if os(iOS)
            if DocumentScannerView.isSupported { showScanner = true } else { showFileImporter = true }
            #else
            showFileImporter = true
            #endif
        }
    }

    private func importFiles(_ urls: [URL]) {
        report(DocumentImporter.importFiles(urls, into: context))
    }

    /// Tells about skipped duplicates and errors, and opens what was imported.
    private func report(_ result: DocumentImporter.ImportResult) {
        if let notice = result.notice { importNotice = notice }
        if let (document, isNew) = result.documentToOpen {
            if isNew { select(document) } else { showExisting(document) }
        }
    }

    private func showExisting(_ document: Document) {
        prepareToShow(document)
        if listFilter.includes(document) {
            selection = [document.id]
        } else {
            sidebarSelection = .all
            Task { @MainActor in selection = [document.id] }
        }
    }

    /// Before opening a document: leave edit mode, and clear a search that would hide it (the
    /// selection only keeps visible documents).
    private func prepareToShow(_ document: Document) {
        #if os(iOS)
        editMode = .inactive
        #endif
        if !document.matches(searchText) { searchText = "" }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var images: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { images.append(data) }
        }
        photoItems = []
        let result = DocumentImporter.importImageData(images, into: context)
        if let document = result.document {
            if result.isDuplicate {
                importNotice = ImportNotice(title: String(localized: "Already in the archive"),
                                            message: String(localized: "These photos were already imported as “\(document.title)”."))
                showExisting(document)
            } else {
                select(document)
            }
        } else {
            importNotice = ImportNotice(title: String(localized: "Import failed"),
                                        message: String(localized: "The selected photos could not be loaded."))
        }
    }

    private func select(_ document: Document) {
        prepareToShow(document)
        // New documents are in the inbox; switch there if needed, so they are visible.
        if let filter = sidebarSelection, filter != .inbox, filter != .all, filter != .recent {
            sidebarSelection = .inbox
            // Select only after `onChange(of: sidebarSelection)` has reset the selection
            Task { @MainActor in selection = [document.id] }
        } else {
            selection = [document.id]
        }
    }
}
