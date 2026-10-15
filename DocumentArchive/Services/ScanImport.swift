import CoreGraphics
import Foundation
import SwiftData

/// The pages of a camera scan. VisionKit's `VNDocumentCameraScan` conforms to it on iOS;
/// tests use generated pages, so the scan import can be tested without a camera.
protocol ScannedPages {
    var pageCount: Int { get }
    /// The page image, or `nil` when it cannot be read.
    func image(at index: Int) -> CGImage?
}

/// Turns a camera scan into one multi-page document.
@MainActor
enum ScanImport {
    enum Result {
        /// The document was created; `skippedPages` lists unreadable pages (1-based).
        case imported(Document, skippedPages: [Int])
        /// No page could be read, so nothing was created.
        case empty

        /// A message for the user, or `nil` when everything went fine.
        var notice: ImportNotice? {
            switch self {
            case .imported(_, let skippedPages) where !skippedPages.isEmpty:
                let pages = skippedPages.map(String.init).joined(separator: ", ")
                return ImportNotice(title: String(localized: "Scan partly imported"),
                                    message: String(localized: "These pages could not be read and were skipped: \(pages)"))
            case .imported:
                return nil
            case .empty:
                return ImportNotice(title: String(localized: "Scan failed"),
                                    message: String(localized: "No page of the scan could be read."))
            }
        }
    }

    static func importScan(_ pages: ScannedPages, into context: ModelContext) -> Result {
        var images: [CGImage] = []
        var skipped: [Int] = []
        for index in 0..<pages.pageCount {
            if let image = pages.image(at: index) {
                images.append(image)
            } else {
                skipped.append(index + 1)
            }
        }
        guard !images.isEmpty,
              let document = DocumentImporter.importImages(images, source: .scan, into: context)
        else { return .empty }
        return .imported(document, skippedPages: skipped)
    }
}
