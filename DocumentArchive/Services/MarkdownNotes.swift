import Foundation

/// Markdown in notes and in Mistral's OCR text (#19): the blocks `NotesView` renders and the
/// conversion to plain text for "Copy Text". Notes stay a plain `String` in the model; older app
/// versions show the Markdown source.
enum MarkdownNotes {
    /// One rendered piece of a note. `text` holds the inline formatting (emphasis, code, links).
    struct Block: Equatable {
        enum Kind: Equatable {
            /// `#` to `###`; deeper headings are shown as level 3.
            case heading(level: Int)
            /// Consecutive lines, kept as separate lines.
            case paragraph
            /// List items; `level` is the indentation (two spaces or one tab per level).
            case bullet(level: Int)
            case numbered(marker: String, level: Int)
            /// `- [ ]` / `- [x]`, read-only (maintainer decision).
            case task(isChecked: Bool, level: Int)
            /// Consecutive `>` lines.
            case quote
            /// The lines between two fences, verbatim and without formatting or links.
            case code
            /// `---`, `***`, `___`.
            case rule
        }

        var kind: Kind
        var text: AttributedString
    }

    /// The only URL schemes that become links; anything else (`file:`, `javascript:`, other
    /// apps' schemes) stays text.
    static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    // MARK: Blocks

    /// The blocks of a note. Never fails: text that cannot be parsed is shown as it is.
    static func blocks(from markdown: String) -> [Block] {
        var builder = BlockBuilder()
        for rawLine in lines(of: markdown) {
            builder.add(rawLine)
        }
        return builder.finish()
    }

    /// Collects lines into blocks: paragraphs and quotes until a blank line or another block,
    /// everything between fences as code.
    private struct BlockBuilder {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String] = []
        /// The open fence ("```" or "~~~"), nil outside a code block.
        var fence: String?

