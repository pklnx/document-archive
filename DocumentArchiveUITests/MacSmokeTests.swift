#if os(macOS)
import XCTest

/// A few smoke tests on the Mac: pointer, ⌘-click and keyboard instead of the iOS gestures.
/// The app starts with generated sample data in memory (`-UITestSeed`), never touches the real
/// archive and never calls Mistral. Elements are found by accessibility identifier only (see
/// `AccessibilityID` in the app), never by their German text. Every test attaches screenshots, so
/// a review can look at the Mac UI without running the app.
///
/// macOS UI tests take over the pointer and the keyboard of the Mac they run on, and need
/// automation mode (`automationmodetool enable-automationmode-without-authentication`).
///
/// `@MainActor`: XCTest runs UI tests on the main thread, and the UI automation API is
/// main-actor isolated. `setUp` and `tearDown` are the `async` variants, which may run on the
/// main actor; a failed assertion there still ends the test (`continueAfterFailure`).
@MainActor
final class MacSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    /// Sample documents from `UITestSeed`, newest first.
    private let firstDocument = "Electricity bill March"
    private let secondDocument = "Account statement"
    private let favoriteDocument = "Medical invoice"
    /// All documents of `UITestSeed` ("All Documents").
    private let seededDocumentCount = 7

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Not "-ApplePersistenceIgnoreState YES": with it the SwiftUI app starts without a window.
        app.launchArguments = ["-UITestSeed"]
        app.launch()
        XCTAssertTrue(element("documentList").waitForExistence(timeout: 30), "no document list after the launch")
        // A known list, whatever the window showed first.
        element("sidebar.all").click()
        XCTAssertTrue(row(firstDocument).waitForExistence(timeout: 5), "sample documents missing")
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func row(_ title: String) -> XCUIElement { element("documentList.row.\(title)") }

    /// The open document. On the Mac the PDF view hides the detail's own identifier
    /// (`documentDetail`), so its toolbar button stands for it.
    private var documentDetail: XCUIElement { element("documentDetail.inspectorToggle") }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The element tree, attached when a query found something unexpected.
    private func attachHierarchy(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Rows of the document list that are selected (SwiftUI's `List` is an outline or a table).
    private var selectedRowCount: Int {
        let rowTypes = [XCUIElement.ElementType.outlineRow, .tableRow].map(\.rawValue)
        return element("documentList").descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND isSelected == true", rowTypes)).count
    }

    private func openDocument(_ title: String) {
        let row = row(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "row \(title) missing")
        row.click()
        XCTAssertTrue(documentDetail.waitForExistence(timeout: 5), "detail did not open")
    }

    /// Opens the inspector of the open document and returns whether it was open before (the app
    /// remembers the state; tests put it back).
    private func showInspector() -> Bool {
        let inspector = element("documentDetail.inspector")
        let wasOpen = inspector.waitForExistence(timeout: 2)
        if !wasOpen {
            element("documentDetail.inspectorToggle").click()
            XCTAssertTrue(inspector.waitForExistence(timeout: 5), "inspector did not open")
        }
        return wasOpen
    }

    private func restoreInspector(wasOpen: Bool) {
        let inspector = element("documentDetail.inspector")
        if inspector.exists != wasOpen { element("documentDetail.inspectorToggle").click() }
    }

    /// The delete confirmation for the list's selection (`BulkActionCoordinator`), cancelled with
    /// Escape. Returns whether it appeared.
    private func deleteConfirmationAppeared(timeout: TimeInterval) -> Bool {
        element("bulkActions.deleteConfirm").waitForExistence(timeout: timeout)
    }

    // MARK: - Tests

    func testOpenDocumentFromTheList() {
        attachScreenshot("list")
        openDocument(firstDocument)
        XCTAssertTrue(documentDetail.isHittable)
        attachScreenshot("document")
        openDocument(secondDocument)
        attachScreenshot("second document")
    }

    func testInspectorOpensAndCloses() {
        openDocument(firstDocument)
        let inspector = element("documentDetail.inspector")
        let toggle = element("documentDetail.inspectorToggle")
        let wasOpen = inspector.waitForExistence(timeout: 2)
        if wasOpen {
            toggle.click()   // the column was open from the last session
            XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "inspector did not close")
        }
        attachScreenshot("document without inspector")

        toggle.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "inspector did not open")
        XCTAssertTrue(element("documentDetail.inspector.title").exists, "no title field in the inspector")
        attachScreenshot("inspector")

        toggle.click()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "inspector did not close")
        restoreInspector(wasOpen: wasOpen)
    }

    /// ⌘-click adds a second document to the selection: the detail column shows the bulk actions
    /// instead of a document. ⌘A selects every document of the list.
    func testCommandClickAndSelectAll() {
        row(firstDocument).click()
        XCTAssertTrue(documentDetail.waitForExistence(timeout: 5), "first document did not open")
        XCUIElement.perform(withKeyModifiers: .command) {
            row(secondDocument).click()
        }
        XCTAssertTrue(element("bulkActions").waitForExistence(timeout: 5), "no bulk actions for two documents")
        XCTAssertFalse(documentDetail.exists, "a document is still open with two selected")
        if selectedRowCount != 2 { attachHierarchy("selection of two") }
        XCTAssertEqual(selectedRowCount, 2)
        attachScreenshot("two documents selected")

        app.typeKey("a", modifierFlags: .command)
        let all = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            selectedRowCount == seededDocumentCount
        }, object: nil)
        if XCTWaiter().wait(for: [all], timeout: 5) != .completed { attachHierarchy("select all") }
        XCTAssertEqual(selectedRowCount, seededDocumentCount, "⌘A did not select every document")
        XCTAssertTrue(element("bulkActions").exists)
        attachScreenshot("all documents selected")
    }

    /// ⌫ with the list focused asks before deleting the selection; Cancel keeps everything.
    func testDeleteKeyInTheListAsksFirst() {
        row(firstDocument).click()
        XCTAssertTrue(documentDetail.waitForExistence(timeout: 5))
        row(firstDocument).click()   // the list keeps the focus, not the PDF view
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(deleteConfirmationAppeared(timeout: 5), "⌫ in the list did not ask to delete")
        attachScreenshot("delete confirmation")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("bulkActions.deleteConfirm").waitForNonExistence(timeout: 5), "dialog did not close")
        XCTAssertTrue(row(firstDocument).exists, "the document was deleted although the dialog was cancelled")
    }

    /// Regression guard (#10): ⌫ in the inspector's title field edits the title and never asks to
    /// delete (or deletes) the document.
    func testDeleteKeyInTheTitleFieldOnlyEditsText() {
        openDocument(firstDocument)
        let wasOpen = showInspector()
        let title = element("documentDetail.inspector.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no title field")
        title.click()
        app.typeKey(.downArrow, modifierFlags: .command)   // end of the text
        app.typeKey("X", modifierFlags: [])
        XCTAssertTrue(row(firstDocument + "X").waitForExistence(timeout: 5), "typing did not reach the title")
        attachScreenshot("title edited")

        app.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(deleteConfirmationAppeared(timeout: 2), "⌫ in the title field asked to delete the document")
        XCTAssertTrue(row(firstDocument).waitForExistence(timeout: 5), "⌫ did not remove the typed character")
        XCTAssertTrue(documentDetail.exists, "the document was closed")
        XCTAssertEqual(element("documentList").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'documentList.row.'")).count,
                       seededDocumentCount, "a document disappeared")
        attachScreenshot("after ⌫ in the title field")
        restoreInspector(wasOpen: wasOpen)
    }

    /// ⌘, opens the settings window, ⌘W closes it again.
    func testSettingsWindowOpensAndCloses() {
        app.typeKey(",", modifierFlags: .command)
        let settings = element("settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⌘, did not open the settings")
        // Only the settings window: a screenshot of the app is the whole screen on the Mac.
        let window = app.windows.containing(.any, identifier: "settings").firstMatch
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "⌘W did not close the settings")
        XCTAssertTrue(element("documentList").exists, "the main window closed instead")
    }

    func testSidebarFiltersTheList() {
        element("sidebar.favorites").click()
        XCTAssertTrue(row(favoriteDocument).waitForExistence(timeout: 5))
        XCTAssertTrue(row(firstDocument).waitForNonExistence(timeout: 5), "favorites show other documents")
        attachScreenshot("favorites")

        element("sidebar.tag.Important").click()
        XCTAssertTrue(row("Credit card terms").waitForExistence(timeout: 5))
        XCTAssertTrue(row(firstDocument).waitForNonExistence(timeout: 5), "the tag shows other documents")
        attachScreenshot("tag Important")
    }
}
#endif
