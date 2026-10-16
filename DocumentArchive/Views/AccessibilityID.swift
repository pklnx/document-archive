/// Accessibility identifiers for the views UI tests touch. UI tests query these, never the
/// (localized) text, so changing a label does not break them.
enum AccessibilityID {
    static let sidebar = "sidebar"
    static let settingsButton = "sidebar.settings"
    static let settings = "settings"
    static let settingsDone = "settings.done"

    /// Settings → Storage Location (folder copy, `StorageSettingsSection`).
    static let storageLocation = "settings.storage.location"
    static let storageChooseFolder = "settings.storage.chooseFolder"
    static let storageSyncNow = "settings.storage.syncNow"
    static let storageUseDefault = "settings.storage.useDefault"
    static let deletionsConfirm = "folderCopy.deletionsConfirm"
    static let deletionsDiscard = "folderCopy.deletionsDiscard"
    /// Sidebar footer line of the folder copy.
    static let folderCopyStatus = "sidebar.folderCopyStatus"

    static let documentList = "documentList"
    static let importMenu = "documentList.import"
    static let deleteSwipe = "documentList.deleteSwipe"
    static let deleteConfirm = "documentList.deleteConfirm"
    /// iOS: "Select" / "Done" for the list's edit mode.
    static let selectButton = "documentList.select"
    static let selectAll = "documentList.selectAll"

    /// Bulk actions for several selected documents (`BulkActionsView`, `BulkActionsMenu`).
    static let bulkActions = "bulkActions"
    static let bulkTags = "bulkActions.tags"
    static let bulkInbox = "bulkActions.inbox"
    static let bulkMore = "bulkActions.more"
    static let bulkReanalyze = "bulkActions.reanalyze"
    static let bulkReanalyzeConfirm = "bulkActions.reanalyzeConfirm"
    static let bulkCancel = "bulkActions.cancel"
    static let bulkDelete = "bulkActions.delete"
    static let bulkDeleteConfirm = "bulkActions.deleteConfirm"

    static let documentDetail = "documentDetail"
    /// iPad: back from the document to the list.
    static let showList = "documentDetail.showList"
    static let inspectorToggle = "documentDetail.inspectorToggle"
    static let inspector = "documentDetail.inspector"
    static let documentMore = "documentDetail.more"
    static let documentDelete = "documentDetail.delete"
    static let documentDeleteConfirm = "documentDetail.deleteConfirm"
    /// Print, copy and "Share as…" (#19) in the More menu and the context menu.
    static let documentPrint = "documentDetail.print"
    static let documentCopyPDF = "documentDetail.copyPDF"
    static let documentCopyText = "documentDetail.copyText"
    static let documentShareAs = "documentDetail.shareAs"
    static let shareOptions = "shareOptions"
    static let shareOptionsName = "shareOptions.name"
    static let shareOptionsFileName = "shareOptions.fileName"
    static let shareOptionsShare = "shareOptions.share"
    static let shareOptionsExport = "shareOptions.export"
    static let shareOptionsDone = "shareOptions.done"
    /// Markdown notes (#19): the rendered note, "Edit Notes", the editor and its "Done".
    static let notesRendered = "documentDetail.notes.rendered"
    static let notesEdit = "documentDetail.notes.edit"
    static let notesEditor = "documentDetail.notes.editor"
    static let notesDone = "documentDetail.notes.done"
    /// UI tests only: shown once the More menu's Delete action ran (see `UITestMarker`).
    static let documentDeleteRequested = "documentDetail.deleteRequested"

    static let ruleEditorCancel = "ruleEditor.cancel"

    /// Nested tags (#13): the list's subfolder chips and the "Move To…" sheet.
    static let subfolders = "documentList.subfolders"
    static func subfolderChip(_ name: String) -> String { "documentList.subfolder.\(name)" }
    static let tagMove = "sidebar.tag.move"
    /// The chevron that expands or collapses a tag's nested tags in the sidebar.
    static func tagDisclosure(_ name: String) -> String { "sidebar.tagDisclosure.\(name)" }
    static let tagParentPicker = "tagParentPicker"
    static let tagParentTopLevel = "tagParentPicker.topLevel"
    static func tagParentChoice(_ name: String) -> String { "tagParentPicker.tag.\(name)" }

    /// Saved views (#14): the sidebar section's menu, the editor, the manage sheet and the list's
    /// "Save as View" / "Edit View" button and banner.
    static let savedViewsMenu = "sidebar.savedViews.menu"
    static let manageSavedViews = "sidebar.savedViews.manage"
    static let savedViewEditor = "savedViewEditor"
    static let savedViewEditorName = "savedViewEditor.name"
    static let savedViewEditorCount = "savedViewEditor.count"
    static let savedViewEditorSave = "savedViewEditor.save"
    static let savedViewEditorCancel = "savedViewEditor.cancel"
    static let savedViewsManager = "savedViewsManager"
    static let savedViewsManagerDone = "savedViewsManager.done"
    /// "Delete" in the confirmation for tags, correspondents, types and saved views.
    static let deletionConfirm = "metadata.deleteConfirm"
    static func savedViewsManagerRow(_ name: String) -> String { "savedViewsManager.row.\(name)" }
    static func savedViewsManagerName(_ name: String) -> String { "savedViewsManager.name.\(name)" }
    /// The list's menu with the sort and "Save as View…" / "Edit View…".
    static let listOptions = "documentList.options"
    static let saveAsView = "documentList.saveAsView"
    static let editView = "documentList.editView"
    static let unresolvedBanner = "documentList.unresolvedBanner"

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
        case .savedView(let view): "sidebar.savedView.\(view.name)"
        }
    }

    /// "Add" button in a sidebar section header, e.g. `sidebar.add.tag`.
    static func sidebarAdd(_ section: String) -> String { "sidebar.add.\(section)" }

    static func documentRow(_ title: String) -> String { "documentList.row.\(title)" }
}
