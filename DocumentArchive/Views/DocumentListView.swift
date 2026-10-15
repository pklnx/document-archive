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

struct DocumentListView<ImportMenu: View>: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Document.createdAt, order: .reverse) private var allDocuments: [Document]

    let filter: SidebarItem
    let searchText: String
    @Binding var selection: Document?
    @ViewBuilder var importMenu: () -> ImportMenu
    var onDropFiles: ([URL]) -> Void

    @AppStorage("documentSort") private var sort: DocumentSort = .added
    @State private var isDropTargeted = false
    @State private var documentToDelete: Document?
    @State private var confirmRemoveDuplicates = false

    private var documents: [Document] {
        let allDocuments = allDocuments.filter(\.isAlive)
        if filter == .duplicates {
            // Show duplicates grouped, each with the original (oldest) first
            return MetadataMaintenance.duplicateDocumentGroups(allDocuments)
                .flatMap { $0 }
                .filter { $0.matches(searchText) }
        }
        let filtered = allDocuments.filter { filter.includes($0) && $0.matches(searchText) }
        switch sort {
        case .added:
            return filtered
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

    var body: some View {
        let documents = documents
        List(selection: $selection) {
            ForEach(documents) { document in
                NavigationLink(value: document) {
                    DocumentRow(document: document)
                }
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
                    Button {
                        document.isFavorite.toggle()
                        document.touch()
                    } label: {
                        Label("Favorite", systemImage: document.isFavorite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
                .contextMenu { contextMenu(for: document) }
                .draggable(document.transfer ?? PDFTransfer(data: Data(), fileName: String(localized: "Document") + ".pdf"))
            }
        }
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
        .dropDestination(for: URL.self) { urls, _ in
            onDropFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle(filter.title)
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        .navigationSubtitle("\(documents.count) documents")
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                importMenu()
            }
            if filter == .duplicates, !documents.isEmpty {
                ToolbarItem {
                    Button("Remove Duplicates", systemImage: "trash.slash") { confirmRemoveDuplicates = true }
                }
            }
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
        .confirmationDialog("Remove duplicates?", isPresented: $confirmRemoveDuplicates, titleVisibility: .visible) {
            Button("Delete Duplicates", role: .destructive) {
                selection = nil
                MetadataMaintenance.removeDuplicateDocuments(in: context)
            }
        } message: {
            Text("For every identical file, the document imported first is kept. Missing details such as tags or notes are taken over from the duplicates.")
        }
        .confirmationDialog("Delete document?", isPresented: .constant(documentToDelete != nil),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let documentToDelete { delete(documentToDelete) }
                documentToDelete = nil
            }
            Button("Cancel", role: .cancel) { documentToDelete = nil }
        } message: {
            Text("“\(documentToDelete?.title ?? "")” will be deleted on all devices.")
        }
    }

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
        Button("Delete", systemImage: "trash", role: .destructive) { documentToDelete = document }
    }

    private func delete(_ document: Document) {
        if selection?.id == document.id { selection = nil }
        context.delete(document)
        try? context.save()
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
                    .accessibilityLabel("In inbox")
            }
        }
        .padding(.vertical, 4)
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
    }
}

struct TagChip: View {
    let tag: Tag
    var compact = false

    var body: some View {
        Text(tag.name)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 4)
            .background(tag.color.opacity(0.18), in: Capsule())
            .foregroundStyle(tag.color)
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
