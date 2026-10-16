import SwiftData
import SwiftUI

/// Documents an action waits to be confirmed for (delete, analyze again).
struct BulkRequest: Identifiable {
    let id = UUID()
    let documents: [Document]
}

/// State of the bulk actions that outlives a menu: confirmations and the progress of
/// "Analyze again". `ContentView` owns it, shows the dialogs and puts it into the environment, so
/// `BulkActionsMenu` works the same in the context menu, `BulkActionsView` and the iPhone toolbar.
@MainActor @Observable
final class BulkActionCoordinator {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    var pendingDelete: BulkRequest?
    var pendingReanalysis: BulkRequest?
    /// Set while "Analyze again" runs.
    private(set) var progress: Progress?
    private var task: Task<Void, Never>?

    func requestDelete(_ documents: [Document]) {
        guard !documents.isEmpty else { return }
        pendingDelete = BulkRequest(documents: documents)
    }

    func requestReanalysis(_ documents: [Document]) {
        guard !documents.isEmpty, progress == nil else { return }
        pendingReanalysis = BulkRequest(documents: documents)
    }

    /// Analyzes the documents one after another (`BulkEditor.reanalyze`).
    func startReanalysis(_ documents: [Document], context: ModelContext) {
        guard progress == nil else { return }
        progress = Progress(done: 0, total: documents.count)
        task = Task { [self] in
            await BulkEditor.reanalyze(documents, context: context) { done, total in
                progress = Progress(done: done, total: total)
            }
            let finished = !Task.isCancelled
            progress = nil
            task = nil
            AccessibilityNotification.Announcement(finished ? String(localized: "Analysis finished")
                                                            : String(localized: "Analysis cancelled")).post()
        }
    }

    /// Finishes the current document and skips the rest.
    func cancelReanalysis() {
        task?.cancel()
    }
}

/// All actions for several selected documents. Used in the list's context menu, in
/// `BulkActionsView` and (split into `primary` and `more`) in the iPhone's bottom toolbar.
/// Later features add their bulk actions here.
struct BulkActionsMenu: View {
    enum Part {
        /// Everything.
        case all
        /// What the iPhone toolbar's "More" menu holds (everything except tags and inbox).
        case more
    }

    let documents: [Document]
    var part: Part = .all
    /// `true` in a `Form` (`BulkActionsView`): groups as sections. Menus use dividers, because
    /// iOS drops the accessibility identifiers of menu items inside a `Section`.
    var inSections = false

    @Environment(BulkActionCoordinator.self) private var coordinator: BulkActionCoordinator?

    var body: some View {
        if inSections {
            Section { assignment }
            Section { state }
            Section { reanalyze }
            Section { delete }
        } else {
            assignment
            Divider()
            state
            Divider()
            reanalyze
            Divider()
            delete
        }
    }

    @ViewBuilder
    private var assignment: some View {
        if part == .all {
            BulkTagsMenu(documents: documents)
        }
        BulkCorrespondentMenu(documents: documents)
        BulkDocumentTypeMenu(documents: documents)
    }

    @ViewBuilder
    private var state: some View {
        if part == .all {
            BulkInboxButton(documents: documents)
        }
        BulkFavoriteButton(documents: documents)
    }

    private var reanalyze: some View {
        Button("Analyze Again…", systemImage: "text.viewfinder") {
            MenuPresentation.afterMenuCloses { coordinator?.requestReanalysis(documents) }
        }
        .disabled(coordinator?.progress != nil)
        .accessibilityIdentifier(AccessibilityID.bulkReanalyze)
    }

    private var delete: some View {
        Button("Delete…", systemImage: "trash", role: .destructive) {
            MenuPresentation.afterMenuCloses { coordinator?.requestDelete(documents) }
        }
        .accessibilityIdentifier(AccessibilityID.bulkDelete)
    }
}

/// Tags with three states: on all documents (checkmark), on some (dash) or on none.
/// Choosing a tag adds it to all; choosing a tag that all have removes it.
struct BulkTagsMenu: View {
    let documents: [Document]

    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var tags: [Tag]

