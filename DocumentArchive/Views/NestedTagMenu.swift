import SwiftUI

/// The tags as nested menus (#13), for the inspector's tag menu and the bulk tag menu: a tag with
/// nested tags is a submenu that starts with the tag itself, followed by the tags inside it.
/// Siblings are alphabetical (`TagHierarchy.tree`).
struct NestedTagMenuItems<Item: View>: View {
    let nodes: [TagHierarchy.Node]
    /// The menu item for one tag (a toggle or a button).
    @ViewBuilder let item: (Tag) -> Item

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                item(node.tag)
            } else {
                Menu {
                    item(node.tag)
                    Divider()
                    NestedTagMenuItems(nodes: node.children, item: item)
                } label: {
                    Text(verbatim: node.tag.name)
                }
                .accessibilityLabel(Text(verbatim: TagHierarchy.displayPath(of: node.tag)))
            }
        }
    }
}
