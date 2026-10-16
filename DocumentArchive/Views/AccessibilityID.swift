/// Accessibility identifiers for the views UI tests touch. UI tests query these, never the
/// (localized) text, so changing a label does not break them.
enum AccessibilityID {
    static let sidebar = "sidebar"
    static let settingsButton = "sidebar.settings"
    static let settings = "settings"
    static let settingsDone = "settings.done"

    static let documentList = "documentList"
    static let importMenu = "documentList.import"
    static let deleteSwipe = "documentList.deleteSwipe"
    static let deleteConfirm = "documentList.deleteConfirm"

    static let documentDetail = "documentDetail"
    /// iPad: back from the document to the list.
    static let showList = "documentDetail.showList"
    static let inspectorToggle = "documentDetail.inspectorToggle"
    static let inspector = "documentDetail.inspector"
    static let documentMore = "documentDetail.more"
    static let documentDelete = "documentDetail.delete"
    static let documentDeleteConfirm = "documentDetail.deleteConfirm"

    static let ruleEditorCancel = "ruleEditor.cancel"

    static func sidebarRow(_ item: SidebarItem) -> String {
        switch item {
        case .inbox: "sidebar.inbox"
        case .all: "sidebar.all"
        case .favorites: "sidebar.favorites"
        case .recent: "sidebar.recent"
        case .duplicates: "sidebar.duplicates"
        case .documentType(let type): "sidebar.documentType.\(type.name)"
        case .correspondent(let correspondent): "sidebar.correspondent.\(correspondent.name)"
        case .tag(let tag): "sidebar.tag.\(tag.name)"
        }
    }

    /// "Add" button in a sidebar section header, e.g. `sidebar.add.tag`.
    static func sidebarAdd(_ section: String) -> String { "sidebar.add.\(section)" }

    static func documentRow(_ title: String) -> String { "documentList.row.\(title)" }
}
