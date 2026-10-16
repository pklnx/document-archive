import Foundation
import Testing
@testable import DocumentArchive

/// Markdown in notes and Mistral OCR text (#19): the rendered blocks with their links and the
/// plain text for "Copy Text".
@Suite struct MarkdownNotesTests {
    @Test func plainTextStaysAsItIs() {
        #expect(MarkdownNotes.plainText(from: "Kundennummer 123456\nBetrag 42,00 EUR") == "Kundennummer 123456\nBetrag 42,00 EUR")
    }

    @Test func mistralPageBecomesReadableText() {
        let page = """
        # Rechnung Nr. 2026-117

        **Stadtwerke** Musterstadt, *Abteilung Abrechnung*

        ![img-0.jpeg](img-0.jpeg)

        | Position | Menge | Betrag |
        |:---|---:|---:|
        | Strom `Grundpreis` | 1 | 12,50 € |
        | Arbeitspreis | 230 kWh | 69,00 € |

        ---

        > Bitte überweisen bis zum 30.10.2026.

        Details: [Kundenportal](https://example.com/portal)
        """
        let expected = """
        Rechnung Nr. 2026-117

        Stadtwerke Musterstadt, Abteilung Abrechnung

        Position\tMenge\tBetrag
        Strom Grundpreis\t1\t12,50 €
        Arbeitspreis\t230 kWh\t69,00 €

        Bitte überweisen bis zum 30.10.2026.

        Details: Kundenportal
        """
        #expect(MarkdownNotes.plainText(from: page) == expected)
    }

    @Test func listsAndTasksKeepAMarker() {
        let markdown = """
        ## Offen ##
        - [ ] Kündigen
        - [x] Zählerstand melden
        * Ordner A
          - Unterpunkt
        1. Erster
        2) Zweiter
        """
        let expected = """
        Offen
        ☐ Kündigen
        ☑ Zählerstand melden
        • Ordner A
          • Unterpunkt
        1. Erster
        2) Zweiter
        """
        #expect(MarkdownNotes.plainText(from: markdown) == expected)
    }

    @Test func pipesInsideCellsAndUnclosedEmphasis() {
        #expect(MarkdownNotes.plainText(from: "| a \\| b | c |") == "a | b\tc")
        #expect(MarkdownNotes.plainText(from: "**open") == "**open")
    }

    @Test func codeFencesAreRemoved() {
        #expect(MarkdownNotes.plainText(from: "```\nIBAN DE00 1234\n```") == "IBAN DE00 1234")
    }

    /// Regression (#51 review): lines inside a fence are copied verbatim, not parsed as Markdown.
    @Test func codeFenceContentIsKeptVerbatim() {
        let markdown = """
        Vor dem Block
        ```
        # keine Überschrift
        | a | b |
        |---|---|
        *nicht kursiv* und C:\\Pfad

          - eingerückt
        ```
        ~~~
        > kein Zitat
        ~~~
        """
        let expected = """
        Vor dem Block
        # keine Überschrift
        | a | b |
        |---|---|
        *nicht kursiv* und C:\\Pfad

          - eingerückt
        > kein Zitat
        """
        #expect(MarkdownNotes.plainText(from: markdown) == expected)
    }

    // MARK: Blocks

    private func blocks(_ markdown: String) -> [MarkdownNotes.Block] { MarkdownNotes.blocks(from: markdown) }

    private func text(_ block: MarkdownNotes.Block?) -> String { block.map { String($0.text.characters) } ?? "" }

    private func links(_ block: MarkdownNotes.Block?) -> [URL] { block.map { MarkdownNotes.links(in: $0.text) } ?? [] }

    @Test func plainTextIsOneParagraph() {
        let result = blocks("Rückruf bei Frau Muster\nVertrag liegt im Ordner")
        #expect(result.count == 1)
        #expect(result.first?.kind == .paragraph)
        #expect(text(result.first) == "Rückruf bei Frau Muster\nVertrag liegt im Ordner")
        #expect(links(result.first).isEmpty)
        #expect(blocks("").isEmpty)
        #expect(blocks(" \n\n ").isEmpty)
    }

    @Test func blankLinesSeparateParagraphs() {
        let result = blocks("Erster Absatz\n\n\nZweiter Absatz")
        #expect(result.map(\.kind) == [.paragraph, .paragraph])
        #expect(result.map(text) == ["Erster Absatz", "Zweiter Absatz"])
    }

