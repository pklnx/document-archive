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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tag.name)
                        .accessibilityValue(DocumentAccessibility.documentCount(tag.documentCount))
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarRow(.tag(tag)))
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { editorTarget = .tag(tag) }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = .tag(tag) }
                    }
                }
            } header: {
                sectionHeader(String(localized: "Tags"), id: "tag") { editorTarget = .newTag }
            }
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
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(presenting: $pendingDeletion),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) { delete(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The documents themselves are kept.")
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

    private enum PendingDeletion {
        case tag(Tag), correspondent(Correspondent), documentType(DocumentType)

        var title: String {
            switch self {
            case .tag(let t): String(localized: "Delete tag “\(t.name)”?")
            case .correspondent(let c): String(localized: "Delete correspondent “\(c.name)”?")
            case .documentType(let d): String(localized: "Delete document type “\(d.name)”?")
            }
        }
    }

    private func delete(_ deletion: PendingDeletion) {
        switch deletion {
        case .tag(let tag):
            if selection == .tag(tag) { selection = .all }
            MetadataDeletion.delete(tag, in: context, recorder: DocumentDeletion.recorder())
        case .correspondent(let correspondent):
            if selection == .correspondent(correspondent) { selection = .all }
            MetadataDeletion.delete(correspondent, in: context, recorder: DocumentDeletion.recorder())
        case .documentType(let type):
            if selection == .documentType(type) { selection = .all }
            MetadataDeletion.delete(type, in: context, recorder: DocumentDeletion.recorder())
        }
        try? context.save()
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
