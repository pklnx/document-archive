import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds a compact PDF from images (camera scan, photos, image files).
/// The images are scaled down and embedded as JPEG, so the files stay small
/// and sync quickly through iCloud.
enum PDFBuilder {
    /// Page width in PDF points (A4 width). The height follows from the aspect ratio.
    private static let pageWidth: CGFloat = 595
    private static let maxPixelSize: Int = 2400
    private static let jpegQuality: CGFloat = 0.72

    static func makePDF(from images: [CGImage]) -> Data? {
        makePDF(pageCount: images.count) { images[$0] }
    }

    /// Builds the PDF one page at a time: `page(i)` is asked for each page just before it is
    /// drawn, so only one full-size image is in memory at once (photo cleanup decodes and
    /// processes each page in there). Pages for which `page` returns `nil` are left out.
    static func makePDF(pageCount: Int, page: (Int) -> CGImage?) -> Data? {
        guard pageCount > 0 else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 1.414)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var pagesDrawn = 0
        for index in 0..<pageCount {
            autoreleasepool {
                guard let original = page(index) else { return }
                let image = compressed(original) ?? original
                let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
                var pageBox = CGRect(x: 0, y: 0, width: pageWidth, height: (pageWidth * aspect).rounded())
                let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(image, in: pageBox)
                context.endPDFPage()
                pagesDrawn += 1
            }
        }
        context.closePDF()
        return pagesDrawn > 0 ? output as Data : nil
    }

    static func makePDF(fromImageFiles urls: [URL]) -> Data? {
        let images = urls.compactMap { url -> CGImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageCoding.orientedImage(from: data, maxPixelSize: maxPixelSize)
        }
        return makePDF(from: images)
    }

    static func makePDF(fromImageData items: [Data]) -> Data? {
        let images = items.compactMap { ImageCoding.orientedImage(from: $0, maxPixelSize: maxPixelSize) }
        return makePDF(from: images)
    }

    /// Scales an image down and compresses it as JPEG. Quartz copies JPEG data into the PDF
    /// when drawing, instead of embedding it uncompressed.
    private static func compressed(_ image: CGImage) -> CGImage? {
        guard let jpeg = ImageCoding.jpegData(from: image, maxPixelSize: maxPixelSize, quality: jpegQuality),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Shared image loading and encoding for the importer, the photo cleanup and `PDFBuilder`.
enum ImageCoding {
    /// Size of the previews the photo cleanup detects the page on (and #20 part 2 shows).
    static let previewPixelSize = 1200
    /// Size a page is decoded at before cleanup; `PDFBuilder` then scales it to 2400 px.
    static let pagePixelSize = 3000

    /// Decodes the first image in `data` with its EXIF orientation applied (important for phone
    /// photos), scaled down so its longer side is at most `maxPixelSize`. Smaller images keep
    /// their size.
    static func orientedImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

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
