import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// "Manage Views" asks before deleting, like the sidebar (follow-up from #41): its delete paths
/// only produce the same confirmation, which deletes once confirmed.
@MainActor @Suite struct SavedViewDeletionTests {
    private func makeViews(_ names: [String], in context: ModelContext) -> [SavedView] {
        names.map { name in
            let view = SavedView(name: name)
            context.insert(view)
            return view
        }
    }

    @Test func requestingADeleteOnlyAsks() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let views = makeViews(["Steuer", "Offen"], in: context)
        try context.save()

        let pending = try #require(SavedViewsManager.pendingDeletion(for: SavedViewsManager.views(at: [1], in: views)))
        guard case .savedView(let view) = pending else { Issue.record("not a saved view"); return }
        #expect(view.id == views[1].id)
        #expect(pending.title.contains("Offen"))
        // Nothing is deleted before the confirmation.
        #expect(try context.fetchCount(FetchDescriptor<SavedView>()) == 2)
    }

    @Test func noConfirmationForMissingOrDeletedViews() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let views = makeViews(["Steuer"], in: context)
        try context.save()

        #expect(SavedViewsManager.views(at: [3], in: views).isEmpty)
        #expect(SavedViewsManager.pendingDeletion(for: []) == nil)
        context.delete(views[0])
        try context.save()
        #expect(SavedViewsManager.pendingDeletion(for: views) == nil)
    }

    @Test func confirmingDeletesTheViewAndLeavesIt() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        let views = makeViews(["Steuer", "Offen"], in: context)
        try context.save()
        var selection: SidebarItem? = .savedView(views[0])

        SidebarView.PendingDeletion.savedView(views[0]).perform(in: context, selection: &selection)

        #expect(selection == .all)
        let remaining = try context.fetch(FetchDescriptor<SavedView>())
        #expect(remaining.map(\.name) == ["Offen"])

        // Confirming again (a second dialog for the same view) changes nothing.
        selection = .savedView(views[1])
        SidebarView.PendingDeletion.savedView(views[0]).perform(in: context, selection: &selection)
        #expect(selection == .savedView(views[1]))
        #expect(try context.fetchCount(FetchDescriptor<SavedView>()) == 1)
    }
}
