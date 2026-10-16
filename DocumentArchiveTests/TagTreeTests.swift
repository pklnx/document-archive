import CoreTransferable
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import DocumentArchive

/// The tag tree's interactions (#13 part 2): drag and drop with `TagReference`, the tag editor's
/// parent check, the iPhone drill-down path, subfolder chips, deleting a tag that is gone, and
/// the cycle repair after a store change.
@Suite @MainActor struct TagTreeTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try TestSupport.makeContainer()
    }

    @discardableResult
    private func tag(_ name: String, under parent: ArchiveTag? = nil) -> ArchiveTag {
        let tag = ArchiveTag(name: name)
        context.insert(tag)
        tag.parent = parent
        return tag
    }

    private func document(_ title: String, tags: [ArchiveTag]) -> Document {
        let document = Document(title: title, pdfData: Data(title.utf8), source: .file)
        context.insert(document)
        document.tags = tags
        return document
    }

    /// Auto › Golf › Werkstatt, plus Auto › Polo and a root "Haus".
    private func tree() throws -> (auto: ArchiveTag, golf: ArchiveTag, werkstatt: ArchiveTag, polo: ArchiveTag, haus: ArchiveTag) {
        let auto = tag("Auto")
        let golf = tag("Golf", under: auto)
        let werkstatt = tag("Werkstatt", under: golf)
        let polo = tag("Polo", under: auto)
        let haus = tag("Haus")
        try context.save()
        return (auto, golf, werkstatt, polo, haus)
    }

    // MARK: TagReference

    @Test func tagReferenceRoundTrip() async throws {
        let (_, golf, _, _, _) = try tree()
        let reference = TagReference(golf)

        // The payload is the Codable representation.
        let decoded = try JSONDecoder().decode(TagReference.self, from: JSONEncoder().encode(reference))
        #expect(decoded == reference)
        if #available(macOS 15.2, iOS 18.2, *) {
            let data = try await reference.exported(as: .tagReference)
            let imported = try await TagReference(importing: data, contentType: .tagReference)
            #expect(imported == reference)
            #expect(imported.id == golf.id)
        }
        #expect(UTType.tagReference.identifier == "de.patrickklein.documentarchive.tag-ref")
        #expect(!UTType.tagReference.conforms(to: .text), "text dragged in from other apps is no tag")
    }

    // MARK: Drop handler

    @Test func droppingNestsTheTag() throws {
        let (auto, _, _, _, haus) = try tree()

        #expect(TagHierarchy.moveDropped([TagReference(haus)], under: auto, in: context))

        #expect(haus.parent?.id == auto.id)
        #expect(!context.hasChanges, "the drop is saved")
    }

    @Test func droppingOnTheHeaderMakesATopLevelTag() throws {
        let (_, golf, werkstatt, _, _) = try tree()

        #expect(TagHierarchy.moveDropped([TagReference(golf)], under: nil, in: context))

        #expect(golf.parent == nil)
        #expect(werkstatt.parent?.id == golf.id, "nested tags move along")
    }

    @Test func dropWithUnknownIDIsRefused() throws {
        let (auto, _, _, _, _) = try tree()
        let deleted = tag("Deleted")
        try context.save()
        let deletedReference = TagReference(deleted)
        TagHierarchy.delete(deleted, in: context, recorder: nil)
        try context.save()

        #expect(!TagHierarchy.moveDropped([TagReference(id: UUID())], under: auto, in: context))
        #expect(!TagHierarchy.moveDropped([deletedReference], under: auto, in: context))
        #expect(auto.children?.count == 2)
    }

    @Test func dropThatWouldCreateACycleIsRefused() throws {
        let (auto, golf, werkstatt, _, _) = try tree()

        #expect(!TagHierarchy.moveDropped([TagReference(auto)], under: werkstatt, in: context))
        #expect(!TagHierarchy.moveDropped([TagReference(golf)], under: golf, in: context))

        #expect(auto.parent == nil)
        #expect(TagHierarchy.isRooted(werkstatt))
    }

    @Test func dropOnADeletedTagIsRefused() throws {
        let (_, _, _, polo, haus) = try tree()
        TagHierarchy.delete(polo, in: context, recorder: nil)

        #expect(!TagHierarchy.moveDropped([TagReference(haus)], under: polo, in: context))
        #expect(haus.parent == nil)
    }

    // MARK: Deleting

    /// Follow-up from the part 1 review: a tag deleted meanwhile (sync, another window) is left
    /// alone, without a second tombstone.
    @Test func deletingATagThatIsGoneDoesNothing() throws {
        let (auto, golf, werkstatt, _, _) = try tree()
        let recorder = RecordedDeletions()

        #expect(TagHierarchy.delete(golf, in: context, recorder: recorder))
        #expect(!TagHierarchy.delete(golf, in: context, recorder: recorder), "deleted, not saved yet")
        try context.save()
        #expect(!TagHierarchy.delete(golf, in: context, recorder: recorder), "deleted and saved")

        #expect(recorder.records.map(\.id) == [golf.id])
        #expect(werkstatt.parent?.id == auto.id)
    }

    // MARK: Editor

    @Test func editorParentChoice() throws {
        let (auto, golf, werkstatt, _, haus) = try tree()
        let tags = try context.fetch(FetchDescriptor<ArchiveTag>())

        #expect(TagHierarchy.parent(withID: nil, for: golf, among: tags) == .success(nil))
        #expect(TagHierarchy.parent(withID: haus.id, for: golf, among: tags) == .success(haus))
        #expect(TagHierarchy.parent(withID: werkstatt.id, for: nil, among: tags) == .success(werkstatt),
                "a new tag can go anywhere")
        // Moved meanwhile (e.g. by sync): the chosen parent is now below the edited tag.
        #expect(TagHierarchy.parent(withID: werkstatt.id, for: auto, among: tags) == .failure(.wouldCreateCycle))
        #expect(TagHierarchy.parent(withID: golf.id, for: golf, among: tags) == .failure(.wouldCreateCycle))
    }

    @Test func editorReportsADeletedParent() throws {
        let (_, golf, _, _, haus) = try tree()
        let tags = try context.fetch(FetchDescriptor<ArchiveTag>())
        let hausID = haus.id
        TagHierarchy.delete(haus, in: context, recorder: nil)
        try context.save()

        #expect(TagHierarchy.parent(withID: hausID, for: golf, among: tags) == .failure(.parentDeleted),
                "the editor's list still holds the deleted tag")
        #expect(TagHierarchy.parent(withID: UUID(), for: nil, among: tags) == .failure(.parentDeleted))
        #expect(!RuleEditorView.message(for: .parentDeleted).isEmpty)
        #expect(RuleEditorView.title(for: .parentDeleted) != RuleEditorView.title(for: .wouldCreateCycle))
    }

    // MARK: iPhone drill-down

    @Test func drillDownPathBelongsToTheSidebarSelection() throws {
        let (auto, golf, werkstatt, polo, haus) = try tree()

        #expect(TagNavigation.path([], continues: SidebarItem.inbox))
        #expect(TagNavigation.path([golf], continues: SidebarItem.tag(auto)))
        #expect(TagNavigation.path([golf, werkstatt], continues: SidebarItem.tag(auto)))
        #expect(!TagNavigation.path([golf], continues: SidebarItem.tag(haus)), "another tag selected")
        #expect(!TagNavigation.path([golf], continues: SidebarItem.all))
        #expect(!TagNavigation.path([golf, polo], continues: SidebarItem.tag(auto)), "Polo is not in Golf")

        TagHierarchy.move(golf, under: haus)
        #expect(!TagNavigation.path([golf, werkstatt], continues: SidebarItem.tag(auto)), "moved elsewhere meanwhile")
    }

    // MARK: Subfolder chips

    @Test func subfolderChipsListDirectChildrenWithSubtreeCounts() throws {
        let (auto, golf, werkstatt, polo, haus) = try tree()
        let documents = [
            document("Service", tags: [golf]),
            document("Repair", tags: [werkstatt]),
            document("Both", tags: [golf, werkstatt]),
            document("Car", tags: [auto]),
        ]
        try context.save()

        let chips = SubfolderChip.chips(of: .tag(auto), in: documents)
        #expect(chips.map(\.tag.name) == ["Golf", "Polo"], "direct children only, alphabetical")
        #expect(chips.map(\.count) == [3, 0], "a document tagged with Golf and Werkstatt counts once")
        #expect(SubfolderChip.chips(of: .tag(golf), in: documents).map(\.tag.id) == [werkstatt.id])
        #expect(SubfolderChip.chips(of: .tag(polo), in: documents).isEmpty)
        #expect(SubfolderChip.chips(of: .tag(haus), in: documents).isEmpty)
        #expect(SubfolderChip.chips(of: .all, in: documents).isEmpty)
    }

    // MARK: Accessibility

    @Test func nestedTagsAreReadWithTheirPath() throws {
        let (_, golf, _, _, _) = try tree()
        let document = document("Service", tags: [golf])
        let label = DocumentAccessibility.label(for: document, locale: Locale(identifier: "en_US"))
        #expect(label.contains("Auto › Golf"))
    }

    @Test func everyTagSymbolHasAName() {
        #expect(Set(ArchiveTag.symbolNames.keys) == Set(ArchiveTag.symbolChoices))
        #expect(Set(ArchiveTag.symbolNames.values).count == ArchiveTag.symbolNames.count)
        #expect(ArchiveTag.symbolChoices.first == ArchiveTag(name: "New").symbol, "the default is offered first")
    }

    // MARK: Cycle repair after store changes

    /// Follow-up from the part 1 review: a change saved to the store (as a CloudKit import or a
    /// folder read does) starts the repair through `StoreChangeObserver`.
    /// On disk: with the suite's in-memory store, the saves of tests running in parallel (#43)
    /// restart the observer's debounce and the repair can start too late.
    @Test func storeChangeTriggersCycleRepair() async throws {
        let container = try TestSupport.makeContainerOnDisk()
        let context = container.mainContext
        let auto = ArchiveTag(name: "Auto")
        let golf = ArchiveTag(name: "Golf")
        context.insert(auto)
        context.insert(golf)
        golf.parent = auto
        try context.save()
        let observer = StoreChangeObserver(container: container, debounce: .milliseconds(50))
        let repair = TagCycleRepair()
        repair.start(container: container, changes: observer)
        defer { repair.stop(); observer.stop() }

        // What two devices' concurrent moves produce once both arrive: Auto → Golf → Auto.
        auto.parent = golf
        try context.save()
        #expect(!TagHierarchy.isRooted(auto))

        let clock = ContinuousClock()
        let deadline = clock.now + TestSupport.scaled(.seconds(30))
        while !TagHierarchy.isRooted(auto), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(TagHierarchy.isRooted(auto))
        #expect(TagHierarchy.isRooted(golf))
        #expect(!context.hasChanges, "the repair saved")
    }
}
