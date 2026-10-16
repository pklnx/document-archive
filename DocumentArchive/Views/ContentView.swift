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
        switch self {
        case .inbox: document.isInbox
        case .all: true
        case .favorites: document.isFavorite
        case .recent: document.createdAt > Date().addingTimeInterval(-60 * 60 * 24 * 30)
        case .duplicates: false // needs all documents, see DocumentListView
        case .documentType(let type): document.documentType?.id == type.id
        case .correspondent(let correspondent): document.correspondent?.id == correspondent.id
        case .tag(let tag): document.hasTag(tag)
        }
    }
}

/// Which editor for tags, correspondents or document types is open.
enum RuleEditorTarget: Identifiable {
    case newTag, newCorrespondent, newDocumentType
    case tag(Tag), correspondent(Correspondent), documentType(DocumentType)

    var id: String {
        switch self {
        case .newTag: "new-tag"
        case .newCorrespondent: "new-correspondent"
        case .newDocumentType: "new-type"
        case .tag(let t): "tag-\(t.id)"
        case .correspondent(let c): "correspondent-\(c.id)"
        case .documentType(let d): "type-\(d.id)"
        }
    }
}

/// Which columns an iPad shows once a document is opened.
enum SplitLayout {
    /// Narrower windows show the list over the document instead of beside it.
    static let sideBySideMinimumWidth: CGFloat = 1000

    /// Narrow windows (iPad mini, iPad Air in portrait) show only the document; the list stays
    /// one tap away (`showList`). Wider windows keep the list beside the document.
    static func columnsAfterOpeningDocument(windowWidth: CGFloat) -> NavigationSplitViewVisibility {
        windowWidth < sideBySideMinimumWidth ? .detailOnly : .doubleColumn
    }
}

struct ImportNotice {
    var title: String
    var message: String
}

struct ContentView: View {
    @Environment(\.modelContext) private var context

    @State private var sidebarSelection: SidebarItem? = .all
    @State private var selectedDocument: Document?
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var windowWidth: CGFloat = 0
    #endif

    @State private var showFileImporter = false
    @State private var showScanner = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var editorTarget: RuleEditorTarget?
    @State private var importNotice: ImportNotice?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection, editorTarget: $editorTarget, showSettings: $showSettings)
        } content: {
            DocumentListView(
                filter: sidebarSelection ?? .all,
                searchText: searchText,
                selection: $selectedDocument,
                importMenu: { importMenu },
                onDropFiles: { report(DocumentImporter.importDropped($0, into: context)) }
            )
            .searchable(text: $searchText, prompt: "Search full text")
        } detail: {
            if let selectedDocument, selectedDocument.isAlive {
                DocumentDetailView(document: selectedDocument, editorTarget: $editorTarget) {
                    self.selectedDocument = nil
                }
                .id(selectedDocument.id)
                #if os(iOS)
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
            } else {
                ContentUnavailableView("No Document Selected", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Select a document on the left or add a new one."))
            }
        }
        .onChange(of: sidebarSelection) { selectedDocument = nil }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onChange(of: selectedDocument) {
            // The opened document comes to the front. Forcing all columns kept the list laid
            // over the document in portrait (iPad mini), and the first tap only closed the list.
            if selectedDocument != nil, horizontalSizeClass == .regular {
                columnVisibility = SplitLayout.columnsAfterOpeningDocument(windowWidth: windowWidth)
            }
        }
        #endif
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
        .task {
            DocumentType.upgradeDefaults(in: context)
            MetadataMaintenance.mergeDuplicates(in: context)
            DocumentImporter.backfillHashes(in: context)
            DocumentImporter.resumePendingProcessing(in: context)
        }
    }

    #if os(iOS)
    /// Only the document is shown on an iPad: offer the way back to the list. On iPhone the
    /// navigation bar's back button does that.
    private var showsListButton: Bool {
        horizontalSizeClass == .regular && columnVisibility == .detailOnly
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
        var lines: [String] = []
        if !result.duplicates.isEmpty {
            lines.append(result.duplicates.count == 1
                ? String(localized: "This file is already in the archive and was skipped:")
                : String(localized: "\(result.duplicates.count) files are already in the archive and were skipped:"))
            lines += result.duplicates.map { String(localized: "• \($0.fileName) → “\($0.existing.title)”") }
        }
        lines += result.errors.map(\.localizedDescription)
        if !lines.isEmpty {
            let title = result.errors.isEmpty
                ? (result.imported.isEmpty ? String(localized: "Already in the archive")
                                           : String(localized: "\(result.imported.count) imported, duplicates skipped"))
                : String(localized: "Import partly failed")
            importNotice = ImportNotice(title: title, message: lines.joined(separator: "\n"))
        }
        if result.imported.count == 1, let document = result.imported.first {
            select(document)
        } else if result.imported.isEmpty, result.duplicates.count == 1, let existing = result.duplicates.first?.existing {
            showExisting(existing)
        }
    }

    private func showExisting(_ document: Document) {
        if let filter = sidebarSelection, filter.includes(document) {
            selectedDocument = document
        } else {
            sidebarSelection = .all
            Task { @MainActor in selectedDocument = document }
        }
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
        // New documents are in the inbox; switch there if needed, so they are visible.
        if let filter = sidebarSelection, filter != .inbox, filter != .all, filter != .recent {
            sidebarSelection = .inbox
            // Select only after `onChange(of: sidebarSelection)` has reset the selection
            Task { @MainActor in selectedDocument = document }
        } else {
            selectedDocument = document
        }
    }
}
