import SwiftData
import SwiftUI

/// One tag of the sidebar's tag tree (#13).
///
/// The tree is a flat list of rows (`TagTreeRow.visibleRows`), indented by depth, with a
/// chevron button that expands or collapses the nested tags. A `DisclosureGroup` was tried
/// first: on iOS its label toggles the group instead of selecting the tag, so a tag with nested
/// tags could not be opened. Rows can be dragged onto other tags (nest) or onto the "Tags"
/// header (top level); the context menu offers the same as "Move To…" and "Move to Top Level",
/// so nothing needs the gesture.
struct TagTreeRow: View {
    /// What the rows ask the sidebar to do.
    struct Actions {
        var edit: (Tag) -> Void
        var newSubtag: (Tag) -> Void
        var move: (Tag) -> Void
        var moveToTopLevel: (Tag) -> Void
        var delete: (Tag) -> Void
        /// Tags dropped on a tag; returns whether the drop was accepted.
        var drop: ([TagReference], Tag) -> Bool
    }

    /// A row of the tree as shown: the node and its depth.
    struct Entry: Identifiable {
        let node: TagHierarchy.Node
        let depth: Int
        var id: UUID { node.id }
    }

    /// The rows to show, depth-first: the nested tags of expanded tags only.
    static func visibleRows(_ nodes: [TagHierarchy.Node], expanded: Set<UUID>) -> [Entry] {
        var result: [Entry] = []
        var stack = nodes.reversed().map { Entry(node: $0, depth: 0) }
        while let entry = stack.popLast() {
            result.append(entry)
            if expanded.contains(entry.id) {
                stack.append(contentsOf: entry.node.children.reversed().map { Entry(node: $0, depth: entry.depth + 1) })
            }
        }
        return result
    }

    let entry: Entry
    let count: Int
    @Binding var expanded: Set<UUID>
    /// `false` on iPhone: no chevrons; the nested tags are reached through the tag's list.
    var showsTree = true
    var allowsDragAndDrop = true
    let actions: Actions

    private var tag: Tag { entry.node.tag }
    private var hasChildren: Bool { !entry.node.children.isEmpty }
    private var isExpanded: Bool { expanded.contains(tag.id) }

    var body: some View {
        if allowsDragAndDrop {
            link
                .draggable(TagReference(tag))
                .dropDestination(for: TagReference.self) { references, _ in
                    actions.drop(references, tag)
                }
        } else {
            link
        }
    }

    private var link: some View {
        NavigationLink(value: SidebarItem.tag(tag)) {
            HStack(spacing: 4) {
                if showsTree {
                    disclosureButton
                }
                content
            }
            .padding(.leading, CGFloat(entry.depth) * 16)
        }
        .accessibilityIdentifier(AccessibilityID.sidebarRow(.tag(tag)))
        .contextMenu { contextMenu }
    }

    /// Expands or collapses the nested tags; an empty space of the same width for tags without
    /// nested tags, so names line up.
    @ViewBuilder
    private var disclosureButton: some View {
        if hasChildren {
            Button {
                withAnimation { toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            // Plain, not borderless: a borderless button takes the accent tint and disappears
            // on the selected (accent-colored) row.
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? Text("Collapse \(tag.name)") : Text("Expand \(tag.name)"))
            .accessibilityIdentifier(AccessibilityID.tagDisclosure(tag.name))
        } else {
            Color.clear.frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private func toggle() {
        if isExpanded { expanded.remove(tag.id) } else { expanded.insert(tag.id) }
    }

    private var content: some View {
        HStack {
            Label {
                Text(tag.name)
            } icon: {
                Image(systemName: tag.symbol).foregroundStyle(tag.color)
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // VoiceOver reads the whole path, "Auto › Golf, 3 documents", plus expanded/collapsed.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TagHierarchy.displayPath(of: tag))
        .accessibilityValue(accessibilityValue)
        .accessibilityActions {
            if showsTree, hasChildren {
                Button(isExpanded ? "Collapse" : "Expand") { toggle() }
            }
        }
    }

    private var accessibilityValue: String {
        let documents = DocumentAccessibility.documentCount(count)
        guard showsTree, hasChildren else { return documents }
        return documents + ", " + (isExpanded ? String(localized: "expanded") : String(localized: "collapsed"))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Edit…", systemImage: "pencil") { actions.edit(tag) }
        Button("New Subtag…", systemImage: "plus") { actions.newSubtag(tag) }
        Button("Move To…", systemImage: "folder") { actions.move(tag) }
            .accessibilityIdentifier(AccessibilityID.tagMove)
        if tag.parent != nil {
            Button("Move to Top Level", systemImage: "arrow.up.to.line") { actions.moveToTopLevel(tag) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(tag) }
    }
}

/// "Move To…": chooses the tag a tag is nested in, or the top level. The menu alternative to
/// drag and drop, on every platform. Only targets that create no cycle are offered.
struct TagParentPicker: View {
    let tag: Tag

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var tags: [Tag]

    var body: some View {
        NavigationStack {
            List {
                choice(nil, title: Text("Top Level"), depth: 0)
                    .accessibilityIdentifier(AccessibilityID.tagParentTopLevel)
                ForEach(TagHierarchy.flattened(tags).filter { TagHierarchy.canMove(tag, under: $0.tag) },
                        id: \.tag.id) { entry in
                    choice(entry.tag, title: Text(verbatim: entry.tag.name), depth: entry.depth)
                        .accessibilityLabel(Text(verbatim: TagHierarchy.displayPath(of: entry.tag)))
                        .accessibilityIdentifier(AccessibilityID.tagParentChoice(entry.tag.name))
                }
            }
            .accessibilityIdentifier(AccessibilityID.tagParentPicker)
            .navigationTitle(Text("Move “\(tag.name)” To"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: TagHierarchy.isAlive(tag)) { _, isAlive in
                // Deleted on another device while the sheet is open.
                if !isAlive { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }

    private func choice(_ parent: Tag?, title: Text, depth: Int) -> some View {
        let isCurrent = tag.parent?.id == parent?.id
        return Button {
            if TagHierarchy.isAlive(tag), TagHierarchy.move(tag, under: parent) {
                try? context.save()
            }
            dismiss()
        } label: {
            HStack {
                if let parent {
                    Image(systemName: parent.symbol)
                        .foregroundStyle(parent.color)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                title
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
