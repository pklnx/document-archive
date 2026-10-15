import Foundation
import Testing
@testable import DocumentArchive

@Suite struct DateDetectorTests {
    @Test(arguments: [
        ("Rechnungsdatum: 03.09.2026", TestSupport.date(2026, 9, 3)),
        ("am 5.7.24 erhalten", TestSupport.date(2024, 7, 5)),
        ("vom 2024-11-05", TestSupport.date(2024, 11, 5)),
        ("Datum 1. März 2025 bla", TestSupport.date(2025, 3, 1)),
        ("München, 12 Dezember 2023", TestSupport.date(2023, 12, 12)),
        ("Date of issue October 3, 2026", TestSupport.date(2026, 10, 3)),
        ("Issued on Oct 3rd 2026", TestSupport.date(2026, 10, 3)),
    ])
    func recognizesFormats(text: String, expected: DateComponents) {
        #expect(TestSupport.components(of: DateDetector.firstDate(in: text)) == expected)
    }

    @Test(arguments: [
        "Version 1.2.3",
        "Telefon 0211 12345678",
        "Kein Datum hier",
        "Gültig bis 01.01.2099",   // more than a year in the future
        "31.02.2026",              // no such day
        "15.13.2026",              // no such month
    ])
    func ignoresNonDates(text: String) {
        #expect(DateDetector.firstDate(in: text) == nil)
    }

    @Test func earliestDateInTheTextWins() {
        let text = "Rechnung vom 03.09.2026, fällig am 17.09.2026"
        #expect(TestSupport.components(of: DateDetector.firstDate(in: text)) == TestSupport.date(2026, 9, 3))
    }

    @Test func picksEarliestAcrossFormats() {
        let text = "Invoice date October 3, 2026\nPaid 2026-10-10"
        #expect(TestSupport.components(of: DateDetector.firstDate(in: text)) == TestSupport.date(2026, 10, 3))
    }
}