    @Test func boldAndItalicHaveTheirIntents() throws {
        let block = try #require(blocks("Bitte **bis Freitag** *bezahlen* und `IBAN` prüfen").first)
        var intents: [String: InlinePresentationIntent] = [:]
        for run in block.text.runs {
            if let intent = run.inlinePresentationIntent {
                intents[String(block.text[run.range].characters)] = intent
            }
        }
        #expect(text(block) == "Bitte bis Freitag bezahlen und IBAN prüfen")
        #expect(intents["bis Freitag"] == .stronglyEmphasized)
        #expect(intents["bezahlen"] == .emphasized)
        #expect(intents["IBAN"] == .code)
    }

    @Test func markdownLinkKeepsItsText() throws {
        let block = try #require(blocks("Siehe [Vertrag](https://example.com/vertrag) im Portal").first)
        #expect(text(block) == "Siehe Vertrag im Portal")
        #expect(links(block) == [URL(string: "https://example.com/vertrag")!])
        let run = try #require(block.text.runs.first { $0.link != nil })
        #expect(String(block.text[run.range].characters) == "Vertrag")
    }

    @Test func bareURLAndEmailAreLinked() throws {
        let block = try #require(blocks("Portal: https://example.com/login, Fragen an info@example.com, Tel. tel:+49301234").first)
        let found = links(block).map(\.absoluteString)
        #expect(found.contains("https://example.com/login"))
        #expect(found.contains("mailto:info@example.com"))
        #expect(found.contains("tel:+49301234"))
        #expect(text(block) == "Portal: https://example.com/login, Fragen an info@example.com, Tel. tel:+49301234")
    }

    @Test func otherSchemesAreNotLinked() throws {
        let markdown = """
        [Datei](file:///etc/passwd)
        [Skript](javascript:alert(1))
        [App](myapp://open/1)
        file:///Users/test/a.pdf und myapp://open/2
        """
        let block = try #require(blocks(markdown).first)
        #expect(links(block).isEmpty, "unexpected links: \(links(block))")
        #expect(text(block).hasPrefix("Datei\nSkript\nApp\n"))
        #expect(MarkdownNotes.isAllowedLink(URL(string: "HTTPS://example.com")!))
        #expect(!MarkdownNotes.isAllowedLink(URL(string: "ftp://example.com")!))
    }

    @Test func inlineCodeIsNotLinked() throws {
        let block = try #require(blocks("Aufruf: `https://example.com/api`").first)
        #expect(links(block).isEmpty)
    }

    @Test func headingsListsAndTasks() {
        let markdown = """
        # Vertrag
        ## Fristen ##
        #### Detail
        - Kündigung
          * Schriftlich
        1. Erster
        12) Zwölfter
        - [ ] Kündigen
        - [x] Zählerstand melden
        > Zitat **fett**
        > zweite Zeile
        ---
        """
        let result = blocks(markdown)
        #expect(result.map(\.kind) == [
            .heading(level: 1), .heading(level: 2), .heading(level: 3),
            .bullet(level: 0), .bullet(level: 1),
            .numbered(marker: "1.", level: 0), .numbered(marker: "12)", level: 0),
            .task(isChecked: false, level: 0), .task(isChecked: true, level: 0),
            .quote, .rule,
        ])
        #expect(result.map(text) == [
            "Vertrag", "Fristen", "Detail", "Kündigung", "Schriftlich", "Erster", "Zwölfter",
            "Kündigen", "Zählerstand melden", "Zitat fett\nzweite Zeile", "",
        ])
    }

    @Test func unclosedEmphasisFallsBackToText() {
        let result = blocks("**open")
        #expect(result.map(\.kind) == [.paragraph])
        #expect(text(result.first) == "**open")
        #expect(text(blocks("[nur Text](").first) == "[nur Text](")
    }

    /// Fences are code: their lines stay verbatim, are not parsed and get no links.
    @Test func codeFenceIsOneVerbatimBlock() {
        let result = blocks("Text\n```\n# keine Überschrift\n**nicht fett** https://example.com\n```\n- Punkt")
        #expect(result.map(\.kind) == [.paragraph, .code, .bullet(level: 0)])
        #expect(text(result[safe: 1]) == "# keine Überschrift\n**nicht fett** https://example.com")
        #expect(links(result[safe: 1]).isEmpty)
        // An unclosed fence runs to the end.
        #expect(blocks("```\n# a\n- b").map(\.kind) == [.code])
    }

    @Test func windowsLineBreaks() {
        #expect(blocks("# Titel\r\nZeile 1\r\nZeile 2").map(text) == ["Titel", "Zeile 1\nZeile 2"])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