    var body: some View {
        Menu {
            ForEach(tags) { tag in
                let state = BulkEditor.tagState(tag, in: documents)
                Button {
                    if state == .all {
                        BulkEditor.removeTag(tag, from: documents, in: context)
                    } else {
                        BulkEditor.addTag(tag, to: documents, in: context)
                    }
                } label: {
                    switch state {
                    case .all: Label(tag.name, systemImage: "checkmark")
                    case .some: Label(tag.name, systemImage: "minus")
                    case .none: Text(tag.name)
                    }
                }
                .accessibilityValue(Self.stateDescription(state))
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
        .accessibilityIdentifier(AccessibilityID.bulkTags)
        .disabled(documents.isEmpty || tags.isEmpty)
    }

    static func stateDescription(_ state: BulkEditor.TagState) -> String {
        switch state {
        case .all: String(localized: "on all documents")
        case .some: String(localized: "on some documents")
        case .none: String(localized: "on no document")
        }
    }
}

struct BulkCorrespondentMenu: View {
    let documents: [Document]

    @Environment(\.modelContext) private var context
    @Query(sort: \Correspondent.name) private var correspondents: [Correspondent]

    var body: some View {
        // Marked only when all documents have the same one.
        let common = commonValue(documents.map { $0.correspondent?.id })
        Menu {
            choice(Text("None"), isCommon: common == .some(nil)) {
                BulkEditor.setCorrespondent(nil, for: documents, in: context)
            }
            ForEach(correspondents) { correspondent in
                choice(Text(verbatim: correspondent.name), isCommon: common == .some(correspondent.id)) {
                    BulkEditor.setCorrespondent(correspondent, for: documents, in: context)
                }
            }
        } label: {
            Label("Correspondent", systemImage: "person.crop.circle")
        }
        .disabled(documents.isEmpty)
    }
}

struct BulkDocumentTypeMenu: View {
    let documents: [Document]

    @Environment(\.modelContext) private var context
    @Query(sort: \DocumentType.name) private var documentTypes: [DocumentType]

    var body: some View {
        let common = commonValue(documents.map { $0.documentType?.id })
        Menu {
            choice(Text("None"), isCommon: common == .some(nil)) {
                BulkEditor.setDocumentType(nil, for: documents, in: context)
            }
            ForEach(documentTypes) { type in
                choice(Text(verbatim: type.name), isCommon: common == .some(type.id)) {
                    BulkEditor.setDocumentType(type, for: documents, in: context)
                }
            }
        } label: {
            Label("Document type", systemImage: "doc.text")
        }
        .disabled(documents.isEmpty)
    }
}

/// "Mark as Done" while any document is in the inbox, otherwise "Move to Inbox".
struct BulkInboxButton: View {
    let documents: [Document]

    @Environment(\.modelContext) private var context

    var body: some View {
        let anyInInbox = documents.contains(where: \.isInbox)
        Button {
            BulkEditor.setInbox(!anyInInbox, for: documents, in: context)
        } label: {
            Label(anyInInbox ? "Mark as Done" : "Move to Inbox",
                  systemImage: anyInInbox ? "tray.and.arrow.up" : "tray.and.arrow.down")
        }
        .accessibilityIdentifier(AccessibilityID.bulkInbox)
        .disabled(documents.isEmpty)
    }
}

/// "Add to Favorites" unless all documents are favorites already.
struct BulkFavoriteButton: View {
    let documents: [Document]

    @Environment(\.modelContext) private var context

    var body: some View {
        let allFavorites = !documents.isEmpty && documents.allSatisfy(\.isFavorite)
        Button {
            BulkEditor.setFavorite(!allFavorites, for: documents, in: context)
        } label: {
            Label(allFavorites ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: allFavorites ? "star.slash" : "star")
        }
        .disabled(documents.isEmpty)
    }
}

/// "Analyzing 3 of 12…" with Cancel, below the list while bulk "Analyze again" runs.
struct BulkProgressView: View {
    let progress: BulkActionCoordinator.Progress
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(maxWidth: 120)
                .accessibilityHidden(true)
            Text("Analyzing \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .accessibilityIdentifier(AccessibilityID.bulkCancel)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

/// The value all elements share: `.some(value)` (which may be `nil`), or `nil` when they differ.
private func commonValue<T: Equatable>(_ values: [T?]) -> T?? {
    guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
    return .some(first)
}

/// A menu choice with a checkmark when it is what all documents have.
@ViewBuilder
private func choice(_ title: Text, isCommon: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        if isCommon {
            Label { title } icon: { Image(systemName: "checkmark") }
        } else {
            title
        }
    }
    .accessibilityAddTraits(isCommon ? .isSelected : [])
}
