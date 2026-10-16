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
                // Prefer a bar that is not the document's (iPad). Only on iPhone may it be the
                // document's bar, whose first button is Back. On iPad that bar's first button is
                // the document's own ("Mark as Done"), so stop and let the assertion fail.
                let bars = app.navigationBars.allElementsBoundByIndex
                let bar = bars.first { !$0.buttons["documentDetail.inspectorToggle"].exists }
                    ?? (isPhone ? bars.first : nil)
                guard let button = bar?.buttons.element(boundBy: 0), button.exists,
                      !button.identifier.hasPrefix("documentDetail.") else { break }
                button.tap()
            }
            _ = element.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(element.isHittable, "\(what) not reachable")
    }

    /// An iPad window narrower than `SplitLayout.sideBySideMinimumWidth` (iPad mini, iPad Air
    /// and iPad Pro 11" in portrait): an opened document is shown alone, with Show List.
    private var isNarrowIPad: Bool { !isPhone && app.windows.firstMatch.frame.width < 1000 }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    /// Rotates and waits until the window has the new orientation.
    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let window = app.windows.firstMatch
        let portrait = orientation.isPortrait
        for _ in 0..<20 where (window.frame.width < window.frame.height) != portrait {
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 1)   // the split view settles after the window
    }

    /// Narrow iPad with a document open: only the document is shown and Show List is offered.
    private func assertOnlyTheDocumentIsShown(_ listRow: String, _ situation: String) {
        XCTAssertTrue(element("documentDetail.showList").waitForExistence(timeout: 5),
                      "\(situation): no Show List button")
        XCTAssertTrue(element("documentDetail.inspectorToggle").isHittable, "\(situation): document not in front")
        XCTAssertFalse(row(listRow).isHittable, "\(situation): the list covers the document")
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
        if isNarrowIPad {
            // Regression (iPadOS 26): with only the document shown there was no way back.
            assertOnlyTheDocumentIsShown(secondDocument, "opened")
            element("documentDetail.showList").tap()
            XCTAssertTrue(waitUntilHittable(row(secondDocument)), "Show List did not bring the list back")
            attachScreenshot("list over the document")
            // Tapping the document that is already open brings it to the front again.
            row(firstDocument).tap()
            assertOnlyTheDocumentIsShown(secondDocument, "re-selected")
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

        // Back to portrait with the document open: the narrow window shows only the document
        // again instead of laying the list over it.
        rotate(to: .portrait)
        attachScreenshot("portrait document after rotation")
        if isNarrowIPad { assertOnlyTheDocumentIsShown(firstDocument, "rotated to portrait") }
        openDocument(firstDocument)
    }

    /// Regression: deleting the open document on a narrow iPad left only the empty document
    /// column, with no list and no Show List button.
    func testDeletingTheOpenDocumentShowsTheList() {
        openDocument(firstDocument)
        element("documentDetail.more").tap()
        let delete = element("documentDetail.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = element("documentDetail.deleteConfirm")
        XCTAssertTrue(waitUntilHittable(confirm, timeout: 10), "no delete confirmation")
        confirm.tap()
        // Slow CI runners (iOS 26.5) close the dialog late; wait for it before looking at the list.
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 15), "delete confirmation did not close")
        attachScreenshot("after deleting the open document")

        // No reveal(): the list must be there without searching for a button, on iPhone too
        // (the empty document column must not stay pushed).
        XCTAssertTrue(waitUntilHittable(row(secondDocument), timeout: 10),
                      "list not shown after deleting the open document")
        XCTAssertFalse(row(firstDocument).exists, "document was not deleted")
        openDocument(secondDocument)
    }

    /// Select mode: several documents are selected without opening one, and deleted together.
    func testSelectSeveralDocumentsAndDeleteThem() {
        let select = element("documentList.select")
        reveal(select, "Select button")
        select.tap()
        row(firstDocument).tap()
        row(secondDocument).tap()
        attachScreenshot("two documents selected")
        // Selecting in edit mode must not open a document.
        XCTAssertFalse(element("documentDetail").exists, "a document opened while selecting")
        let more = element("bulkActions.more")
        if isPhone || isNarrowIPad {
            // Like on the iPhone, the actions are in the list's bottom toolbar.
            XCTAssertTrue(waitUntilHittable(more), "no bottom toolbar while selecting")
            more.tap()
        } else {
            XCTAssertTrue(element("bulkActions").waitForExistence(timeout: 5), "no bulk actions for the selection")
            XCTAssertFalse(more.exists, "bottom toolbar beside the bulk actions column")
        }
        let delete = element("bulkActions.delete")
        if !isPhone, !isNarrowIPad, delete.waitForExistence(timeout: 5), !delete.isHittable {
            element("bulkActions").swipeUp()   // at the end of the actions column
        }
        XCTAssertTrue(waitUntilHittable(delete), "no Delete for the selection")
        delete.tap()
        let confirm = element("bulkActions.deleteConfirm")
        XCTAssertTrue(waitUntilHittable(confirm, timeout: 10), "no delete confirmation")
        attachScreenshot("bulk delete confirmation")
        confirm.tap()
        XCTAssertTrue(row(firstDocument).waitForNonExistence(timeout: 10), "first document was not deleted")
        XCTAssertFalse(row(secondDocument).exists, "second document was not deleted")
        XCTAssertTrue(row(favoriteDocument).exists, "an unselected document was deleted")

        // Leaving select mode; a tap opens a document again.
        reveal(select, "Done button")
        select.tap()
        openDocument(favoriteDocument)
    }
}
