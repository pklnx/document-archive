import Testing
@testable import DocumentArchive

@Suite struct MatchingRuleTests {
    private func rule(_ mode: MatchMode, _ text: String) -> ArchiveTag {
        let tag = ArchiveTag(name: "Test")
        tag.matchMode = mode
        tag.matchText = text
        return tag
    }

    @Test func anyMatchesOneOfTheWords() {
        let tag = rule(.any, "Strom Gas")
        #expect(tag.matches(text: "Ihr Gasabschlag" ) == false) // whole words only
        #expect(tag.matches(text: "Abschlag für Gas"))
        #expect(tag.matches(text: "STROM"))
    }

    @Test func anyAcceptsCommaSeparatedWords() {
        #expect(rule(.any, "Kfz, Werkstatt").matches(text: "Rechnung der Werkstatt"))
    }

    @Test func allNeedsEveryWord() {
        let tag = rule(.all, "Strom Abschlag")
        #expect(tag.matches(text: "Abschlag Strom September"))
        #expect(!tag.matches(text: "Strom Jahresrechnung"))
    }

    @Test func exactMatchesThePhraseIgnoringCaseAndDiacritics() {
        let tag = rule(.exact, "Stadtwerke München")
        #expect(tag.matches(text: "STADTWERKE MUNCHEN GmbH"))
        #expect(!tag.matches(text: "Stadtwerke Köln"))
    }

    @Test func regexMatches() {
        let tag = rule(.regex, #"Kundennr\.?\s*12345"#)
        #expect(tag.matches(text: "Kundennr. 12345"))
        #expect(tag.matches(text: "kundennr12345"))
        #expect(!tag.matches(text: "Kundennr. 54321"))
    }

    @Test func noneAndEmptyNeverMatch() {
        #expect(!rule(.none, "Strom").matches(text: "Strom"))
        #expect(!rule(.any, "").matches(text: "Strom"))
        #expect(!rule(.any, "Strom").matches(text: ""))
    }

    @Test func scoreCountsMatchingWords() {
        let tag = rule(.any, "Rechnung Rechnungsnummer Invoice")
        #expect(tag.matchScore(text: "Rechnung, Rechnungsnummer 42") == 2)
        #expect(tag.matchScore(text: "Invoice") == 1)
        #expect(tag.matchScore(text: "Vertrag") == 0)
        #expect(rule(.exact, "Stadtwerke").matchScore(text: "Stadtwerke") == 2)
    }

    @Test func newCorrespondentMatchesItsCoreNameExactly() {
        let correspondent = Correspondent(name: "Stadtwerke München GmbH")
        #expect(correspondent.matchMode == .exact)
        #expect(correspondent.matchText == "Stadtwerke München")
        #expect(correspondent.matches(text: "Ihre Stadtwerke München informieren"))
        // "any" would have matched every document mentioning München
        #expect(!correspondent.matches(text: "Bürgerbüro München"))
    }
}
