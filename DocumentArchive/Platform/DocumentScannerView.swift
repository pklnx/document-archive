#if os(iOS)
import SwiftUI
import VisionKit

/// The iOS document scanner: detects page edges, corrects the perspective
/// and allows several pages per scan.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: (any ScannedPages) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onFinish(scan)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
        }
    }
}

extension VNDocumentCameraScan: ScannedPages {
    func image(at index: Int) -> CGImage? {
        let image = imageOfPage(at: index)
        if let cgImage = image.cgImage { return cgImage }
        // Some pages come without a CGImage backing; redraw them into one.
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.cgImage
    }
}
#endif
