import Foundation

/// Markdown in notes and in Mistral's OCR text (#19). This part has the conversion to plain
/// text for "Copy Text"; the rendered notes (blocks, links) follow in part 2.
enum MarkdownNotes {
    /// Markdown as readable plain text: headings, emphasis, inline code and links become their
    /// text, images are dropped, quotes lose their ">", list items get "•" (tasks "☐" / "☑"),
    /// table rows become tab-separated cells without the separator row, rules and code fences
    /// disappear. Other lines are kept as they are.
    static func plainText(from markdown: String) -> String {
        var lines: [String] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") || isRule(line) || isTableSeparator(line) {
                continue
            }
            if line.hasPrefix("|") {
                lines.append(tableCells(of: line).map(inline).joined(separator: "\t"))
            } else {
                lines.append(blockLine(line, indent: String(rawLine.prefix { $0 == " " || $0 == "\t" })))
            }
        }
        return collapsingBlankLines(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line outside a table: its block marker replaced or removed, its inline text plain.
    private static func blockLine(_ line: String, indent: String) -> String {
        if let match = line.firstMatch(of: #/^#{1,6}\s+(.*?)(\s+#+)?$/#) {
            return inline(String(match.1))
        }
        if let match = line.firstMatch(of: #/^>\s?(.*)$/#) {
            return blockLine(String(match.1), indent: "")
        }
        if let match = line.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.*)$/#) {
            return indent + (match.1 == " " ? "☐ " : "☑ ") + inline(String(match.2))
        }
        if let match = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
            return indent + "• " + inline(String(match.1))
        }
        if let match = line.firstMatch(of: #/^(\d+[.)])\s+(.*)$/#) {
            return indent + String(match.1) + " " + inline(String(match.2))
        }
        return inline(line)
    }

    /// Inline Markdown as its text. Unparsable text stays as it is.
    private static func inline(_ text: String) -> String {
        let withoutImages = text.replacing(#/!\[[^\]]*\]\([^)]*\)/#, with: "")
        guard let attributed = try? AttributedString(
            markdown: withoutImages,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return withoutImages.trimmingCharacters(in: .whitespaces) }
        return String(attributed.characters).trimmingCharacters(in: .whitespaces)
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

    private static func collapsingBlankLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        return result
    }
}
