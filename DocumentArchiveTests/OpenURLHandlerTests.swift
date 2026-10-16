import Foundation
import Testing
@testable import DocumentArchive

@Suite @MainActor struct OpenURLHandlerTests {
    @Test func fileURLsGoToTheExternalImport() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        // Without an archive the file waits in the queue, so nothing is imported here.
        let externalImport = ExternalImport(inboxFolder: directory.appending(path: "Inbox"))
        let file = directory.appending(path: "Rechnung.pdf")

        #expect(OpenURLHandler.handle(file, externalImport: externalImport))
        #expect(externalImport.queued.map(\.url) == [file])
        #expect(externalImport.queued.map(\.origin) == [.openWith])
    }

    /// Other URLs are ignored for now; #15 adds the `documentarchive://` branch.
    @Test func otherURLsAreIgnored() throws {
        let externalImport = ExternalImport(inboxFolder: try TestSupport.makeTemporaryDirectory())

        #expect(!OpenURLHandler.handle(URL(string: "documentarchive://document/1")!, externalImport: externalImport))
        #expect(!OpenURLHandler.handle(URL(string: "https://example.com/Rechnung.pdf")!, externalImport: externalImport))
        #expect(externalImport.queued.isEmpty)
    }
}

/// The app offers itself for PDFs and images in "Open with" (macOS) and "Open in…" (iOS),
/// without becoming the default viewer. The tests are hosted by the app, so `Bundle.main` is
/// the app's Info.plist.
@Suite struct DeclaredDocumentTypesTests {
    let info = Bundle.main.infoDictionary ?? [:]

    @Test func pdfsAndImagesAreDeclaredAsViewerWithAlternateRank() throws {
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(Set(contentTypes) == ["com.adobe.pdf", "public.image"])
        for type in types {
            #expect(type["CFBundleTypeRole"] as? String == "Viewer")
            #expect(type["LSHandlerRank"] as? String == "Alternate", "never the default app for PDFs")
            #expect((type["CFBundleTypeName"] as? String)?.isEmpty == false)
        }
    }

    /// Both keys would expose the app's `Documents` folder in Files.
    @Test func documentsFolderIsNotShared() {
        #expect(info["UIFileSharingEnabled"] == nil)
        #expect(info["UISupportsDocumentBrowser"] == nil)
    }

    #if os(iOS)
    /// Files hands over the file itself (security-scoped) instead of a copy.
    @Test func filesAreOpenedInPlace() {
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
    }
    #endif
}
