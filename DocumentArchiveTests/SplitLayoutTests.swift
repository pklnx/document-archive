import SwiftUI
import Testing
@testable import DocumentArchive

/// Which columns an iPad shows after a document is opened.
@Suite struct SplitLayoutTests {
    @Test(arguments: [744.0, 820.0, 834.0, 999.0])
    func narrowWindowsShowOnlyTheDocument(width: Double) {
        #expect(SplitLayout.columnsAfterOpeningDocument(windowWidth: width) == .detailOnly)
    }

    @Test(arguments: [1000.0, 1032.0, 1133.0, 1376.0])
    func wideWindowsKeepTheListBeside(width: Double) {
        #expect(SplitLayout.columnsAfterOpeningDocument(windowWidth: width) == .doubleColumn)
    }
}