        mutating func add(_ rawLine: String) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) {
                    closeFence()
                } else {
                    code.append(rawLine)
                }
                return
            }
            if let marker = MarkdownNotes.fenceMarker(of: line) {
                flush()
                fence = marker
                return
            }
            if line.isEmpty {
                flush()
                return
            }
            if let match = line.firstMatch(of: #/^>\s?(.*)$/#) {
                flushParagraph()
                quote.append(String(match.1))
                return
            }
            if let item = MarkdownNotes.singleLineBlock(line, rawLine: rawLine) {
                flush()
                blocks.append(item)
                return
            }
            flushQuote()
            paragraph.append(line)
        }

        mutating func finish() -> [Block] {
            if fence != nil { closeFence() }   // an unclosed fence runs to the end, as in CommonMark
            flush()
            return blocks
        }

        private mutating func closeFence() {
            blocks.append(Block(kind: .code, text: AttributedString(code.joined(separator: "\n"))))
            code = []
            fence = nil
        }

        private mutating func flush() {
            flushParagraph()
            flushQuote()
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Block(kind: .paragraph, text: MarkdownNotes.inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        private mutating func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(Block(kind: .quote, text: MarkdownNotes.inline(quote.joined(separator: "\n"))))
            quote = []
        }
    }

    /// Rules, headings and list items (one line each); nil for paragraph text.
    private static func singleLineBlock(_ line: String, rawLine: String) -> Block? {
        if isRule(line) {
            return Block(kind: .rule, text: AttributedString())
        }
        if let match = line.firstMatch(of: #/^(#{1,6})\s+(.*?)(\s+#+)?$/#) {
            return Block(kind: .heading(level: min(match.1.count, 3)), text: inline(String(match.2)))
        }
        let level = indentLevel(of: rawLine)
        if let match = line.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.*)$/#) {
            return Block(kind: .task(isChecked: match.1 != " ", level: level), text: inline(String(match.2)))
        }
        if let match = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
            return Block(kind: .bullet(level: level), text: inline(String(match.1)))
        }
        if let match = line.firstMatch(of: #/^(\d{1,9}[.)])\s+(.*)$/#) {
            return Block(kind: .numbered(marker: String(match.1), level: level), text: inline(String(match.2)))
        }
        return nil
    }

    /// Two spaces (a tab counts as two) per level, at most 6.
    private static func indentLevel(of rawLine: String) -> Int {
        let spaces = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return min(spaces / 2, 6)
    }

    // MARK: Inline text and links

    /// Inline Markdown (emphasis, code, links) of one block, with links limited to
    /// `linkSchemes` and bare URLs and e-mail addresses linked. Unparsable text stays plain.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .throwError)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        removeDisallowedLinks(in: &attributed)
        linkBareAddresses(in: &attributed)
        return attributed
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return linkSchemes.contains(scheme)
    }

    /// The link destinations of a block, in order and without repeats (macOS tooltip).
    static func links(in text: AttributedString) -> [URL] {
        var result: [URL] = []
        for run in text.runs {
            if let link = run.link, !result.contains(link) { result.append(link) }
        }
        return result
    }

    /// Removes links with other schemes (their text stays) and image sources (the alt text stays).
    private static func removeDisallowedLinks(in attributed: inout AttributedString) {
        var disallowed: [Range<AttributedString.Index>] = []
        var images: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if let link = run.link, !isAllowedLink(link) { disallowed.append(run.range) }
            if run.imageURL != nil { images.append(run.range) }
        }
        for range in disallowed {
            attributed[range].link = nil
        }
        for range in images {
            attributed[range].imageURL = nil
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Links URLs and e-mail addresses written without Markdown, outside links and inline code.
    private static func linkBareAddresses(in attributed: inout AttributedString) {
        guard let detector else { return }
        let string = String(attributed.characters)
        let matches = detector.matches(in: string, range: NSRange(string.startIndex..., in: string))
        for match in matches {
            guard let url = match.url, isAllowedLink(url),
                  let stringRange = Range(match.range, in: string),
                  let range = Range(stringRange, in: attributed) else { continue }
            let isFree = attributed[range].runs.allSatisfy { run in
                run.link == nil && !(run.inlinePresentationIntent?.contains(.code) ?? false)
            }
            if isFree { attributed[range].link = url }
        }
    }

    // MARK: Plain text

    /// Markdown as readable plain text: headings, emphasis, inline code and links become their
    /// text, images are dropped, quotes lose their ">", list items get "•" (tasks "☐" / "☑"),
    /// table rows become tab-separated cells without the separator row, rules and fence lines
    /// disappear. Lines inside a code fence are kept verbatim; other lines are kept as they are.
    static func plainText(from markdown: String) -> String {
        var result: [(text: String, isCode: Bool)] = []
        var fence: String?
        for rawLine in lines(of: markdown) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil } else { result.append((rawLine, true)) }
                continue
            }
            if let marker = fenceMarker(of: line) {
                fence = marker
                continue
            }
            if isRule(line) || isTableSeparator(line) {
                continue
            }
            if line.hasPrefix("|") {
                result.append((tableCells(of: line).map(plainInline).joined(separator: "\t"), false))
            } else {
                result.append((blockLine(line, indent: String(rawLine.prefix { $0 == " " || $0 == "\t" })), false))
            }
        }
        return collapsingBlankLines(result).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line outside a table: its block marker replaced or removed, its inline text plain.
    private static func blockLine(_ line: String, indent: String) -> String {
        if let match = line.firstMatch(of: #/^#{1,6}\s+(.*?)(\s+#+)?$/#) {
            return plainInline(String(match.1))
        }
        if let match = line.firstMatch(of: #/^>\s?(.*)$/#) {
            return blockLine(String(match.1), indent: "")
        }
        if let match = line.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.*)$/#) {
            return indent + (match.1 == " " ? "☐ " : "☑ ") + plainInline(String(match.2))
        }
        if let match = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
            return indent + "• " + plainInline(String(match.1))
        }
        if let match = line.firstMatch(of: #/^(\d+[.)])\s+(.*)$/#) {
            return indent + String(match.1) + " " + plainInline(String(match.2))
        }
        return plainInline(line)
    }

    /// Inline Markdown as its text. Unparsable text stays as it is.
    private static func plainInline(_ text: String) -> String {
        let withoutImages = text.replacing(#/!\[[^\]]*\]\([^)]*\)/#, with: "")
        guard let attributed = try? AttributedString(
            markdown: withoutImages,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return withoutImages.trimmingCharacters(in: .whitespaces) }
        return String(attributed.characters).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Lines

    /// The lines of a text; "\r\n" and "\r" count as one line break.
    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// "```" or "~~~" when the trimmed line opens (or closes) a code fence.
    private static func fenceMarker(of line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func tableCells(of line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        // "\|" is a pipe inside a cell.
        let placeholder = "\u{FFFF}"
        return row.replacingOccurrences(of: "\\|", with: placeholder)
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// "|---|:--:|" between a table's header and its rows.
    private static func isTableSeparator(_ line: String) -> Bool {
        line.hasPrefix("|") && line.contains("-") && line.allSatisfy { "|-: \t".contains($0) }
    }

    /// "---", "***", "___" (three or more, spaces allowed).
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Runs of blank lines become one; blank lines inside code are kept.
    private static func collapsingBlankLines(_ lines: [(text: String, isCode: Bool)]) -> [String] {
        var result: [String] = []
        for line in lines {
            if !line.isCode, line.text.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line.text)
        }
        return result
    }
}
