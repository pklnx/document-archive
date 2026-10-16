#if os(iOS)
import XCTest

/// A few smoke tests on iPhone and iPad. The app starts with generated sample data in memory
/// (`-UITestSeed`), never touches the real archive and never calls Mistral. Elements are found by
/// accessibility identifier only (see `AccessibilityID` in the app), never by their German text.
/// iOS only (swipes, rotation, edit mode, navigation bars); the Mac has `MacSmokeTests`.
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
        launchApp()
    }

    /// Generous: slow CI runners need a long time for the first launch of a simulator.
    private let launchTimeout: TimeInterval = 60
    /// Set while the first launch attempt runs; its failures are collected instead of recorded.
    private var firstLaunchIssues: [XCTIssue]?

    /// Launches the app and waits for the list or the sidebar. On slow CI runners a launch
    /// sometimes fails ("Timed out while launching application via Xcode", "Failed to get
    /// background assertion") or the app shows nothing for a long time; then it is terminated
    /// and launched once more. A second failure fails the test as before.
    private func launchApp() {
        firstLaunchIssues = []
        continueAfterFailure = true   // a failed launch must return here instead of ending the test
        app.launch()
        let issues = firstLaunchIssues ?? []
        firstLaunchIssues = nil
        continueAfterFailure = false
        if issues.isEmpty, appIsReady() { return }

        let reason = issues.map(\.compactDescription).joined(separator: "; ")
        XCTContext.runActivity(named: "Launch again: \(reason.isEmpty ? "no list or sidebar" : reason)") { _ in
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(appIsReady(), "neither the list nor the sidebar appeared after launching twice")
    }

    private func appIsReady() -> Bool {
        let list = element("documentList")
        let sidebar = element("sidebar.settings")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in list.exists || sidebar.exists }, object: nil)
        return XCTWaiter().wait(for: [ready], timeout: launchTimeout) == .completed
    }

    override func record(_ issue: XCTIssue) {
        if firstLaunchIssues != nil {
            firstLaunchIssues?.append(issue)
        } else {
            super.record(issue)
        }
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

    /// A sidebar row further down (tags on a small iPhone): the list only creates rows once they
    /// are scrolled into view.
    private func sidebarRow(_ id: String) -> XCUIElement {
        let row = element(id)
        for _ in 0..<5 where !row.exists || !row.isHittable {
            element("sidebar").swipeUp()
        }
        XCTAssertTrue(row.isHittable, "\(id) not reachable in the sidebar")
        return row
    }

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
        sidebarRow("sidebar.tag.Important").tap()
        XCTAssertTrue(row("Credit card terms").waitForExistence(timeout: 5))
        XCTAssertFalse(row(firstDocument).exists)
    }

    /// Nested tags (#13): Auto's list includes Golf's documents and shows Golf as a subfolder.
    /// On iPhone the chip pushes Golf's list and Back returns to Auto, then to the sidebar, which
    /// shows only top-level tags. On iPad the chip selects Golf in the sidebar's tag tree.
    func testNestedTagDrillDown() {
        showSidebar()
        sidebarRow("sidebar.tag.Auto").tap()
        XCTAssertTrue(row("Car insurance").waitForExistence(timeout: 5), "Auto's own document missing")
        XCTAssertTrue(row("Golf inspection").exists, "Auto must include the documents of Golf")
        XCTAssertFalse(row(firstDocument).exists)
        let chip = element("documentList.subfolder.Golf")
        XCTAssertTrue(waitUntilHittable(chip), "no subfolder chip for Golf")
        attachScreenshot("Auto with subfolder Golf")

        chip.tap()
        XCTAssertTrue(row("Car insurance").waitForNonExistence(timeout: 5), "Golf's list shows Auto's document")
        XCTAssertTrue(row("Golf inspection").exists)
        attachScreenshot("Golf")

        if isPhone {
            // A document opens from the pushed list, and Back returns to that list.
            openDocument("Golf inspection")
            attachScreenshot("document from Golf")
            backButton().tap()
            XCTAssertTrue(waitUntilHittable(row("Golf inspection")), "Back did not return to Golf")
            XCTAssertFalse(row("Car insurance").exists)

            backButton().tap()
            XCTAssertTrue(waitUntilHittable(row("Car insurance")), "Back did not return to Auto")
            XCTAssertTrue(chip.exists)
            backButton().tap()
            XCTAssertTrue(waitUntilHittable(element("sidebar.settings")), "second Back did not return to the sidebar")
            _ = sidebarRow("sidebar.tag.Auto")
            XCTAssertFalse(element("sidebar.tag.Golf").exists, "iPhone shows only top-level tags in the sidebar")
            attachScreenshot("sidebar after going back")
        } else {
            showSidebar()
            let golfRow = element("sidebar.tag.Golf")
            XCTAssertTrue(golfRow.waitForExistence(timeout: 5), "Golf not shown in the tag tree")
            attachScreenshot("sidebar with Golf selected")
            // The chevron collapses and expands Auto without selecting it.
            element("sidebar.tagDisclosure.Auto").tap()
            XCTAssertTrue(golfRow.waitForNonExistence(timeout: 5), "Auto did not collapse")
            XCTAssertTrue(row("Golf inspection").exists && !row("Car insurance").exists, "the chevron changed the list")
            element("sidebar.tagDisclosure.Auto").tap()
            XCTAssertTrue(golfRow.waitForExistence(timeout: 5), "Auto did not expand")
            element("sidebar.tag.Auto").tap()
            attachScreenshot("Auto selected in the tree")
        }
    }

    /// The leading button of the frontmost navigation bar (Back on iPhone).
    private func backButton() -> XCUIElement {
        let bar = app.navigationBars.allElementsBoundByIndex.last { $0.isHittable } ?? app.navigationBars.firstMatch
        return bar.buttons.element(boundBy: 0)
    }

    /// Saved views (#14): the seeded view filters the list; "Save as View…" creates a view from
    /// the list in front (editor: popover on iPad, sheet on iPhone) and opens it; the "Manage
    /// Views" sheet reorders the views, and the sidebar follows.
    func testSavedViewsCreateOpenAndReorder() {
        showSidebar()
        sidebarRow("sidebar.savedView.Taxes").tap()
        XCTAssertTrue(row(firstDocument).waitForExistence(timeout: 5), "the seeded view misses a Tax document")
        XCTAssertTrue(row(favoriteDocument).exists)
        XCTAssertFalse(row("Water bill").exists, "the seeded view shows a document without Tax")
        attachScreenshot("seeded view")

        showSidebar()
        sidebarRow("sidebar.favorites").tap()
        XCTAssertTrue(row(favoriteDocument).waitForExistence(timeout: 5))
        let options = element("documentList.options")
        // iPad portrait: the sidebar lies over the list until it is closed.
        if !waitUntilHittable(options) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(waitUntilHittable(options), "no menu with Save as View")
        options.tap()
        let saveAsView = element("documentList.saveAsView")
        XCTAssertTrue(waitUntilHittable(saveAsView), "no Save as View in the menu")
        saveAsView.tap()
        let name = element("savedViewEditor.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the editor did not open")
        XCTAssertTrue(element("savedViewEditor.count").exists, "no live count")
        attachScreenshot("editor from Favorites")
        // Prefilled with the list's name; replaced by a fixed one for the identifiers below.
        name.tap()
        let current = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5) + "Starred")
        element("savedViewEditor.save").tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5), "the editor did not close")
        XCTAssertTrue(row(favoriteDocument).waitForExistence(timeout: 5), "the new view does not show its document")
        XCTAssertFalse(row(firstDocument).exists, "the new view shows more than the favorites")

        showSidebar()
        let taxes = sidebarRow("sidebar.savedView.Taxes")
        let starred = element("sidebar.savedView.Starred")
        XCTAssertTrue(starred.waitForExistence(timeout: 5), "the new view is not in the sidebar")
        XCTAssertLessThan(taxes.frame.minY, starred.frame.minY, "a new view goes after the others")
        attachScreenshot("sidebar with two views")

        element("sidebar.savedViews.menu").tap()
        let manage = element("sidebar.savedViews.manage")
        XCTAssertTrue(waitUntilHittable(manage), "no Manage Views in the menu")
        manage.tap()
        let starredRow = element("savedViewsManager.row.Starred")
        XCTAssertTrue(starredRow.waitForExistence(timeout: 5), "the manage sheet did not open")
        // The reorder handle of the row (the system's "line.horizontal.3" image), dragged above Taxes.
        let taxesRow = element("savedViewsManager.row.Taxes")
        let handle = app.images.matching(identifier: "line.horizontal.3").allElementsBoundByIndex
            .first { abs($0.frame.midY - starredRow.frame.midY) < 10 }
        XCTAssertNotNil(handle, "no reorder handle")
        handle?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: taxesRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)))
        XCTAssertLessThan(starredRow.frame.minY, taxesRow.frame.minY, "dragging did not move the row")
        attachScreenshot("manage sheet after moving")
        element("savedViewsManager.done").tap()
        XCTAssertTrue(starredRow.waitForNonExistence(timeout: 5), "the manage sheet did not close")
        _ = sidebarRow("sidebar.savedView.Taxes")
        XCTAssertLessThan(element("sidebar.savedView.Starred").frame.minY, element("sidebar.savedView.Taxes").frame.minY,
                          "the sidebar does not follow the new order")
        attachScreenshot("sidebar after reordering")
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
        // The folder copy's section is there; with sample data it stays off (#8).
        let storage = element("settings.storage.location")
        for _ in 0..<6 where !storage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(storage.isHittable, "storage location section missing")
        XCTAssertFalse(element("settings.storage.chooseFolder").exists, "folder copy offered with sample data")
        attachScreenshot("settings storage location")
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
        // Once flaky at this step: the list was not there yet when reveal() looked for the row.
        XCTAssertTrue(element("documentList").waitForExistence(timeout: 15), "no document list")
        let first = row(firstDocument)
        _ = waitUntilHittable(first, timeout: 10)   // still settling after the launch
        reveal(first, "row \(firstDocument)")

        first.swipeLeft()
        let deleteSwipe = element("documentList.deleteSwipe")
        XCTAssertTrue(waitUntilHittable(deleteSwipe), "no Delete swipe action")
        deleteSwipe.tap()
        let confirm = element("documentList.deleteConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attachScreenshot("delete dialog")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()   // outside the dialog
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "dialog did not close")
        XCTAssertTrue(first.exists, "nothing was deleted")

        let second = row(secondDocument)
        second.swipeLeft()
        XCTAssertTrue(waitUntilHittable(deleteSwipe), "no Delete swipe action for the second document")
        deleteSwipe.tap()
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
        let more = element("documentDetail.more")
        XCTAssertTrue(waitUntilHittable(more), "no More menu")
        more.tap()
        let delete = element("documentDetail.delete")
        // Not before the menu has finished opening: a tap on a menu still animating in can be lost.
        XCTAssertTrue(waitUntilHittable(delete, timeout: 10), "no Delete in the More menu")
        delete.tap()
        attachScreenshot("after tapping Delete")
        let confirm = element("documentDetail.deleteConfirm")
        // Once failed on iPadOS 26.5 (CI) with the inspector column open; the marker tells
        // whether the tap ran the action and only the dialog is missing.
        if !waitUntilHittable(confirm, timeout: 10) {
            let actionRan = element("documentDetail.deleteRequested").exists
            attachScreenshot("no delete confirmation")
            XCTFail(actionRan ? "no delete confirmation, although the Delete action ran"
                              : "no delete confirmation: the Delete tap did not run the action")
            return
        }
        attachScreenshot("delete confirmation of the open document")
        XCTAssertTrue(element("documentDetail.deleteRequested").exists, "the marker for the Delete action is missing")
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
        attachScreenshot("after tapping Delete for the selection")
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
#endif
