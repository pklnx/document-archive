import Foundation
import Testing
@testable import DocumentArchive

/// Markdown in notes and Mistral OCR text (#19). Part 1: the plain text for "Copy Text".
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
}
