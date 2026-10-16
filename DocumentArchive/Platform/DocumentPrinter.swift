import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What "Print…" (⌘P) sends to the system print panel (#19): the PDF and the job name, which
/// the print queue shows. `nil` for data PDFKit cannot read.
struct PrintJob {
    let data: Data
    let jobName: String
    let pdf: PDFDocument

    init?(data: Data?, jobName: String) {
        guard let data, !data.isEmpty, let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { return nil }
        self.data = data
        self.pdf = pdf
        let name = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jobName = name.isEmpty ? String(localized: "Document") : name
    }

    /// The document's print job: its PDF under its title; `nil` without a readable PDF.
    @MainActor init?(document: Document) {
        guard document.isAlive else { return nil }
        self.init(data: document.pdfData, jobName: document.title)
    }
}

/// Shows the system print panel: on macOS for the key window (scaled to the page, rotated to
/// fit), on iPhone and iPad the AirPrint sheet (a form sheet on iPad, no anchor needed).
enum DocumentPrinter {
    @MainActor static func print(_ job: PrintJob) {
        #if os(macOS)
        guard let operation = job.pdf.printOperation(for: NSPrintInfo.shared.copy() as? NSPrintInfo ?? .shared,
                                                     scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.jobTitle = job.jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        #else
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = job.jobName
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = job.data
        controller.present(animated: true)
        #endif
    }
}
