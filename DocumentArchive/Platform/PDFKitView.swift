import PDFKit
import SwiftUI

/// PDF viewer for iOS and macOS.
struct PDFKitView: View {
    let data: Data
    let id: UUID

    var body: some View {
        Representable(data: data, id: id)
    }
}

#if os(macOS)
private struct Representable: NSViewRepresentable {
    let data: Data
    let id: UUID

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
private struct Representable: UIViewRepresentable {
    let data: Data
    let id: UUID

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

private final class Coordinator {
    var shownID: UUID?
    var shownSize: Int = -1
}

extension Representable {
    fileprivate func configure(_ view: PDFView) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        #if os(iOS)
        view.backgroundColor = .secondarySystemBackground
        #endif
    }

    fileprivate func update(_ view: PDFView, coordinator: Coordinator) {
        // Only reload when the document actually changed
        guard coordinator.shownID != id || coordinator.shownSize != data.count else { return }
        coordinator.shownID = id
        coordinator.shownSize = data.count
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
}
