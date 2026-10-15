import Testing
@testable import DocumentArchive

@Suite struct SenderDetectorTests {
    @Test(arguments: [
        ("Stadtwerke München GmbH · Postfach 1234 · 80287 München\nRechnung", "Stadtwerke München GmbH", "Stadtwerke München"),
        ("Deutsche Telekom AG\nKundencenter", "Deutsche Telekom AG", "Deutsche Telekom"),
        ("Invoice\nAnthropic, PBC @anthropic\n548 Market Street", "Anthropic, PBC", "Anthropic"),
        ("Muster GmbH & Co. KG\nHauptstraße 1", "Muster GmbH & Co. KG", "Muster"),
        ("Acme Inc.\n1 Infinite Loop", "Acme Inc.", "Acme"),
        ("Sportverein Lippstadt e.V.\nMitgliedsbeitrag", "Sportverein Lippstadt e.V.", "Sportverein Lippstadt"),
    ])
    func detectsCompanyByLegalForm(text: String, name: String, matchText: String) {
        let sender = SenderDetector.detect(in: text)
        #expect(sender?.name == name)
        #expect(sender?.matchText == matchText)
    }

    @Test func skipsTheRecipientBlock() {
        let text = """
        Rechnungsempfänger
        Max Muster GmbH
        Straße 1
        12345 Ort
        Deutschland

        Vodafone GmbH, Düsseldorf
        """
        #expect(SenderDetector.detect(in: text)?.name == "Vodafone GmbH")
    }

    @Test func skipsBillToBlockInEnglishInvoices() {
        let text = """
        Bill to
        Example Corp.
        Main Street 5
        Springfield
        USA

        Northwind Traders Ltd.
        """
        #expect(SenderDetector.detect(in: text)?.name == "Northwind Traders Ltd.")
    }

    @Test(arguments: [
        "Amtsgericht Köln HRB 1234\nIBAN DE00 0000",
        "Sitz der Gesellschaft: Köln AG",
        "Bankverbindung Commerzbank AG",
    ])
    func ignoresRegisterAndBankLines(text: String) {
        #expect(SenderDetector.detect(in: text) == nil)
    }

    @Test func fallsBackToBusinessEmailDomain() {
        let sender = SenderDetector.detect(in: "Fragen? Schreib an kontakt@gmail.com oder service@ikea.de")
        #expect(sender?.name == "Ikea")
        #expect(sender?.matchText == "Ikea")
    }

    @Test func fallsBackToWebAddress() {
        #expect(SenderDetector.detect(in: "Mehr unter www.example-shop.de")?.name == "Example-shop")
    }

    @Test func ignoresFreemailOnly() {
        #expect(SenderDetector.detect(in: "patrick@mail.de, someone@gmail.com, x@web.de") == nil)
    }

    @Test(arguments: [
        ("Stadtwerke München GmbH", "Stadtwerke München"),
        ("Anthropic, PBC", "Anthropic"),
        ("Revolut Bank UAB", "Revolut Bank UAB"),
        ("GmbH", "GmbH"),
    ])
    func coreNameStripsLegalForm(name: String, expected: String) {
        #expect(SenderDetector.coreName(name) == expected)
    }
}
