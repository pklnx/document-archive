import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import Vision

/// The four corners of a page in a photo, **normalized** (0…1) with the origin in the
/// **lower-left** corner, the convention of Vision and Core Image. SwiftUI views use an upper-left
/// origin; `QuadGeometry` is the one place that converts between the two.
struct PageQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// The whole image.
    static let whole = PageQuad(topLeft: CGPoint(x: 0, y: 1), topRight: CGPoint(x: 1, y: 1),
                                bottomRight: CGPoint(x: 1, y: 0), bottomLeft: CGPoint(x: 0, y: 0))

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Four points in any order as a quad: sorted around their center, the corner nearest to the
    /// upper-left of the image becomes `topLeft`. `nil` unless there are exactly four points.
    static func ordered(_ points: [CGPoint]) -> PageQuad? {
        guard points.count == 4 else { return nil }
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        // Clockwise as seen on screen (y up): descending angle.
        let clockwise = points.sorted {
            atan2($0.y - center.y, $0.x - center.x) > atan2($1.y - center.y, $1.x - center.x)
        }
        // Upper-left: smallest x − y (left and high up).
        let start = clockwise.indices.min { clockwise[$0].x - clockwise[$0].y < clockwise[$1].x - clockwise[$1].y } ?? 0
        let p = (0..<4).map { clockwise[(start + $0) % 4] }
        return PageQuad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
    }

    /// Every corner moved into the image (0…1).
    func clamped() -> PageQuad {
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        return PageQuad(topLeft: clamp(topLeft), topRight: clamp(topRight),
                        bottomRight: clamp(bottomRight), bottomLeft: clamp(bottomLeft))
    }

    /// The share of the image the quad covers (shoelace formula), 0…1.
    var area: Double {
        let points = corners
        var sum: Double = 0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    /// Whether every corner lies within `tolerance` of the image's own corner.
    func isWholeImage(tolerance: CGFloat = 0.02) -> Bool {
        zip(corners, Self.whole.corners).allSatisfy { abs($0.x - $1.x) <= tolerance && abs($0.y - $1.y) <= tolerance }
    }

    /// The largest distance of a corner from the matching corner of `other`, in normalized units.
    func maximumDistance(to other: PageQuad) -> CGFloat {
        zip(corners, other.corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
    }
}

/// Converts between `PageQuad`'s normalized lower-left coordinates and the upper-left points of
/// a view (or image) of a given size. The only place with the y flip.
enum QuadGeometry {
    static func viewPoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: (1 - normalized.y) * size.height)
    }

    static func normalizedPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x / max(size.width, 1), y: 1 - point.y / max(size.height, 1))
    }

    /// The corners in view coordinates, in the order top-left, top-right, bottom-right, bottom-left.
    static func viewCorners(of quad: PageQuad, in size: CGSize) -> [CGPoint] {
        quad.corners.map { viewPoint($0, in: size) }
    }

    static func quad(fromViewCorners points: [CGPoint], in size: CGSize) -> PageQuad? {
        guard points.count == 4 else { return nil }
        let normalized = points.map { normalizedPoint($0, in: size) }
        return PageQuad(topLeft: normalized[0], topRight: normalized[1],
                        bottomRight: normalized[2], bottomLeft: normalized[3])
    }
}

/// How a cleaned page is colored.
enum PageFilter: String, CaseIterable, Sendable, Identifiable {
    case original
    case color
    case grayscale
    case blackAndWhite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: String(localized: "Original")
        case .color: String(localized: "Color")
        case .grayscale: String(localized: "Grayscale")
        case .blackAndWhite: String(localized: "Black & White")
        }
    }
}

/// What the cleanup does with one page.
struct CleanupSettings: Equatable, Sendable {
    /// The page's corners; `nil` uses the whole image.
    var quad: PageQuad?
    /// How sure the detection was (0…1); 0 when nothing was detected.
    var confidence: Float = 0
    var filter: PageFilter = .color
    /// Shifts the black-and-white threshold (−0.2 lighter … +0.2 darker).
    var bwOffset: Double = 0
    /// Clockwise quarter turns (0…3).
    var rotation: Int = 0
}

