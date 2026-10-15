import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Binding var selection: SidebarItem?
    @Binding var editorTarget: RuleEditorTarget?
    @Binding var showSettings: Bool

    @Query(filter: #Predicate<Document> { _ in true }) private var queriedDocuments: [Document]
    private var documents: [Document] { queriedDocuments.filter(\.isAlive) }
    @Query(sort: \DocumentType.name) private var documentTypes: [DocumentType]
    @Query(sort: \Correspondent.name) private var correspondents: [Correspondent]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var pendingDeletion: PendingDeletion?

    var body: some View {
        List(selection: $selection) {
            Section("Bibliothek") {
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

            Section {
                ForEach(documentTypes) { type in
                    row(.documentType(type), icon: type.symbol, count: type.documentCount)
                        .contextMenu {
                            Button("Bearbeiten …", systemImage: "pencil") { editorTarget = .documentType(type) }
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                pendingDeletion = .documentType(type)
                            }
                        }
                }
            } header: {
                sectionHeader("Dokumenttypen") { editorTarget = .newDocumentType }
            }

            Section {
                ForEach(correspondents) { correspondent in
                    row(.correspondent(correspondent), icon: "person.crop.circle", count: correspondent.documentCount)
                        .contextMenu {
                            Button("Bearbeiten …", systemImage: "pencil") { editorTarget = .correspondent(correspondent) }
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                pendingDeletion = .correspondent(correspondent)
                            }
                        }
                }
            } header: {
                sectionHeader("Korrespondenten") { editorTarget = .newCorrespondent }
            }

            Section {
                ForEach(tags) { tag in
                    NavigationLink(value: SidebarItem.tag(tag)) {
                        HStack {
                            Label {
                                Text(tag.name)
                            } icon: {
                                Image(systemName: "tag.fill").foregroundStyle(tag.color)
                            }
                            Spacer()
                            countBadge(tag.documentCount)
                        }
                    }
                    .contextMenu {
                        Button("Bearbeiten …", systemImage: "pencil") { editorTarget = .tag(tag) }
                        Button("Löschen", systemImage: "trash", role: .destructive) { pendingDeletion = .tag(tag) }
                    }
                }
            } header: {
                sectionHeader("Tags") { editorTarget = .newTag }
            }
        }
        .navigationTitle("Document Archive")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        #else
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
            }
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            SyncStatusView()
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: .constant(pendingDeletion != nil),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) { deletePending() }
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Die Dokumente selbst bleiben erhalten.")
        }
    }

    private func row(_ item: SidebarItem, icon: String, count: Int?) -> some View {
        NavigationLink(value: item) {
            HStack {
                Label(item.title, systemImage: icon)
                Spacer()
                if let count { countBadge(count) }
            }
        }
    }

    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("\(title): neu anlegen")
            .accessibilityLabel("\(title) hinzufügen")
        }
    }

    private enum PendingDeletion {
        case tag(Tag), correspondent(Correspondent), documentType(DocumentType)

        var title: String {
            switch self {
            case .tag(let t): "Tag „\(t.name)“ löschen?"
            case .correspondent(let c): "Korrespondent „\(c.name)“ löschen?"
            case .documentType(let d): "Dokumenttyp „\(d.name)“ löschen?"
            }
        }
    }

    private func deletePending() {
        guard let pendingDeletion else { return }
        switch pendingDeletion {
        case .tag(let tag):
            if selection == .tag(tag) { selection = .all }
            context.delete(tag)
        case .correspondent(let correspondent):
            if selection == .correspondent(correspondent) { selection = .all }
            context.delete(correspondent)
        case .documentType(let type):
            if selection == .documentType(type) { selection = .all }
            context.delete(type)
        }
        try? context.save()
        self.pendingDeletion = nil
    }
}

struct SyncStatusView: View {
    private var monitor = SyncMonitor.shared

    var body: some View {
        HStack(spacing: 6) {
            switch monitor.state {
            case _ where !monitor.isCloudKitEnabled:
                Image(systemName: "externaldrive")
                Text("Nur lokal gespeichert – kein iCloud-Sync")
            case _ where !monitor.isICloudSignedIn:
                Image(systemName: "icloud.slash")
                Text("Nicht bei iCloud angemeldet")
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Synchronisiere …")
            case .failed:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                Text("Sync-Fehler – siehe Einstellungen")
            case .succeeded(let date):
                Image(systemName: "checkmark.icloud")
                Text("Synchronisiert \(date.formatted(.relative(presentation: .named)))")
            case .idle:
                Image(systemName: "icloud")
                Text("iCloud – warte auf ersten Abgleich")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
