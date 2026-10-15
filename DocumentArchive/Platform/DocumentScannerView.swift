#if os(iOS)
import SwiftUI
import VisionKit

/// Der Dokumentenscanner von iOS: erkennt Seitenränder automatisch, korrigiert die Perspektive
/// und erlaubt mehrere Seiten pro Scan.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([CGImage]) -> Void
    var onCancel: () -> Void

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
            let images = (0..<scan.pageCount).compactMap { index -> CGImage? in
                let image = scan.imageOfPage(at: index)
                return image.cgImage ?? normalized(image).cgImage
            }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("Scan fehlgeschlagen: \(error)")
            parent.onCancel()
        }

        private func normalized(_ image: UIImage) -> UIImage {
            UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
        }
    }
}
#endif