/// Straightens and cleans up photographed pages: finds the page (Vision), corrects the
/// perspective and applies a filter (Core Image). Pure functions, no UI; everything runs on the
/// device.
enum ImageCleanup {
    /// Below this confidence, or when the page covers less than `minimumUnattendedArea` of the
    /// photo, a crop nobody looked at is not applied (an inner table, a receipt on a letter).
    static let minimumUnattendedConfidence: Float = 0.8
    static let minimumUnattendedArea = 0.5

    // MARK: Core Image context

    /// A Core Image context. Software rendering for tests and devices without Metal (CI runners
    /// are VMs with limited GPU access), so results do not depend on the GPU.
    static func makeContext(softwareRendering: Bool) -> CIContext {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ]
        if softwareRendering { options[.useSoftwareRenderer] = true }
        return CIContext(options: options)
    }

    /// The one context the app uses; `CIContext` is thread-safe.
    static let sharedContext: CIContext = makeContext(
        softwareRendering: TestEnvironment.isRunningTests || MTLCreateSystemDefaultDevice() == nil
    )

    // MARK: Detection

    /// Finds the page in a photo (best on a preview of about 1200 px; the quad is normalized).
    /// Uses document segmentation and falls back to rectangle detection when it finds nothing
    /// **or throws** (it can on machines without a Neural Engine or GPU). Each request waits for
    /// `VisionGate`, like text recognition (#60).
    /// - Parameter environment: The caller's environment (`visionHook`). No default: this runs
    ///   detached, where `ProcessingEnvironment.current` is `.live`.
    /// - Returns: `nil` when nothing was found or the page is (almost) the whole image.
    static func detectPage(in image: CGImage,
                           environment: ProcessingEnvironment) async -> (quad: PageQuad, confidence: Float)? {
        var found: (quad: PageQuad, confidence: Float)?
        if usesDocumentSegmentation,
           let document = try? await VisionGate.run(.detectDocumentSegmentation, environment: environment, {
               try await DetectDocumentSegmentationRequest().perform(on: image)
           }),
           let quad = PageQuad.ordered([document.topLeft, document.topRight, document.bottomRight, document.bottomLeft]
                                       .map(\.cgPoint)) {
            found = (quad.clamped(), document.confidence)
        }
        if found == nil {
            var request = DetectRectanglesRequest()
            request.minimumAspectRatio = 0.3
            request.maximumAspectRatio = 1
            request.minimumSize = 0.2
            request.minimumConfidence = 0.6
            request.quadratureToleranceDegrees = 30
            request.maximumObservations = 1
            if let rectangle = try? await VisionGate.run(.detectRectangles, environment: environment, {
                   try await request.perform(on: image).first
               }),
               let quad = PageQuad.ordered([rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
                                           .map(\.cgPoint)) {
                found = (quad.clamped(), rectangle.confidence)
            }
        }
        guard let found, found.quad.area > 0.01, !found.quad.isWholeImage() else { return nil }
        return found
    }

    /// The iOS simulator has no Neural Engine, and its document segmentation returns arbitrary
    /// quads with high confidence (a strip along the bottom of a plain surface), so it uses
    /// rectangle detection only. Devices and Macs use both.
    static var usesDocumentSegmentation: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// The settings for a page nobody looks at (Automatic mode): the detected quad only when the
    /// detection is confident **and** the quad covers at least half of the photo; otherwise the
    /// whole image with only the filter.
    static func unattendedSettings(for detected: CleanupSettings) -> CleanupSettings {
        var settings = detected
        guard let quad = detected.quad,
              detected.confidence >= minimumUnattendedConfidence,
              quad.area >= minimumUnattendedArea
        else {
            settings.quad = nil
            return settings
        }
        settings.quad = quad
        return settings
    }

    // MARK: Applying

    /// Applies perspective correction, rotation and the filter to a page.
    static func apply(_ settings: CleanupSettings, to image: CGImage, context: CIContext = sharedContext) -> CGImage? {
        var output = CIImage(cgImage: image)
        let width = CGFloat(image.width), height = CGFloat(image.height)

        if let quad = settings.quad?.clamped(), !quad.isWholeImage(tolerance: 0.001) {
            func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * width, y: point.y * height) }
            let correction = CIFilter.perspectiveCorrection()
            correction.inputImage = output
            correction.topLeft = pixel(quad.topLeft)
            correction.topRight = pixel(quad.topRight)
            correction.bottomRight = pixel(quad.bottomRight)
            correction.bottomLeft = pixel(quad.bottomLeft)
            correction.crop = true
            if let corrected = correction.outputImage { output = corrected }
        }

        switch ((settings.rotation % 4) + 4) % 4 {
        case 1: output = output.oriented(.right)
        case 2: output = output.oriented(.down)
        case 3: output = output.oriented(.left)
        default: break
        }
        output = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))

        output = filtered(output, settings.filter, bwOffset: settings.bwOffset, context: context)
        let extent = output.extent.integral
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func filtered(_ image: CIImage, _ filter: PageFilter, bwOffset: Double, context: CIContext) -> CIImage {
        switch filter {
        case .original:
            return image
        case .color:
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = image
            enhancer.amount = 1
            if let enhanced = enhancer.outputImage?.cropped(to: image.extent) { return enhanced }
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = 1.15
            controls.saturation = 1.05
            return controls.outputImage ?? image
        case .grayscale:
            return grayscale(image, contrast: 1.1)
        case .blackAndWhite:
            let gray = grayscale(image, contrast: 1)
            let histogram = luminanceHistogram(of: gray, context: context)
            let threshold = min(max(otsuThreshold(histogram) + bwOffset, 0.02), 0.98)
            let thresholdFilter = CIFilter.colorThreshold()
            thresholdFilter.inputImage = gray
            thresholdFilter.threshold = Float(threshold)
            return thresholdFilter.outputImage?.cropped(to: image.extent) ?? gray
        }
    }

    private static func grayscale(_ image: CIImage, contrast: Float) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 0
        controls.contrast = contrast
        return controls.outputImage ?? image
    }

    // MARK: Black and white threshold

    static let histogramBins = 256

    /// The share of pixels per luminance bin (0…1 in `histogramBins` steps), from `CIAreaHistogram`.
    static func luminanceHistogram(of image: CIImage, context: CIContext) -> [Double] {
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = image.extent
        filter.count = histogramBins
        filter.scale = 1
        guard let output = filter.outputImage else { return [] }
        var bins = [Float](repeating: 0, count: histogramBins * 4)
        bins.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: histogramBins * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: histogramBins, height: 1), format: .RGBAf, colorSpace: nil)
        }
        // Gray image: R, G and B agree; use green.
        return (0..<histogramBins).map { Double(bins[$0 * 4 + 1]) }
    }

    /// Otsu's threshold of a histogram (any scale): the value 0…1 between the bins that best
    /// separates dark (text) from light (paper). 0.5 for an empty or flat-zero histogram.
    static func otsuThreshold(_ histogram: [Double]) -> Double {
        let total = histogram.reduce(0, +)
        guard histogram.count > 1, total > 0 else { return 0.5 }
        let sumAll = histogram.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
        var weightBackground = 0.0, sumBackground = 0.0
        var bestVariance = -1.0, bestIndex = 0
        for (index, count) in histogram.enumerated() {
            weightBackground += count
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }
            sumBackground += Double(index) * count
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sumAll - sumBackground) / weightForeground
            let variance = weightBackground * weightForeground * pow(meanBackground - meanForeground, 2)
            if variance > bestVariance {
                bestVariance = variance
                bestIndex = index
            }
        }
        // The boundary after the best bin.
        return (Double(bestIndex) + 1) / Double(histogram.count)
    }
}
