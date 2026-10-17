import CoreGraphics
import CoreText
import Foundation
import os
import PDFKit
import Vision

/// A word recognized on a page, with its box in the coordinates of the page *as displayed*:
/// upright (rotation applied), in points, origin bottom-left of the crop box.
struct RecognizedWord: Sendable, Equatable {
    var text: String
    var box: CGRect
    /// Another word follows on the same line. A space is written after the word, so copied and
    /// extracted text keeps the spaces between words.
    var spaceAfter = false
}

/// What Vision read on one page: the lines (for the document's text) and their words with
/// positions (for the text layer).
struct RecognizedPage: Sendable {
    var lines: [String] = []
    var words: [RecognizedWord] = []

    var text: String { lines.joined(separator: "\n") }
}

/// Makes scanned and image-only PDFs searchable: the words Apple Vision recognizes are written
/// into the PDF as invisible text, each word at its position on the page, so the text can be
/// selected, copied and found in other apps (Preview, Finder, Files).
///
/// Every rewritten page is written in its displayed geometry (crop box, rotation baked into the
/// content), and the result is only used when `verify` confirms it looks like the original.
enum TextLayer {
    // MARK: Setting

    /// `UserDefaults` key of the per-device setting "Add a text layer to scans" (default on).
    static let enabledKey = "addTextLayer"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Changes a rewritten PDF before it is verified; see `ProcessingEnvironment.rewriteHook`.
    typealias RewriteHook = @Sendable (_ analyzed: Data, _ rewritten: Data) -> Data

    // MARK: Which pages and PDFs

    /// A page needs a layer when it has (almost) no embedded text.
    static func pageNeedsLayer(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 15
    }

    /// Indexes of the pages without embedded text.
    static func pagesNeedingLayer(in pdf: PDFDocument) -> [Int] {
        (0..<pdf.pageCount).filter { pdf.page(at: $0).map(pageNeedsLayer) ?? false }
    }

