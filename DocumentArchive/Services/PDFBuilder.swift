import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Erzeugt aus Bildern (Kamera-Scan, Fotos, Bilddateien) ein kompaktes PDF.
/// Die Bilder werden verkleinert und als JPEG eingebettet, damit die Dateien klein bleiben
/// und schnell über iCloud synchronisiert werden.
enum PDFBuilder {
    /// Breite einer Seite in PDF-Punkten (A4-Breite). Die Höhe ergibt sich aus dem Seitenverhältnis.
    private static let pageWidth: CGFloat = 595
    private static let maxPixelSize: Int = 2400
    private static let jpegQuality: CGFloat = 0.72

    static func makePDF(from images: [CGImage]) -> Data? {
        guard !images.isEmpty else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 1.414)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for original in images {
            let image = compressed(original) ?? original
            let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
            var pageBox = CGRect(x: 0, y: 0, width: pageWidth, height: (pageWidth * aspect).rounded())
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.interpolationQuality = .high
            context.draw(image, in: pageBox)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    static func makePDF(fromImageFiles urls: [URL]) -> Data? {
        let images = urls.compactMap { url -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return orientedImage(from: source)
        }
        return makePDF(from: images)
    }

    static func makePDF(fromImageData items: [Data]) -> Data? {
        let images = items.compactMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return orientedImage(from: source)
        }
        return makePDF(from: images)
    }

    /// Lädt ein Bild mit korrekt angewendeter EXIF-Ausrichtung (wichtig für Handyfotos).
    private static func orientedImage(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Verkleinert und JPEG-komprimiert ein Bild. Quartz übernimmt JPEG-Daten beim Zeichnen
    /// direkt in das PDF, statt sie unkomprimiert einzubetten.
    private static func compressed(_ image: CGImage) -> CGImage? {
        guard let jpeg = ImageCoding.jpegData(from: image, maxPixelSize: maxPixelSize, quality: jpegQuality),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

enum ImageCoding {
    static func jpegData(from image: CGImage, maxPixelSize: Int? = nil, quality: CGFloat) -> Data? {
        var image = image
        if let maxPixelSize, max(image.width, image.height) > maxPixelSize {
            image = scaled(image, maxPixelSize: maxPixelSize) ?? image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let scale = CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height))
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
