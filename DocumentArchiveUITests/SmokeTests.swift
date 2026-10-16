import XCTest

/// A few smoke tests on iPhone and iPad. The app starts with generated sample data in memory
/// (`-UITestSeed`), never touches the real archive and never calls Mistral. Elements are found by
/// accessibility identifier only (see `AccessibilityID` in the app), never by their German text.
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    /// Sample documents from `UITestSeed`, newest first.
    private let firstDocument = "Electricity bill March"
    private let secondDocument = "Account statement"
    private let favoriteDocument = "Medical invoice"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-UITestSeed"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func row(_ title: String) -> XCUIElement { element("documentList.row.\(title)") }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Makes `element` reachable, one step at a time: on iPad from an opened document with the
    /// app's "Show List" button, otherwise with the leading button of a navigation bar (back on
    /// iPhone, the sidebar button on iPad). Never a toolbar button of the document.
    private func reveal(_ element: XCUIElement, _ what: String) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<3 where !element.isHittable {
            let showList = self.element("documentDetail.showList")
            if showList.exists, showList.isHittable {
                showList.tap()
            } else {
                // Prefer a bar that is not the document's (iPad); on iPhone only the document's
                // bar is there, and its first button is Back.
                let bars = app.navigationBars.allElementsBoundByIndex
                let bar = bars.first { !$0.buttons["documentDetail.inspectorToggle"].exists } ?? bars.first
                guard let button = bar?.buttons.element(boundBy: 0), button.exists,
                      button.identifier != "documentDetail.inspectorToggle" else { break }
                button.tap()
            }
            _ = element.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(element.isHittable, "\(what) not reachable")
    }

    private func showSidebar() { reveal(element("sidebar.settings"), "sidebar") }

    private func openDocument(_ title: String) {
        let row = row(title)
        reveal(row, "row \(title)")
        row.tap()
        XCTAssertTrue(element("documentDetail").waitForExistence(timeout: 5), "detail did not open")
    }

    // MARK: - Tests

    func testOpenDocumentFromTheList() {
        openDocument(firstDocument)
        // The document comes to the front, not covered by the list.
        XCTAssertTrue(element("documentDetail.inspectorToggle").isHittable)
        if !isPhone, element("documentDetail.showList").exists {
            // Regression (iPadOS 26): with only the document shown there was no way back.
            element("documentDetail.showList").tap()
            XCTAssertTrue(row(secondDocument).waitForExistence(timeout: 5) && row(secondDocument).isHittable,
                          "Show List did not bring the list back")
        }
        if isPhone {
            // On iPhone the inspector is a sheet that stays closed until Info is tapped.
            XCTAssertFalse(element("documentDetail.inspector").waitForExistence(timeout: 3),
                           "the inspector sheet must not open by itself")
            attachScreenshot("document")
        }
        openDocument(secondDocument)   // back to the list, then the next document
    }

    func testSidebarFiltersTheList() {
        showSidebar()
        attachScreenshot("sidebar")
        element("sidebar.favorites").tap()
        XCTAssertTrue(row(favoriteDocument).waitForExistence(timeout: 5))
        XCTAssertFalse(row(firstDocument).exists)

        showSidebar()
        element("sidebar.tag.Important").tap()
        XCTAssertTrue(row("Credit card terms").waitForExistence(timeout: 5))
        XCTAssertFalse(row(firstDocument).exists)
    }

    func testInspectorOpensAndCloses() {
        openDocument(firstDocument)
        attachScreenshot("document")
        let inspector = element("documentDetail.inspector")
        let toggle = element("documentDetail.inspectorToggle")
        if !isPhone, inspector.exists {
            toggle.tap()   // the column was open from the last session
            XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        }

        toggle.tap()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "inspector did not open")
        attachScreenshot("inspector")

        if isPhone {
            app.swipeDown(velocity: .fast)   // the sheet closes like any sheet
            if inspector.exists { inspector.swipeDown(velocity: .fast) }
        } else {
            toggle.tap()
        }
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "inspector did not close")
    }

    func testSettingsOpenAndClose() {
        showSidebar()
        element("sidebar.settings").tap()
        let settings = element("settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        attachScreenshot("settings")
        element("settings.done").tap()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
    }

    func testRuleEditorCanBeCancelled() {
        showSidebar()
        element("sidebar.add.tag").tap()
        let cancel = element("ruleEditor.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        attachScreenshot("rule editor")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("sidebar.settings").isHittable)
    }

    /// Regression: the dialog used a constant binding, so dismissing it without a button left it
    /// stuck. Dismissed by tapping outside, it must come back for the next document.
    func testDeleteDialogCanBeDismissedAndShownAgain() {
        let first = row(firstDocument)
        reveal(first, "row \(firstDocument)")

        first.swipeLeft()
        element("documentList.deleteSwipe").tap()
        let confirm = element("documentList.deleteConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attachScreenshot("delete dialog")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()   // outside the dialog
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "dialog did not close")
        XCTAssertTrue(first.exists, "nothing was deleted")

        let second = row(secondDocument)
        second.swipeLeft()
        element("documentList.deleteSwipe").tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "dialog did not show again")
        confirm.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5), "document was not deleted")
        XCTAssertTrue(first.exists)
    }

    func testNavigationInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openDocument(firstDocument)
        attachScreenshot("landscape document")
        showSidebar()
        attachScreenshot("landscape sidebar")
        element("sidebar.inbox").tap()
        openDocument("Water bill")
    }
}
