import CoreGraphics
import CoreImage
import Foundation
import Testing
import UniformTypeIdentifiers
import Vision
@testable import DocumentArchive

/// The photo cleanup pipeline (#20): page detection, perspective correction, filters and the
/// shared image loading. Generated images only; Core Image renders in software in tests, and
/// pixel checks use tolerances, so the results do not depend on the GPU.
@Suite struct ImageCleanupTests {
    static let letter = ["Stadtwerke Beispielstadt GmbH", "Rechnung Nr. 4711", "Rechnungsdatum: 03.09.2026"]

    /// The aspect ratio (width / height) `CIPerspectiveCorrection` gives a quad of a photo of
    /// `size`: the mean lengths of the opposite edges.
    static func expectedAspect(of quad: PageQuad, size: CGSize) -> Double {
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(Double((a.x - b.x) * size.width), Double((a.y - b.y) * size.height))
        }
        let width = (distance(quad.topLeft, quad.topRight) + distance(quad.bottomLeft, quad.bottomRight)) / 2
        let height = (distance(quad.topLeft, quad.bottomLeft) + distance(quad.topRight, quad.bottomRight)) / 2
        return width / height
    }

    /// Whether R, G and B agree (± 2) in every pixel of RGBA bytes.
    static func isGray(_ pixels: [UInt8]) -> Bool {
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            if abs(red - green) > 2 || abs(green - blue) > 2 { return false }
        }
        return true
    }

    static func aspect(_ image: CGImage) -> Double { Double(image.width) / Double(image.height) }

    // 1
    @Test func detectsThePageInAPhoto() async throws {
        let photo = TestSupport.photographedPage(lines: Self.letter)
        let preview = try #require(ImageCoding.orientedImage(from: TestSupport.encoded(photo),
                                                             maxPixelSize: ImageCoding.previewPixelSize))
        let found = try #require(await ImageCleanup.detectPage(in: preview, environment: .live))
        #expect(found.quad.maximumDistance(to: TestSupport.photoCorners) < 0.03, "\(found.quad)")
        #expect(found.confidence > 0)
    }

    // 2
    @Test func correctsThePerspective() async throws {
        let photo = TestSupport.photographedPage(lines: Self.letter)
        let size = CGSize(width: photo.width, height: photo.height)
        let settings = CleanupSettings(quad: TestSupport.photoCorners, confidence: 1, filter: .original)
        let corrected = try #require(ImageCleanup.apply(settings, to: photo))

        let expected = Self.expectedAspect(of: TestSupport.photoCorners, size: size)
        #expect(abs(Self.aspect(corrected) / expected - 1) < 0.03, "aspect \(Self.aspect(corrected)), expected \(expected)")
        #expect(abs(Self.aspect(corrected) - Self.aspect(photo)) > 0.05, "not just the whole photo")

        var request = RecognizeTextRequest()
        request.recognitionLanguages = [Locale.Language(identifier: "de-DE")]
        let text = try await request.perform(on: corrected).compactMap { $0.topCandidates(1).first?.string }
        #expect(text.joined(separator: " ").contains("Rechnung"), "\(text)")
    }

    // 3
    @Test func findsNoPageInUniformOrNoisyImages() async throws {
        let uniform = TestSupport.desk(width: 10, height: 10)
        let context = CGContext(data: nil, width: 900, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(uniform, in: CGRect(x: 0, y: 0, width: 900, height: 1200))
        let gray = context.makeImage()!
        #expect(await ImageCleanup.detectPage(in: gray, environment: .live) == nil)

        var generator = SeededGenerator(seed: 3)
        for _ in 0..<4000 {
            let value = Double.random(in: 0...1, using: &generator)
            context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
            context.fill(CGRect(x: Double.random(in: 0...900, using: &generator), y: Double.random(in: 0...1200, using: &generator),
                                width: 12, height: 12))
        }
        let noise = context.makeImage()!
        #expect(await ImageCleanup.detectPage(in: noise, environment: .live) == nil)

        let whole = try #require(ImageCleanup.apply(CleanupSettings(quad: nil, filter: .color), to: noise))
        #expect(whole.width == noise.width && whole.height == noise.height)
    }

    // 4
    @Test func unattendedCropsOnlyConfidentLargePages() {
        let large = TestSupport.photoCorners
        let confident = CleanupSettings(quad: large, confidence: 0.95, filter: .grayscale)
        #expect(ImageCleanup.unattendedSettings(for: confident).quad == large)
        #expect(ImageCleanup.unattendedSettings(for: confident).filter == .grayscale)

        // A receipt lying on a letter: found confidently, but only a small part of the photo.
        let receipt = PageQuad(topLeft: CGPoint(x: 0.3, y: 0.7), topRight: CGPoint(x: 0.6, y: 0.7),
                               bottomRight: CGPoint(x: 0.6, y: 0.2), bottomLeft: CGPoint(x: 0.3, y: 0.2))
        #expect(receipt.area < 0.5)
        let small = ImageCleanup.unattendedSettings(for: CleanupSettings(quad: receipt, confidence: 0.99, filter: .color))
        #expect(small.quad == nil, "whole image")
        #expect(small.filter == .color, "the filter still applies")

        let unsure = ImageCleanup.unattendedSettings(for: CleanupSettings(quad: large, confidence: 0.6, filter: .color))
        #expect(unsure.quad == nil)
        #expect(ImageCleanup.unattendedSettings(for: CleanupSettings(quad: nil)).quad == nil)
    }

    // 5
    @Test func quadOrderingClampingAndViewCoordinates() throws {
        let quad = TestSupport.photoCorners
        let shuffled = [quad.bottomRight, quad.topLeft, quad.bottomLeft, quad.topRight]
        #expect(PageQuad.ordered(shuffled) == quad)
        #expect(PageQuad.ordered(Array(shuffled.prefix(3))) == nil)

        let outside = PageQuad(topLeft: CGPoint(x: -0.1, y: 1.2), topRight: CGPoint(x: 1.1, y: 0.9),
                               bottomRight: CGPoint(x: 0.9, y: -0.3), bottomLeft: CGPoint(x: 0.1, y: 0.1))
        #expect(outside.clamped().corners.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        #expect(outside.clamped().topLeft == CGPoint(x: 0, y: 1))

        #expect(PageQuad.whole.isWholeImage())
        #expect(PageQuad.whole.area == 1)
        #expect(!quad.isWholeImage())
        let nearlyWhole = PageQuad(topLeft: CGPoint(x: 0.01, y: 0.99), topRight: CGPoint(x: 1, y: 1),
                                   bottomRight: CGPoint(x: 0.99, y: 0.005), bottomLeft: CGPoint(x: 0, y: 0))
        #expect(nearlyWhole.isWholeImage())

        // View coordinates have their origin at the top: the quad's top-left (y 0.9) is near the top.
        let size = CGSize(width: 300, height: 400)
        let viewTopLeft = QuadGeometry.viewPoint(quad.topLeft, in: size)
        #expect(abs(viewTopLeft.x - 36) < 0.001 && abs(viewTopLeft.y - 40) < 0.001)
        #expect(QuadGeometry.normalizedPoint(CGPoint(x: 0, y: 0), in: size) == CGPoint(x: 0, y: 1))
        let roundTrip = try #require(QuadGeometry.quad(fromViewCorners: QuadGeometry.viewCorners(of: quad, in: size), in: size))
        #expect(roundTrip.maximumDistance(to: quad) < 1e-9)
    }

    // 6
    @Test func filters() throws {
        let photo = TestSupport.photographedPage(lines: Self.letter, width: 600, height: 800)

        let gray = try #require(ImageCleanup.apply(CleanupSettings(filter: .grayscale), to: photo))
        let grayPixels = TestSupport.pixels(of: gray)
        #expect(Self.isGray(grayPixels))

        let blackAndWhite = try #require(ImageCleanup.apply(CleanupSettings(filter: .blackAndWhite), to: photo))
        let bwPixels = TestSupport.pixels(of: blackAndWhite)
        #expect(stride(from: 0, to: bwPixels.count, by: 4).allSatisfy { bwPixels[$0] <= 10 || bwPixels[$0] >= 245 })

        let original = try #require(ImageCleanup.apply(CleanupSettings(filter: .original), to: photo))
        let before = TestSupport.pixels(of: photo), after = TestSupport.pixels(of: original)
        #expect(original.width == photo.width && original.height == photo.height)
        #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 2 })

        let turned = try #require(ImageCleanup.apply(CleanupSettings(filter: .original, rotation: 1), to: photo))
        #expect(turned.width == photo.height && turned.height == photo.width)
    }

    @Test func otsuThresholdLiesBetweenThePeaksAndTheOffsetMovesIt() throws {
        let histogram = (0..<256).map { bin -> Double in
            let x = Double(bin)
            return 3 * exp(-pow(x - 50, 2) / 200) + 5 * exp(-pow(x - 200, 2) / 300)
        }
        let threshold = ImageCleanup.otsuThreshold(histogram)
        #expect(threshold > 60.0 / 256 && threshold < 190.0 / 256, "\(threshold)")
        #expect(ImageCleanup.otsuThreshold([]) == 0.5)
        #expect(ImageCleanup.otsuThreshold([0, 0, 0]) == 0.5)

        // "Darker" (+) turns more of a gradient black than "Lighter" (−).
        let gradient = CGContext(data: nil, width: 256, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<256 {
            let value = Double(x) / 255
            gradient.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
            gradient.fill(CGRect(x: x, y: 0, width: 1, height: 16))
        }
        let image = gradient.makeImage()!
        func blackPixels(offset: Double) throws -> Int {
            let result = try #require(ImageCleanup.apply(CleanupSettings(filter: .blackAndWhite, bwOffset: offset), to: image))
            let pixels = TestSupport.pixels(of: result)
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 128 }.count
        }
        let lighter = try blackPixels(offset: -0.2), neutral = try blackPixels(offset: 0), darker = try blackPixels(offset: 0.2)
        #expect(lighter < neutral && neutral < darker, "\(lighter) < \(neutral) < \(darker)")
    }

    // 7
    @Test func exifOrientationIsApplied() throws {
        // Stored on its side (400 × 300) with a red block in the lower-left corner; EXIF
        // orientation 6 says "turn 90° clockwise", which puts the block at the top left.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let jpeg = TestSupport.encoded(context.makeImage()!, type: .jpeg, orientation: 6)

        let upright = try #require(ImageCoding.orientedImage(from: jpeg, maxPixelSize: ImageCoding.pagePixelSize))
        #expect(upright.width == 300 && upright.height == 400)
        let pixels = TestSupport.pixels(of: upright)
        func isRed(x: Int, y: Int) -> Bool {
            let i = (y * upright.width + x) * 4
            return pixels[i] > 200 && pixels[i + 1] < 60 && pixels[i + 2] < 60
        }
        #expect(isRed(x: 20, y: 20))
        #expect(!isRed(x: 280, y: 380))
        #expect(!isRed(x: 20, y: 380))
    }

    // 8
    @Test func pendingImportKeepsOnlyPreviews() async throws {
        let photo = TestSupport.photographedPage(lines: Self.letter, width: 2400, height: 3200)
        let data = TestSupport.encoded(photo, type: .jpeg)
        let pending = try #require(await PendingImport.make(originalData: [data], title: "Foto", filter: .color, environment: .live))

        #expect(pending.originalData == [data])
        #expect(pending.hash == DocumentImporter.sha256(data))
        #expect(pending.preview.count == 1 && pending.settings.count == 1)
        #expect(pending.preview.allSatisfy { max($0.width, $0.height) <= ImageCoding.previewPixelSize })
        // No other image is kept anywhere in the value.
        let children = Mirror(reflecting: pending).children
        #expect(!children.contains { type(of: $0.value) == CGImage.self })
        // (Casts to CF types are not checked, so compare the types.)
        #expect(children.filter { type(of: $0.value) == [CGImage].self }.map(\.label) == ["preview"])
        #expect(pending.settings[0].quad != nil, "detected on the preview")
        #expect(pending.settings[0].filter == .color)

        #expect(await PendingImport.make(originalData: [Data("no image".utf8)], title: "x", filter: .color, environment: .live) == nil)
    }
}
