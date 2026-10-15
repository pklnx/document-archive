import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

/// Pages of a fake scan; `nil` entries are pages that cannot be read.
private struct FakeScan: ScannedPages {
    var pages: [CGImage?]
    var pageCount: Int { pages.count }
    func image(at index: Int) -> CGImage? { pages[index] }
}

extension GlobalStateTests {
    @Suite @MainActor struct ScanImportTests {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }

        init() throws {
            MistralStub.reset()   // local processing only
            container = try TestSupport.makeContainer()
        }

        private func page(_ text: String) -> CGImage { TestSupport.renderPage(lines: [text]) }

        @Test func threePagesBecomeOneProcessedDocument() async throws {
            let result = ScanImport.importScan(FakeScan(pages: [page("Seite 1"), page("Seite 2"), page("Seite 3")]),
                                               into: context)

            guard case .imported(let document, let skipped) = result else {
                Issue.record("expected a document, got \(result)")
                return
            }
            try await TestSupport.waitUntilProcessed([document])
            #expect(skipped.isEmpty)
            #expect(result.notice == nil)
            #expect(document.source == .scan)
            #expect(document.pageCount == 3)
            #expect(document.hasAutomaticTitle)
            #expect(Document.automaticTitlePrefixes.contains { document.title.hasPrefix($0) })
            #expect(document.thumbnailData != nil)
            #expect(document.extractedText.contains("Seite"))
            #expect(try context.fetch(FetchDescriptor<Document>()).count == 1)
        }

        @Test func unreadablePagesAreSkippedAndReported() async throws {
            let result = ScanImport.importScan(FakeScan(pages: [page("Seite 1"), nil, page("Seite 3"), nil]), into: context)

            guard case .imported(let document, let skipped) = result else {
                Issue.record("expected a document, got \(result)")
                return
            }
            try await TestSupport.waitUntilProcessed([document])
            #expect(skipped == [2, 4])
            #expect(document.pageCount == 2)
            let notice = try #require(result.notice)
            #expect(notice.message.contains("2, 4"))
        }

        @Test(arguments: [0, 3])
        func scanWithoutReadablePagesCreatesNothing(pageCount: Int) throws {
            let result = ScanImport.importScan(FakeScan(pages: Array(repeating: nil, count: pageCount)), into: context)

            guard case .empty = result else {
                Issue.record("expected .empty, got \(result)")
                return
            }
            #expect(result.notice != nil)
            #expect(try context.fetch(FetchDescriptor<Document>()).isEmpty)
        }
    }
}
