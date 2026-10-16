import Foundation
import Testing
@testable import DocumentArchive

@Suite struct FileNamingTests {
    @Test func invalidCharactersBecomeDashes() {
        #expect(FileNaming.sanitized("Rechnung: 03/2026 *final* <A|B> \"x\" ?%\\") == "Rechnung- 03-2026 -final- -A-B- -x- ---.pdf")
        #expect(FileNaming.sanitized("Zeile\u{0007}eins") == "Zeile-eins.pdf")
    }

    @Test func spacesAndDotsAreTrimmedAndCollapsed() {
        #expect(FileNaming.sanitized("  ..Vertrag   Miete\n2026.. ") == "Vertrag Miete 2026.pdf")
        #expect(FileNaming.sanitized(".hidden") == "hidden.pdf")
    }

    @Test func emptyNameFallsBack() {
        #expect(FileNaming.sanitized("", fallback: "Document") == "Document.pdf")
        #expect(FileNaming.sanitized("  . . ", fallback: "Document") == "Document.pdf")
        #expect(FileNaming.sanitized(".pdf", fallback: "Document") == "Document.pdf")
        #expect(FileNaming.sanitized("", fallback: "") == "Document.pdf")
    }

    @Test func exactlyOnePDFExtension() {
        #expect(FileNaming.sanitized("Rechnung") == "Rechnung.pdf")
        #expect(FileNaming.sanitized("Rechnung.pdf") == "Rechnung.pdf")
        #expect(FileNaming.sanitized("Rechnung.PDF") == "Rechnung.pdf")
        #expect(FileNaming.sanitized("Rechnung.pdf.Pdf") == "Rechnung.pdf")
        #expect(FileNaming.sanitized("Rechnung.pdf. ") == "Rechnung.pdf")
        #expect(FileNaming.sanitized("Rechnung.txt") == "Rechnung.txt.pdf")
    }

    @Test func longNamesStayWithinTheByteLimitAtCharacterBoundaries() {
        let name = FileNaming.sanitized(String(repeating: "ä", count: 200))
        #expect(name.utf8.count <= FileNaming.maximumBytes)
        #expect(name.hasSuffix(".pdf"))
        #expect(name.dropLast(4).allSatisfy { $0 == "ä" })
        #expect(name.count == 118 + 4)

        // Emoji with several scalars are never cut in half.
        let family = "👨‍👩‍👧‍👦"
        let emoji = FileNaming.sanitized(String(repeating: family, count: 30))
        #expect(emoji.utf8.count <= FileNaming.maximumBytes)
        #expect(emoji.dropLast(4).allSatisfy { String($0) == family })

        // Short names are not touched.
        #expect(FileNaming.sanitized("Kurz") == "Kurz.pdf")
    }

    @Test func uniqueNumbersRepeatedNames() {
        #expect(FileNaming.unique(["A.pdf", "B.pdf", "a.pdf", "A.pdf"]) == ["A.pdf", "B.pdf", "a (2).pdf", "A (3).pdf"])
        #expect(FileNaming.unique(["A.pdf", "A.pdf", "A (2).pdf"]) == ["A.pdf", "A (3).pdf", "A (2).pdf"])
        #expect(FileNaming.unique([]) == [])
    }

    @Test func uniqueKeepsTheByteLimit() {
        let long = FileNaming.sanitized(String(repeating: "ä", count: 200))
        let names = FileNaming.unique([long, long])
        #expect(names[0] == long)
        #expect(names[1].hasSuffix(" (2).pdf"))
        #expect(names[1].utf8.count <= FileNaming.maximumBytes)
    }

    /// Regression: the export name is the same as before `FileNaming`.
    @Test func exportFileNameUnchanged() {
        let document = Document(title: "Rechnung: September/Oktober", pdfData: Data(), source: .file)
        document.documentDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!
        document.correspondent = Correspondent(name: "Stadtwerke")
        #expect(document.exportFileName == "2026-09-03 Stadtwerke Rechnung- September-Oktober.pdf")

        document.title = "Stadtwerke Abschlag"
        #expect(document.exportFileName == "2026-09-03 Stadtwerke Abschlag.pdf")

        document.correspondent = nil
        document.title = "Kfz-Versicherung 2026"
        #expect(document.exportFileName == "2026-09-03 Kfz-Versicherung 2026.pdf")
    }
}