    /// Whether the PDF may be rewritten with a text layer at all.
    ///
    /// Scans and photos are PDFs the app built itself, so they always qualify. A PDF imported
    /// from elsewhere (`.file`) qualifies only when **every** page is image-only (mixed PDFs are
    /// skipped) and nothing that a rewrite could lose or change is in it: encryption, signatures,
    /// a declared conformance (PDF/A, PDF/X, …), embedded files, annotations, form fields, an
    /// outline, or images in formats Quartz may re-encode (CCITT, JBIG2, JPEG 2000). Anything
    /// that cannot be read counts as "does not qualify".
    static func qualifies(_ pdf: PDFDocument, source: DocumentSource) -> Bool {
        guard pdf.pageCount > 0, !pdf.isEncrypted, !pdf.isLocked else { return false }
        switch source {
        case .scan, .image:
            return true
        case .file:
            guard pagesNeedingLayer(in: pdf).count == pdf.pageCount,
                  pdf.outlineRoot == nil,
                  let document = pdf.documentRef, let catalog = document.catalog,
                  !catalogHasSkippedContent(catalog)
            else { return false }
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index), page.annotations.isEmpty,
                      let pageRef = document.page(at: index + 1), let pageDictionary = pageRef.dictionary,
                      !has(pageDictionary, "Annots"),
                      let resources = resources(of: pageDictionary),
                      !resourcesAreRisky(resources, depth: 0)
                else { return false }
            }
            return true
        }
    }

    /// Conformance declarations in XMP metadata that a rewrite would no longer meet.
    /// (`pdfx:` alone is not one: Adobe's custom-properties namespace uses that prefix too.)
    private static let conformanceMarkers = ["pdfaid", "pdfxid", "gts_pdfxversion", "pdfuaid", "pdfeid", "pdfvtid"]

    /// Image filters Quartz may decode and re-encode (growing the file or changing the image).
    private static let riskyFilters: Set<String> = ["CCITTFaxDecode", "CCF", "JBIG2Decode", "JPXDecode"]

    private static func catalogHasSkippedContent(_ catalog: CGPDFDictionaryRef) -> Bool {
        // Forms and signature fields (/AcroForm, /SigFlags), signature permissions, an outline
        if has(catalog, "AcroForm") || has(catalog, "Perms") || has(catalog, "Outlines") { return true }
        // Structure (tagged PDF), optional content and page labels: a rewrite would drop them.
        if has(catalog, "StructTreeRoot") || has(catalog, "OCProperties") || has(catalog, "PageLabels") { return true }
        // Embedded files
        if let names = dictionary(catalog, "Names"), has(names, "EmbeddedFiles") { return true }
        // XMP metadata declaring a conformance
        if has(catalog, "Metadata") {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return true }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return true }
            let xmp = String(decoding: data, as: UTF8.self).lowercased()
            if conformanceMarkers.contains(where: xmp.contains) { return true }
        }
        return false
    }

    /// The page's resources, inherited from the page tree when the page has none of its own.
    private static func resources(of page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page
        var depth = 0
        while let current = node, depth < 32 {
            if let resources = dictionary(current, "Resources") { return resources }
            node = dictionary(current, "Parent")
            depth += 1
        }
        return nil
    }

    /// `true` when an image (also inside nested Form XObjects) uses a filter Quartz may
    /// re-encode, or when the resources cannot be read (fail closed).
    private static func resourcesAreRisky(_ resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < 8 else { return true }
        guard has(resources, "XObject") else { return false }
        guard let xObjects = dictionary(resources, "XObject") else { return true }
        var risky = false
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream),
                  !xObjectIsRisky(streamDictionary, depth: depth)
            else {
                risky = true
                return false
            }
            return true
        }, nil)
        return risky
    }

    private static func xObjectIsRisky(_ xObject: CGPDFDictionaryRef, depth: Int) -> Bool {
        switch name(xObject, "Subtype") {
        case "Image":
            if filtersAreRisky(xObject) { return true }
            if has(xObject, "SMask") {
                var mask: CGPDFStreamRef?
                guard CGPDFDictionaryGetStream(xObject, "SMask", &mask), let mask,
                      let maskDictionary = CGPDFStreamGetDictionary(mask)
                else { return true }
                return filtersAreRisky(maskDictionary)
            }
            return false
        case "Form":
            guard has(xObject, "Resources") else { return false }
            guard let resources = dictionary(xObject, "Resources") else { return true }
            return resourcesAreRisky(resources, depth: depth + 1)
        default:
            return true
        }
    }

    private static func filtersAreRisky(_ stream: CGPDFDictionaryRef) -> Bool {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(stream, "Filter", &object), let object else { return false }
        var filterName: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &filterName), let filterName {
            return riskyFilters.contains(String(cString: filterName))
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array else { return true }
        for index in 0..<CGPDFArrayGetCount(array) {
            var element: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, index, &element), let element,
                  !riskyFilters.contains(String(cString: element))
            else { return true }
        }
        return false
    }

    private static func has(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    private static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    // MARK: Recognition

    /// Renders the page upright (rotation and crop box applied) and reads it with Vision.
    /// Each line is split into words with their own boxes, so a single word in the middle of a
    /// line can be selected.
    static func recognize(_ page: PDFPage) async -> RecognizedPage {
        let size = displayedSize(of: page)
        guard let image = DocumentProcessor.render(page, maxPixelSize: 2600) else { return RecognizedPage() }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image)
        } catch {
            Log.ocr.error("Text recognition failed: \(Log.code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return RecognizedPage()
        }
        var result = RecognizedPage()
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            result.lines.append(candidate.string)
            result.words += words(in: candidate, pageSize: size)
        }
        return result
    }

    /// The words of one recognized line with their boxes in page points.
    static func words(in candidate: RecognizedText, pageSize: CGSize) -> [RecognizedWord] {
        let string = candidate.string
        var words: [RecognizedWord] = []
        var index = string.startIndex
        while index < string.endIndex {
            guard let start = string[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
            if let box = candidate.boundingBox(for: start..<end)?.boundingBox {
                let rect = box.toImageCoordinates(pageSize, origin: .lowerLeft)
                words.append(RecognizedWord(text: String(string[start..<end]), box: rect))
            }
            index = end
        }
        for position in words.indices.dropLast() { words[position].spaceAfter = true }
        return words
    }

    /// The size of the page as it is shown: crop box, width and height swapped for 90° and 270°.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        return page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    // MARK: Writing

    /// The creator written into rewritten PDFs; for information only, the decision whether a page
    /// needs a layer is always based on its text.
    static let creator = "Document Archive OCR"

    /// Writes a new PDF: every page in its displayed geometry with the original content, plus the
    /// given words as invisible text (pages without words are copied as they are).
    /// - Parameter words: Recognized words per page index (0-based).
    /// - Returns: `nil` when the PDF cannot be read or written.
    static func addingTextLayer(to pdfData: Data, words: [Int: [RecognizedWord]]) -> Data? {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0,
              !document.isEncrypted
        else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var defaultBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox,
                                      auxiliaryInfo(of: pdfData) as CFDictionary)
        else { return nil }

        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { return nil }
            let crop = page.getBoxRect(.cropBox)
            let rotated = (page.rotationAngle % 360 + 360) % 180 != 0
            var mediaBox = CGRect(origin: .zero, size: rotated ? CGSize(width: crop.height, height: crop.width) : crop.size)
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            context.saveGState()
            context.concatenate(page.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
            context.clip(to: crop)
            context.drawPDFPage(page)
            context.restoreGState()

            if let pageWords = words[number - 1], !pageWords.isEmpty {
                context.saveGState()
                context.setTextDrawingMode(.invisible)
                for word in pageWords { draw(word, in: context) }
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Draws one word so that its glyph run covers the word's box: the font size follows the
    /// box height, a horizontal scale in the text matrix (`Tm`) makes the run as wide as the box.
    ///
    /// The glyphs are placed at the font's own advance widths, so Quartz writes the word as one
    /// show operation without character spacing (`Tc`) or per-glyph adjustments. Core Text's
    /// size-dependent tracking would add those, and older PDFKit versions (macOS 26) then read
    /// gaps *inside* words as spaces ("G rü ß e"). Quartz embeds a subset of the font with a
    /// `ToUnicode` map, so copied text (umlauts included) pastes correctly.
    private static func draw(_ word: RecognizedWord, in context: CGContext) {
        let box = word.box
        let text = word.text.precomposedStringWithCanonicalMapping
        guard !text.isEmpty, box.width > 0.5, box.height > 0.5 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, box.height, nil)
        let descent = CTFontGetDescent(font)
        let ascent = CTFontGetAscent(font)
        // Center the font's ascent + descent vertically in the box.
        let baseline = box.minY + descent + (box.height - ascent - descent) / 2
        // The space (if any) is drawn after the box, into the gap before the next word.
        let run = word.spaceAfter ? text + " " : text
        guard let glyphRun = GlyphRun(run, font: font, wordLength: text.utf16.count) else {
            // Characters Helvetica does not have: Core Text picks a fallback font.
            drawWithCoreText(run, word: text, font: font, box: box, baseline: baseline, in: context)
            return
        }
        context.setFont(glyphRun.font)
        context.setFontSize(box.height)
        context.textMatrix = CGAffineTransform(scaleX: box.width / glyphRun.wordWidth, y: 1)
        context.textPosition = CGPoint(x: box.minX, y: baseline)
        context.showGlyphs(glyphRun.glyphs, at: glyphRun.positions)
    }

    /// The glyphs of a word in one font, placed at the font's advance widths (text space).
    private struct GlyphRun {
        let font: CGFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        /// Width of the word without a trailing space, in text space.
        let wordWidth: CGFloat

        /// `nil` when the font lacks a glyph for one of the characters.
        init?(_ text: String, font ctFont: CTFont, wordLength: Int) {
            let characters = Array(text.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count),
                  !glyphs.contains(0)
            else { return nil }
            let font = CTFontCopyGraphicsFont(ctFont, nil)
            var advances = [Int32](repeating: 0, count: glyphs.count)
            guard font.getGlyphAdvances(glyphs: glyphs, count: glyphs.count, advances: &advances) else { return nil }
            let scale = CTFontGetSize(ctFont) / CGFloat(max(font.unitsPerEm, 1))
            var x: CGFloat = 0
            var positions: [CGPoint] = []
            var wordWidth: CGFloat = 0
            for (index, advance) in advances.enumerated() {
                positions.append(CGPoint(x: x, y: 0))
                x += CGFloat(advance) * scale
                if index == wordLength - 1 { wordWidth = x }
            }
            guard wordWidth > 0 else { return nil }
            self.font = font
            self.glyphs = glyphs
            self.positions = positions
            self.wordWidth = wordWidth
        }
    }

    private static func drawWithCoreText(_ run: String, word: String, font: CTFont, box: CGRect, baseline: CGFloat,
                                         in context: CGContext) {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let width = CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attributes)), nil, nil, nil)
        guard width > 0 else { return }
        context.textMatrix = CGAffineTransform(scaleX: box.width / width, y: 1)
        context.textPosition = CGPoint(x: box.minX, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: run, attributes: attributes)), context)
    }

    /// Title, author, subject and keywords of the original, plus the creator marker.
    private static func auxiliaryInfo(of pdfData: Data) -> [String: Any] {
        var info: [String: Any] = [kCGPDFContextCreator as String: creator]
        guard let attributes = PDFDocument(data: pdfData)?.documentAttributes else { return info }
        let keys: [(PDFDocumentAttribute, CFString)] = [
            (.titleAttribute, kCGPDFContextTitle), (.authorAttribute, kCGPDFContextAuthor),
            (.subjectAttribute, kCGPDFContextSubject),
        ]
        for (attribute, key) in keys {
            if let value = attributes[attribute] as? String, !value.isEmpty { info[key as String] = value }
        }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] {
            let joined = (keywords as? [String])?.joined(separator: ", ") ?? (keywords as? String) ?? ""
            if !joined.isEmpty { info[kCGPDFContextKeywords as String] = joined }
        }
        return info
    }

    // MARK: Verification

    /// The largest mean difference per color channel (0–255) over a whole page before and after
    /// the rewrite. The invisible text adds nothing visible, so real rewrites stay far below.
    static let maxMeanPixelDifference = 2.5
    /// The largest mean difference within one tile of a `tileGrid` × `tileGrid` grid, so a local
    /// change (a lost stamp or signature on a few percent of the page) fails the check although
    /// the page as a whole barely changes.
    static let maxTilePixelDifference = 12.0
    static let tileGrid = 16

    /// The outcome of the check before a rewrite replaces the stored PDF.
    enum Verification: Equatable {
        case passed
        /// More than 10 % + 20 KB larger than the original.
        case tooLarge
        /// The rewritten PDF (or the original) cannot be opened or rendered.
        case unreadable
        case pageCountChanged
        /// A page looks different (whole page or one tile beyond the tolerance).
        case looksDifferent
    }

    /// Checked before a rewrite replaces the stored PDF: it opens, has the same page count, every
    /// page looks the same (rendered at 480 px, as a whole and per tile) and it is at most
    /// 10 % + 20 KB larger.
    static func check(original: Data, rewritten: Data) -> Verification {
        guard rewritten.count <= maxRewrittenSize(for: original.count) else { return .tooLarge }
        guard let before = PDFDocument(data: original), let after = PDFDocument(data: rewritten),
              before.pageCount > 0
        else { return .unreadable }
        guard before.pageCount == after.pageCount else { return .pageCountChanged }
        for index in 0..<before.pageCount {
            guard let old = before.page(at: index), let new = after.page(at: index),
                  let difference = pixelDifference(old, new)
            else { return .looksDifferent }
            if difference.mean > maxMeanPixelDifference || difference.maxTile > maxTilePixelDifference {
                return .looksDifferent
            }
        }
        return .passed
    }

    static func verify(original: Data, rewritten: Data) -> Bool {
        check(original: original, rewritten: rewritten) == .passed
    }

    static func maxRewrittenSize(for originalSize: Int) -> Int {
        originalSize + originalSize / 10 + 20_000
    }

    /// Mean difference per color channel between two pages rendered at `size` pixels, over the
    /// whole page and the largest over the tiles of a `tileGrid` grid; `nil` when they cannot be
    /// rendered or have different dimensions.
    static func pixelDifference(_ first: PDFPage, _ second: PDFPage,
                                size: CGFloat = 480) -> (mean: Double, maxTile: Double)? {
        guard let a = DocumentProcessor.render(first, maxPixelSize: size),
              let b = DocumentProcessor.render(second, maxPixelSize: size),
              a.width == b.width, a.height == b.height, a.width > 0, a.height > 0,
              let pixelsA = rgbaPixels(a), let pixelsB = rgbaPixels(b)
        else { return nil }
        let width = a.width, height = a.height
        let columns = min(tileGrid, width), rows = min(tileGrid, height)
        var tileTotals = [Int](repeating: 0, count: columns * rows)
        var tileCounts = [Int](repeating: 0, count: columns * rows)
        var total = 0
        for y in 0..<height {
            let row = y * rows / height
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let difference = abs(Int(pixelsA[offset]) - Int(pixelsB[offset]))
                    + abs(Int(pixelsA[offset + 1]) - Int(pixelsB[offset + 1]))
                    + abs(Int(pixelsA[offset + 2]) - Int(pixelsB[offset + 2]))
                total += difference
                let tile = row * columns + x * columns / width
                tileTotals[tile] += difference
                tileCounts[tile] += 3
            }
        }
        let maxTile = zip(tileTotals, tileCounts).map { $1 > 0 ? Double($0) / Double($1) : 0 }.max() ?? 0
        return (Double(total) / Double(width * height * 3), maxTile)
    }

    private static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}
