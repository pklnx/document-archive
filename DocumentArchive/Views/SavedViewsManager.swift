import SwiftData
import SwiftUI

/// "Manage Views" (#14): rename, reorder and delete saved views in a list of its own. On iPhone
/// and iPad this is the only place to reorder them (the sidebar list is never put into edit
/// mode); macOS can also drag them in the sidebar.
struct SavedViewsManager: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// The sidebar's selection: a deleted view that is shown is replaced by "All Documents".
    @Binding var selection: SidebarItem?

    @Query private var queriedViews: [SavedView]
    private var views: [SavedView] { SavedViewMaintenance.sorted(queriedViews) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(views) { view in
                    row(view)
                }
                .onMove(perform: move)
                .onDelete { offsets in
                    let views = views
                    delete(offsets.filter { $0 < views.count }.map { views[$0] })
                }
            }
            .overlay {
                if views.isEmpty {
                    ContentUnavailableView("No Views", systemImage: SavedView.defaultSymbol,
                                           description: Text("Save a list with its filters as a view to see it here."))
                }
            }
            .accessibilityIdentifier(AccessibilityID.savedViewsManager)
            .navigationTitle("Manage Views")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // Always editable: drag handles and delete buttons without an Edit button.
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                        .accessibilityIdentifier(AccessibilityID.savedViewsManagerDone)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
        // Also when the sheet is swiped away.
        .onDisappear(perform: nameUntitledViews)
    }

    private func row(_ view: SavedView) -> some View {
        HStack {
            Image(systemName: view.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Name", text: Binding { view.name } set: { view.name = $0 })
                .onSubmit { try? context.save() }
                .accessibilityIdentifier(AccessibilityID.savedViewsManagerName(view.name))
            #if os(macOS)
            // macOS has no swipe or edit-mode delete button.
            Button {
                delete([view])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Delete View"))
            .accessibilityLabel(String(localized: "Delete “\(view.name)”"))
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.savedViewsManagerRow(view.name))
        // Reordering without dragging (VoiceOver, Switch Control).
        .accessibilityAction(named: Text("Move Up")) { moveByOne(view, up: true) }
        .accessibilityAction(named: Text("Move Down")) { moveByOne(view, up: false) }
        .accessibilityAction(named: Text("Delete")) { delete([view]) }
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        SavedViewMaintenance.move(views, fromOffsets: source, toOffset: destination)
        try? context.save()
    }

    private func moveByOne(_ view: SavedView, up: Bool) {
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return }
        if up, index > 0 {
            move([index], index - 1)
        } else if !up, index < views.count - 1 {
            move([index], index + 2)
        }
    }

    private func delete(_ deleted: [SavedView]) {
        for view in deleted where !view.isDeleted && view.modelContext != nil {
            if selection == .savedView(view) { selection = .all }
            MetadataDeletion.delete(view, in: context, recorder: DocumentDeletion.recorder())
        }
        try? context.save()
    }

    private func close() {
        nameUntitledViews()
        dismiss()
    }

    /// Empty names (cleared while renaming) get a name again, so no view is invisible.
    private func nameUntitledViews() {
        for view in views where view.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            view.name = String(localized: "Untitled View")
        }
        try? context.save()
    }
}
