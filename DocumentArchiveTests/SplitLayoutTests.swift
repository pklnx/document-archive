import SwiftUI
import Testing
@testable import DocumentArchive

/// Which columns an iPad shows around the open document.
@Suite struct SplitLayoutTests {
    @Test(arguments: [744.0, 820.0, 834.0, 999.0])
    func narrowWindowsShowOnlyTheDocument(width: Double) {
        #expect(SplitLayout.columnsAfterOpeningDocument(windowWidth: width) == .detailOnly)
    }

    @Test(arguments: [1000.0, 1032.0, 1133.0, 1376.0])
    func wideWindowsKeepTheListBeside(width: Double) {
        #expect(SplitLayout.columnsAfterOpeningDocument(windowWidth: width) == .doubleColumn)
    }

    // MARK: Closing the open document

    /// Regression: deleting the open document in a narrow window left only the empty document
    /// column, with no list and no Show List button.
    @Test func closingTheOnlyShownDocumentBringsTheListBack() {
        #expect(SplitLayout.columnsAfterClosingDocument(.detailOnly) == .doubleColumn)
    }

    // Not `.automatic`: on iOS it compares equal to `.detailOnly`, so it brings the list back too.
    @Test(arguments: [NavigationSplitViewVisibility.all, .doubleColumn])
    func closingADocumentKeepsOtherColumns(current: NavigationSplitViewVisibility) {
        #expect(SplitLayout.columnsAfterClosingDocument(current) == current)
    }

    // MARK: Resizing with a document open

    /// Regression: rotating an iPad mini or Air from landscape to portrait kept the list beside
    /// the document, so it was laid over it without a Show List button.
    @Test(arguments: [(1133.0, 744.0), (1180.0, 820.0), (1000.0, 999.0)])
    func narrowingBelowTheThresholdShowsOnlyTheDocument(from: Double, to: Double) {
        #expect(SplitLayout.columnsAfterResize(from: from, to: to) == .detailOnly)
    }

    @Test(arguments: [(744.0, 1133.0), (820.0, 1180.0), (999.0, 1000.0)])
    func wideningAboveTheThresholdShowsTheListBeside(from: Double, to: Double) {
        #expect(SplitLayout.columnsAfterResize(from: from, to: to) == .doubleColumn)
    }

    /// Resizes on one side of the threshold keep the user's choice (e.g. a hidden list).
    @Test(arguments: [(744.0, 820.0), (999.0, 500.0), (1133.0, 1376.0), (1376.0, 1000.0)])
    func resizingOnOneSideKeepsTheColumns(from: Double, to: Double) {
        #expect(SplitLayout.columnsAfterResize(from: from, to: to) == nil)
    }
}
