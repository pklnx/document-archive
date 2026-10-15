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
        case .inbox: "Posteingang"
        case .all: "Alle Dokumente"
        case .favorites: "Favoriten"
        case .recent: "Zuletzt hinzugefügt"
        case .duplicates: "Duplikate"
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
        case .duplicates: false // braucht alle Dokumente, siehe DocumentListView
        case .documentType(let type): document.documentType?.id == type.id
        case .correspondent(let correspondent): document.correspondent?.id == correspondent.id
        case .tag(let tag): document.hasTag(tag)
        }
    }
}

/// Welcher Editor für Tags, Korrespondenten oder Dokumenttypen gerade offen ist.
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
                onDropFiles: importFiles
            )
            .searchable(text: $searchText, prompt: "Volltext durchsuchen")
        } detail: {
            if let selectedDocument, selectedDocument.isAlive {
                DocumentDetailView(document: selectedDocument, editorTarget: $editorTarget) {
                    self.selectedDocument = nil
                }
                .id(selectedDocument.id)
            } else {
                ContentUnavailableView("Kein Dokument ausgewählt", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Wähle links ein Dokument aus oder füge ein neues hinzu."))
            }
        }
        .onChange(of: sidebarSelection) { selectedDocument = nil }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: DocumentImporter.importableTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): importNotice = ImportNotice(title: "Import fehlgeschlagen", message: error.localizedDescription)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                if let document = DocumentImporter.importImages(images, source: .scan, into: context) {
                    select(document)
                }
            } onCancel: {
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showSettings = false }
                        }
                    }
            }
        }
        #endif
        .sheet(item: $editorTarget) { target in
            RuleEditorView(target: target)
        }
        .alert(importNotice?.title ?? "", isPresented: .constant(importNotice != nil)) {
            Button("OK") { importNotice = nil }
        } message: {
            Text(importNotice?.message ?? "")
        }
        .focusedSceneValue(\.importActions, ImportActions(
            importFiles: { showFileImporter = true },
            newTag: { editorTarget = .newTag },
            newCorrespondent: { editorTarget = .newCorrespondent },
            newDocumentType: { editorTarget = .newDocumentType }
        ))
        .task {
            DocumentType.upgradeDefaults(in: context)
            MetadataMaintenance.mergeDuplicates(in: context)
            DocumentImporter.backfillHashes(in: context)
            DocumentImporter.resumePendingProcessing(in: context)
        }
    }

    @ViewBuilder
    private var importMenu: some View {
        Menu {
            #if os(iOS)
            if DocumentScannerView.isSupported {
                Button("Dokument scannen", systemImage: "doc.viewfinder") { showScanner = true }
            }
            #endif
            Button("Aus Dateien importieren", systemImage: "folder") { showFileImporter = true }
            Button("Aus Fotos importieren", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
        } label: {
            Label("Hinzufügen", systemImage: "plus")
        } primaryAction: {
            #if os(iOS)
            if DocumentScannerView.isSupported { showScanner = true } else { showFileImporter = true }
            #else
            showFileImporter = true
            #endif
        }
    }

    private func importFiles(_ urls: [URL]) {
        let result = DocumentImporter.importFiles(urls, into: context)
        var lines: [String] = []
        if !result.duplicates.isEmpty {
            lines.append(result.duplicates.count == 1 ? "Diese Datei ist bereits vorhanden und wurde übersprungen:"
                                                      : "\(result.duplicates.count) Dateien sind bereits vorhanden und wurden übersprungen:")
            lines += result.duplicates.map { "• \($0.fileName) → „\($0.existing.title)“" }
        }
        lines += result.errors.map(\.localizedDescription)
        if !lines.isEmpty {
            let title = result.errors.isEmpty
                ? (result.imported.isEmpty ? "Bereits vorhanden" : "\(result.imported.count) importiert, Duplikate übersprungen")
                : "Import teilweise fehlgeschlagen"
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
                importNotice = ImportNotice(title: "Bereits vorhanden",
                                            message: "Diese Fotos wurden schon als „\(document.title)“ importiert.")
                showExisting(document)
            } else {
                select(document)
            }
        } else {
            importNotice = ImportNotice(title: "Import fehlgeschlagen", message: "Die ausgewählten Fotos konnten nicht geladen werden.")
        }
    }

    private func select(_ document: Document) {
        // Neue Dokumente liegen im Posteingang; ggf. dorthin wechseln, damit sie sichtbar sind.
        if let filter = sidebarSelection, filter != .inbox, filter != .all, filter != .recent {
            sidebarSelection = .inbox
            // Erst nach dem Zurücksetzen durch `onChange(of: sidebarSelection)` auswählen
            Task { @MainActor in selectedDocument = document }
        } else {
            selectedDocument = document
        }
    }
}
