import SwiftUI

/// The "Notes" section of `DocumentInfoForm` (#19): the note rendered as Markdown with links, and
/// "Edit" to change the source in a multi-line field. Empty notes start in the editor. Search
/// still uses the raw text.
struct NotesView: View {
    @Bindable var document: Document

    @State private var isEditing: Bool
    @FocusState private var editorIsFocused: Bool

    init(document: Document) {
        self.document = document
        _isEditing = State(initialValue: document.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var hasNotes: Bool {
        !document.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section("Notes") {
            if isEditing || !hasNotes {
                editor
            } else {
                MarkdownBlocksView(blocks: MarkdownNotes.blocks(from: document.notes))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityID.notesRendered)
                Button("Edit Notes", systemImage: "pencil") {
                    isEditing = true
                    editorIsFocused = true
                }
                .accessibilityIdentifier(AccessibilityID.notesEdit)
            }
        }
        .onChange(of: document.id) { isEditing = !hasNotes }
        .onChange(of: document.notes) { oldValue, _ in
            // Typing into empty notes keeps the editor open once the first character is there.
            if !isEditing, oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, editorIsFocused {
                isEditing = true
            }
        }
    }

    @ViewBuilder private var editor: some View {
        TextField("Notes", text: $document.notes, axis: .vertical)
            .lineLimit(3...10)
            .focused($editorIsFocused)
            .accessibilityIdentifier(AccessibilityID.notesEditor)
        Text(String(localized: "Markdown: **bold**, *italic*, # Heading, - List, - [ ] Task, [Text](https://…)"))
            .font(.caption)
            .foregroundStyle(.secondary)
        if hasNotes {
            Button("Done") {
                editorIsFocused = false
                isEditing = false
            }
            .accessibilityIdentifier(AccessibilityID.notesDone)
        }
    }
}

/// Rendered Markdown blocks. Links open in the browser, Mail or Phone through the environment's
/// `openURL`; on macOS a block's link addresses are its tooltip, so a link text that looks like a
/// different address is noticed.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownNotes.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
                    .modifier(LinkTooltip(links: MarkdownNotes.links(in: blocks[index].text)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: MarkdownNotes.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .bold()
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            Text(block.text)
        case .bullet(let level):
            ListItemRow(level: level, text: block.text) {
                Text(verbatim: "•").accessibilityHidden(true)
            }
        case .numbered(let marker, let level):
            ListItemRow(level: level, text: block.text) {
                Text(verbatim: marker).monospacedDigit()
            }
        case .task(let isChecked, let level):
            ListItemRow(level: level, text: block.text) {
                Image(systemName: isChecked ? "checkmark.square" : "square")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isChecked ? Text("Task completed") : Text("Task open"))
            }
        case .quote:
            Text(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 3).accessibilityHidden(true)
                }
        case .code:
            Text(block.text)
                .font(.callout.monospaced())
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }
}

/// A list item: its marker (bullet, number, checkbox) and text, indented by its level.
private struct ListItemRow<Marker: View>: View {
    let level: Int
    let text: AttributedString
    @ViewBuilder let marker: Marker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            Text(text)
        }
        .padding(.leading, CGFloat(level) * 16)
    }
}

/// macOS: the block's link addresses as its tooltip (review point 8). No tooltip without links.
private struct LinkTooltip: ViewModifier {
    let links: [URL]

    func body(content: Content) -> some View {
        #if os(macOS)
        if links.isEmpty {
            content
        } else {
            content.help(links.map(\.absoluteString).joined(separator: "\n"))
        }
        #else
        content
        #endif
    }
}
