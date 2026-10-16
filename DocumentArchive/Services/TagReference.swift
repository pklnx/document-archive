import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// A tag dragged inside the app (#13). Declared in `Config/Info-*.plist`; its own type, so text
    /// dragged in from another app never reaches a tag's drop handler.
    static let tagReference = UTType(exportedAs: "de.patrickklein.documentarchive.tag-ref")
}

/// What a dragged tag carries: only its id. The drop handler looks the tag up again
/// (`TagHierarchy.moveDropped`), so a stale or foreign id is refused.
struct TagReference: Codable, Hashable, Transferable {
    let id: UUID

    init(_ tag: Tag) {
        id = tag.id
    }

    init(id: UUID) {
        self.id = id
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tagReference)
    }
}

extension TagHierarchy {
    /// Drag and drop in the sidebar: nests the dropped tags in `parent` (`nil`: the "Tags"
    /// header, which makes them roots) and saves. Ids that are no existing tag, and moves that
    /// would create a cycle, are refused.
    /// - Returns: `true` when at least one tag was moved (the drop is accepted).
    @MainActor @discardableResult
    static func moveDropped(_ references: [TagReference], under parent: Tag?, in context: ModelContext) -> Bool {
        if let parent, !isAlive(parent) { return false }
        let tags = ((try? context.fetch(FetchDescriptor<Tag>())) ?? []).filter(isAlive)
        let byID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved = false
        for reference in references {
            guard let tag = byID[reference.id], canMove(tag, under: parent) else { continue }
            if tag.parent?.id != parent?.id {
                move(tag, under: parent)
                moved = true
            }
        }
        if moved { try? context.save() }
        return moved
    }
}
