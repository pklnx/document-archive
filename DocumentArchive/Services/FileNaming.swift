import Foundation

/// File names for PDFs that leave the app (share, export, copy, drag; #19). Owner of the naming
/// rules; #10's multi-share uses `unique` for several documents with the same name.
enum FileNaming {
    /// File systems allow 255 bytes per name component; this leaves room for " (2)" and the like.
    static let maximumBytes = 240
    static let pdfExtension = "pdf"

    /// Characters no file system (or a share target) takes in a name, and control characters
    /// (C0, DEL, C1; not format characters such as the zero-width joiner inside emoji).
    private static let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x00)!...Unicode.Scalar(0x1F)!))
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x7F)!...Unicode.Scalar(0x9F)!))
    private static let trimmed = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))

    /// A safe PDF file name: invalid and control characters replaced with "-", runs of
    /// whitespace collapsed into one space, spaces and dots trimmed at both ends, exactly one
    /// ".pdf" (any case of an existing one is replaced), at most `maximumBytes` UTF-8 bytes
    /// including the extension, cut between characters (grapheme clusters). An empty name
    /// becomes `fallback` ("Document").
    static func sanitized(_ name: String, fallback: String = String(localized: "Document")) -> String {
        let suffix = "." + pdfExtension
        var stem = clean(name)
        while true {
            while let last = stem.unicodeScalars.last, trimmed.contains(last) { stem.unicodeScalars.removeLast() }
            guard stem.lowercased().hasSuffix(suffix) else { break }
            stem.removeLast(suffix.count)
        }
        stem = stem.trimmingCharacters(in: trimmed)
        if stem.isEmpty { stem = clean(fallback).trimmingCharacters(in: trimmed) }
        if stem.isEmpty { stem = "Document" }
        return truncated(stem, toBytes: maximumBytes - suffix.utf8.count) + suffix
    }

    /// The names with " (2)", " (3)", … added to the second, third, … occurrence of a name, so
    /// they can be written into one folder (compared without case, like APFS and HFS+ do). A
    /// suffix never produces a name that is already in the list.
    static func unique(_ names: [String]) -> [String] {
        var used = Set<String>()
        var reserved = Set(names.map { $0.lowercased() })
        var result: [String] = []
        for name in names {
            var candidate = name
            if used.contains(candidate.lowercased()) {
                let ext = (name as NSString).pathExtension
                let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                let dotExt = ext.isEmpty ? "" : "." + ext
                var number = 2
                repeat {
                    let counter = " (\(number))"
                    let room = maximumBytes - counter.utf8.count - dotExt.utf8.count
                    candidate = truncated(stem, toBytes: room) + counter + dotExt
                    number += 1
                } while used.contains(candidate.lowercased()) || reserved.contains(candidate.lowercased())
            }
            used.insert(candidate.lowercased())
            reserved.insert(candidate.lowercased())
            result.append(candidate)
        }
        return result
    }

    /// Line breaks and tabs become spaces, runs of spaces one space, invalid characters "-".
    private static func clean(_ name: String) -> String {
        let collapsed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The longest prefix of whole characters that fits into `bytes` UTF-8 bytes; trailing
    /// spaces and dots of the cut are removed.
    private static func truncated(_ text: String, toBytes bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var count = 0
        for character in text {
            let size = character.utf8.count
            if count + size > bytes { break }
            result.append(character)
            count += size
        }
        return result.trimmingCharacters(in: trimmed)
    }
}
