import Foundation
import SwiftData

/// Nested tags (#13): "Auto › Golf › Werkstatt". Pure functions over `Tag.parent` and
/// `Tag.children`.
///
/// Every traversal is iterative and keeps a visited set, so it finishes on deep chains and on
/// cycles. Cycles cannot be created through `move(_:under:)`, but concurrent moves on two devices
/// or a merge can produce one; `repairCycles(in:)` breaks them, and until then a tag whose
/// ancestor chain never reaches a root is shown as a root (`tree(of:)`).
///
/// A document keeps only the tags the user chose; parents are not added (maintainer decision).
/// Filters and counts include the subtree when reading.
enum TagHierarchy {
    /// Between the names of a display path (maintainer decision).
    static let separator = " › "

    // MARK: Traversal

    /// The parent, its parent and so on, nearest first. Stops before a tag that was already seen,
    /// so a cycle gives each member once and never the tag itself.
    static func ancestors(of tag: Tag) -> [Tag] {
        var result: [Tag] = []
        var seen: Set<UUID> = [tag.id]
        var current = tag.parent
        while let next = current, seen.insert(next.id).inserted {
            result.append(next)
            current = next.parent
        }
        return result
    }

    /// Whether the ancestor chain ends at a root (`parent == nil`). `false` for members of a cycle
    /// and for tags below one.
    static func isRooted(_ tag: Tag) -> Bool {
        var seen: Set<UUID> = [tag.id]
        var current = tag
        while let next = current.parent {
            guard seen.insert(next.id).inserted else { return false }
            current = next
        }
        return true
    }

    /// From the root down to the tag itself.
    static func path(of tag: Tag) -> [Tag] {
        ancestors(of: tag).reversed() + [tag]
    }

    /// "Auto › Golf › Werkstatt"
    static func displayPath(of tag: Tag) -> String {
        path(of: tag).map(\.name).joined(separator: separator)
    }

    /// 0 for a root.
    static func depth(of tag: Tag) -> Int {
        ancestors(of: tag).count
    }

