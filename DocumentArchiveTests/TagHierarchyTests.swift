import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Nested tags (#13): traversal, moving, deleting, cycle repair, filter, counts and search.
@Suite @MainActor struct TagHierarchyTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try TestSupport.makeContainer()
    }

    @discardableResult
    private func tag(_ name: String, under parent: ArchiveTag? = nil, createdAt: Date? = nil) -> ArchiveTag {
        let tag = ArchiveTag(name: name)
        if let createdAt { tag.createdAt = createdAt }
        context.insert(tag)
        tag.parent = parent
        return tag
    }

    private func document(_ title: String, tags: [ArchiveTag] = []) -> Document {
        let document = Document(title: title, pdfData: Data(title.utf8), source: .file)
        context.insert(document)
        document.tags = tags
        return document
    }

    /// Auto › Golf › Werkstatt, plus Auto › Polo.
    private func autoTree() -> (auto: ArchiveTag, golf: ArchiveTag, werkstatt: ArchiveTag, polo: ArchiveTag) {
        let auto = tag("Auto")
        let golf = tag("Golf", under: auto)
        let werkstatt = tag("Werkstatt", under: golf)
        let polo = tag("Polo", under: auto)
        return (auto, golf, werkstatt, polo)
    }

    // MARK: Traversal

    @Test func descendantsAndPath() throws {
        let (auto, golf, werkstatt, polo) = autoTree()
        try context.save()

        #expect(Set(TagHierarchy.descendants(of: auto).map(\.id)) == [golf.id, werkstatt.id, polo.id])
        #expect(TagHierarchy.subtreeIDs(of: golf) == [golf.id, werkstatt.id])
        #expect(TagHierarchy.ancestors(of: werkstatt).map(\.id) == [golf.id, auto.id])
        #expect(TagHierarchy.path(of: werkstatt).map(\.name) == ["Auto", "Golf", "Werkstatt"])
        #expect(TagHierarchy.displayPath(of: werkstatt) == "Auto › Golf › Werkstatt")
        #expect(TagHierarchy.depth(of: auto) == 0)
        #expect(TagHierarchy.depth(of: werkstatt) == 2)
        #expect(TagHierarchy.isRooted(werkstatt))
        #expect(auto.children?.count == 2, "children is the inverse of parent")
    }

    @Test func deepChainTerminates() throws {
        var tags = [tag("Level 0")]
        for level in 1..<200 {
            tags.append(tag("Level \(level)", under: tags[level - 1]))
        }
        try context.save()

        let deepest = try #require(tags.last)
        #expect(TagHierarchy.depth(of: deepest) == 199)
        #expect(TagHierarchy.ancestors(of: deepest).count == 199)
        #expect(TagHierarchy.isRooted(deepest))
        #expect(TagHierarchy.descendants(of: tags[0]).count == 199)
        #expect(TagHierarchy.flattened(tags).map(\.depth) == Array(0..<200))
        // A cycle through the whole chain still terminates.
        tags[0].parent = deepest
        #expect(!TagHierarchy.isRooted(deepest))
        #expect(TagHierarchy.ancestors(of: deepest).count == 199)
    }

    // MARK: Moving

    @Test func cannotMoveUnderItselfOrDescendant() throws {
        let (auto, golf, werkstatt, polo) = autoTree()
        #expect(!TagHierarchy.canMove(auto, under: auto))
        #expect(!TagHierarchy.canMove(auto, under: golf))
        #expect(!TagHierarchy.canMove(auto, under: werkstatt))
        #expect(TagHierarchy.canMove(werkstatt, under: polo))
        #expect(!TagHierarchy.move(golf, under: werkstatt))
        #expect(golf.parent?.id == auto.id, "a refused move changes nothing")
        #expect(TagHierarchy.move(werkstatt, under: polo))
        #expect(werkstatt.parent?.id == polo.id)
    }

    @Test func canMoveToRoot() {
        let (auto, golf, _, _) = autoTree()
        #expect(TagHierarchy.canMove(auto, under: nil))
        #expect(TagHierarchy.canMove(golf, under: nil))
    }

    @Test func unnestMovesToRoot() throws {
        let (auto, golf, werkstatt, _) = autoTree()
        #expect(TagHierarchy.move(golf, under: nil))
        try context.save()
        #expect(golf.parent == nil)
        #expect(TagHierarchy.displayPath(of: werkstatt) == "Golf › Werkstatt")
        #expect(auto.children?.map(\.name) == ["Polo"])
    }

    // MARK: Deleting

    @Test func deletingParentMovesChildrenUp() throws {
        let (auto, golf, werkstatt, _) = autoTree()
        let golfDocument = document("Service", tags: [golf])
        let werkstattDocument = document("Repair", tags: [werkstatt])
        try context.save()

        TagHierarchy.delete(golf, in: context, recorder: nil)
        try context.save()

        #expect(werkstatt.parent?.id == auto.id, "moved up one level")
        #expect(TagHierarchy.displayPath(of: werkstatt) == "Auto › Werkstatt")
        #expect(golfDocument.tags?.isEmpty == true, "documents only lose the deleted tag")
        #expect(werkstattDocument.tags?.map(\.id) == [werkstatt.id])
        #expect(try context.fetchCount(FetchDescriptor<Document>()) == 2)
    }

    @Test func deletingARootMakesItsChildrenRoots() throws {
        let (auto, golf, _, polo) = autoTree()
        try context.save()
        TagHierarchy.delete(auto, in: context, recorder: nil)
        try context.save()
        #expect(golf.parent == nil)
        #expect(polo.parent == nil)
    }

    /// An older app version deletes with a plain `context.delete`: `nullify` makes the children
    /// roots, and their documents keep the child tags.
    @Test func olderVersionDeleteMakesChildrenRoots() throws {
        let (auto, golf, werkstatt, polo) = autoTree()
        let document = document("Repair", tags: [werkstatt, polo])
        try context.save()

        context.delete(auto)
        try context.save()

        #expect(golf.parent == nil)
        #expect(polo.parent == nil)
        #expect(werkstatt.parent?.id == golf.id)
        #expect(Set(document.tags?.map(\.id) ?? []) == [werkstatt.id, polo.id])
    }

    // MARK: Cycles

    @Test func repairsCycleDeterministically() throws {
        let older = tag("A", createdAt: Date(timeIntervalSince1970: 1000))
        let newer = tag("B", under: older, createdAt: Date(timeIntervalSince1970: 2000))
        older.parent = newer
        try context.save()

        #expect(TagHierarchy.repairCycles(in: context) == 1)
        #expect(older.parent == nil, "the older tag becomes the root")
        #expect(newer.parent?.id == older.id)
        #expect(!context.hasChanges, "saved")
    }

    @Test(arguments: [false, true])
    func repairWithEqualDatesPicksTheLowerID(insertLowerFirst: Bool) throws {
        let date = Date(timeIntervalSince1970: 1000)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let order = insertLowerFirst ? ids : ids.reversed()
        let first = tag("X", createdAt: date)
        first.id = order[0]
        let second = tag("Y", under: first, createdAt: date)
        second.id = order[1]
        first.parent = second
        try context.save()

        #expect(TagHierarchy.repairCycles(in: context) == 1)
        let lower = [first, second].first { $0.id == ids[0] }!
        let higher = [first, second].first { $0.id == ids[1] }!
        #expect(lower.parent == nil, "same result whatever the insert and fetch order")
        #expect(higher.parent?.id == lower.id)
    }

    /// Runs after every store change: without a cycle it must not change or save anything, or
    /// its own save would trigger it again.
    @Test func repairWithoutCycleChangesNothing() throws {
        _ = autoTree()
        try context.save()
        #expect(TagHierarchy.repairCycles(in: context) == 0)
        #expect(!context.hasChanges)
    }

    @Test func unrootedTagsShowAsRoots() throws {
        let a = tag("A")
        let b = tag("B", under: a)
        let c = tag("C", under: b)
        a.parent = b // A ↔ B, C below the cycle
        let (auto, golf, werkstatt, polo) = autoTree()
        try context.save()

        let tree = TagHierarchy.tree(of: [a, b, c, auto, golf, werkstatt, polo])
        #expect(tree.map(\.tag.name) == ["A", "Auto", "B", "C"])
        let cycleNodes = tree.filter { ["A", "B", "C"].contains($0.tag.name) }
        #expect(cycleNodes.allSatisfy { $0.children.isEmpty })
        let autoNode = try #require(tree.first { $0.tag.id == auto.id })
        #expect(autoNode.children.map(\.tag.name) == ["Golf", "Polo"], "siblings alphabetical")
        #expect(autoNode.children.first?.children.map(\.tag.name) == ["Werkstatt"])
        #expect(TagHierarchy.flattened([a, b, c, auto, golf, werkstatt, polo]).count == 7, "no tag is lost")
    }

    // MARK: Filter, counts, search

    @Test func parentFilterIncludesChildDocuments() throws {
        let (auto, golf, werkstatt, polo) = autoTree()
        let repair = document("Repair", tags: [werkstatt])
        let poloDocument = document("Polo", tags: [polo])
        let other = document("Other", tags: [tag("Bank")])
        try context.save()

        #expect(SidebarItem.tag(auto).includes(repair))
        #expect(SidebarItem.tag(golf).includes(repair))
        #expect(SidebarItem.tag(auto).includes(poloDocument))
        #expect(!SidebarItem.tag(golf).includes(poloDocument))
        #expect(!SidebarItem.tag(auto).includes(other))
        #expect(!SidebarItem.tag(werkstatt).includes(document("Untagged")))

        let visible = SidebarItem.tag(golf).visibleDocuments(in: [repair, poloDocument, other], searchText: "", sort: .title)
        #expect(visible.map(\.id) == [repair.id])
    }

    @Test func documentWithParentAndChildCountsOnce() throws {
        let (auto, golf, werkstatt, _) = autoTree()
        let both = document("Both", tags: [auto, werkstatt])
        try context.save()

        let counts = TagHierarchy.subtreeCounts(documents: [both])
        #expect(counts[auto.id] == 1)
        #expect(counts[golf.id] == 1)
        #expect(counts[werkstatt.id] == 1)
    }

    @Test func subtreeCountsInOnePass() throws {
        let (auto, golf, werkstatt, polo) = autoTree()
        let bank = tag("Bank")
        let documents = [
            document("1", tags: [werkstatt]), document("2", tags: [golf, polo]), document("3", tags: [auto]),
            document("4", tags: [bank, werkstatt]), document("5"),
        ]
        try context.save()

        let counts = TagHierarchy.subtreeCounts(documents: documents)
        for tag in [auto, golf, werkstatt, polo, bank] {
            let scan = documents.filter { SidebarItem.tag(tag).includes($0) }.count
            #expect(counts[tag.id, default: 0] == scan, "\(tag.name)")
        }
        #expect(counts[auto.id] == 4)
    }

    @Test func searchFindsAncestorNames() throws {
        let (_, _, werkstatt, _) = autoTree()
        let repair = document("Rechnung", tags: [werkstatt])
        try context.save()

        #expect(repair.matches("Auto"))
        #expect(repair.matches("golf rechnung"))
        #expect(!repair.matches("Polo"))
    }

    @Test func sortedTagsFollowTheDisplayPath() throws {
        let (auto, golf, werkstatt, polo) = autoTree()
        let bank = tag("Bank")
        let doc = document("All", tags: [polo, bank, werkstatt, auto, golf])
        try context.save()
        #expect(doc.sortedTags.map(TagHierarchy.displayPath(of:))
                == ["Auto", "Auto › Golf", "Auto › Golf › Werkstatt", "Auto › Polo", "Bank"])
    }
}