    /// All tags below the tag (children, their children, …), without the tag itself.
    static func descendants(of tag: Tag) -> [Tag] {
        var result: [Tag] = []
        var seen: Set<UUID> = [tag.id]
        var queue = tag.children ?? []
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            guard !next.isDeleted, seen.insert(next.id).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: next.children ?? [])
        }
        return result
    }

    /// The tag and all tags below it: what the tag's filter and count include.
    static func subtreeIDs(of tag: Tag) -> Set<UUID> {
        Set(descendants(of: tag).map(\.id)).union([tag.id])
    }

    // MARK: Moving and deleting

    /// `false` for the tag itself and for any tag below it; a root (`nil`) is always allowed.
    static func canMove(_ tag: Tag, under parent: Tag?) -> Bool {
        guard let parent else { return true }
        return parent.id != tag.id && !ancestors(of: parent).contains { $0.id == tag.id }
    }

    /// Nests the tag under `parent` (`nil`: makes it a root). Does not save.
    /// - Returns: `false` (and changes nothing) when the move would create a cycle.
    @MainActor @discardableResult
    static func move(_ tag: Tag, under parent: Tag?) -> Bool {
        guard canMove(tag, under: parent) else { return false }
        if tag.parent?.id != parent?.id { tag.parent = parent }
        return true
    }

    /// **The only way to delete a tag.** Its children move up to the deleted tag's parent, and
    /// documents lose only this tag. Records the deletion for the folder copy. Does not save.
    @MainActor
    static func delete(_ tag: Tag, in context: ModelContext, recorder: DeletionRecording?) {
        let newParent = tag.parent
        for child in Array(tag.children ?? []) where child.id != tag.id {
            child.parent = newParent.flatMap { canMove(child, under: $0) && $0.id != tag.id ? $0 : nil }
        }
        MetadataDeletion.delete(tag, in: context, recorder: recorder)
    }

    // MARK: Cycle repair

    /// Breaks every cycle by making its oldest member a root (`createdAt`, then `id.uuidString`),
    /// so every device makes the same choice whatever the fetch order. Saves only when something
    /// changed: the repair runs after every store change, and a save without changes would trigger
    /// it again.
    /// - Returns: The number of tags that became roots.
    @MainActor @discardableResult
    static func repairCycles(in context: ModelContext) -> Int {
        let repaired = breakCycles(in: context)
        if repaired > 0 { try? context.save() }
        return repaired
    }

    /// `repairCycles` without saving, for callers that save themselves (`mergeDuplicates`).
    @MainActor
    static func breakCycles(in context: ModelContext) -> Int {
        let tags = ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter { !$0.isDeleted }
        var repaired = 0
        for tag in tags where !isRooted(tag) {
            // Walk up until a tag repeats; the cycle is the part from its first visit on.
            var chain: [Tag] = []
            var position: [UUID: Int] = [:]
            var current: Tag? = tag
            while let next = current, position[next.id] == nil {
                position[next.id] = chain.count
                chain.append(next)
                current = next.parent
            }
            guard let repeated = current, let start = position[repeated.id] else { continue }
            let cycle = chain[start...]
            if let oldest = MetadataMaintenance.keeperOrder(Array(cycle), createdAt: \.createdAt, id: \.id).first {
                oldest.parent = nil
                repaired += 1
            }
        }
        return repaired
    }

    // MARK: Tree

    /// One row of the tag tree.
    struct Node: Identifiable {
        let tag: Tag
        let children: [Node]
        var id: UUID { tag.id }
    }

    /// The tags as a forest, siblings sorted by name. Tags whose ancestor chain never reaches a
    /// root (a cycle not repaired yet) are shown as roots without children, so the tree is safe
    /// to render at any time and no tag disappears.
    static func tree(of tags: [Tag]) -> [Node] {
        let alive = tags.filter { !$0.isDeleted }
        let rooted = Set(alive.filter(isRooted).map(\.id))
        var childrenByParent: [UUID: [Tag]] = [:]
        var roots: [Tag] = []
        for tag in alive {
            if let parent = tag.parent, rooted.contains(tag.id) {
                childrenByParent[parent.id, default: []].append(tag)
            } else {
                roots.append(tag)
            }
        }
        // Rooted tags form a forest, so this terminates; depth is bounded by the number of tags.
        func build(_ tag: Tag) -> Node {
            Node(tag: tag, children: sortedByName(childrenByParent[tag.id] ?? []).map(build))
        }
        return sortedByName(roots).map(build)
    }

    /// The tree flattened depth-first, with each tag's depth in the tree: the order of pickers
    /// and menus.
    static func flattened(_ tags: [Tag]) -> [(tag: Tag, depth: Int)] {
        var result: [(tag: Tag, depth: Int)] = []
        var stack = tree(of: tags).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            result.append((node.tag, depth))
            stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
        }
        return result
    }

    /// Alphabetical (maintainer decision); equal names by `id`, so the order is stable.
    static func sortedByName(_ tags: [Tag]) -> [Tag] {
        tags.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    /// By display path, so a parent comes right before its children.
    static func sortedByPath(_ tags: [Tag]) -> [Tag] {
        tags.map { (tag: $0, path: path(of: $0).map(\.name)) }
            .sorted { lhs, rhs in
                for (a, b) in zip(lhs.path, rhs.path) {
                    let order = a.localizedStandardCompare(b)
                    if order != .orderedSame { return order == .orderedAscending }
                }
                if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
                return lhs.tag.id.uuidString < rhs.tag.id.uuidString
            }
            .map(\.tag)
    }

    // MARK: Counts

    /// Documents per tag including its subtree, in one pass over the documents: each document
    /// adds itself once to every tag it has and to their ancestors, so a document tagged with both
    /// a parent and its child counts once for the parent. `documents` is the list the sidebar
    /// shows (after any central exclusion); this function fetches nothing.
    static func subtreeCounts(documents: [Document]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for document in documents {
            var ids = Set<UUID>()
            for tag in document.tags ?? [] where !tag.isDeleted {
                ids.insert(tag.id)
                for ancestor in ancestors(of: tag) { ids.insert(ancestor.id) }
            }
            for id in ids { counts[id, default: 0] += 1 }
        }
        return counts
    }
}
