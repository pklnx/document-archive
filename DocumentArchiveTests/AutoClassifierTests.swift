import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

extension GlobalStateTests {
    @Suite @MainActor final class AutoClassifierTests {
        let container: ModelContainer
        let defaultsName: String
        var context: ModelContext { container.mainContext }

        static let invoiceText = """
            Invoice
            Invoice number GIK14I5L-0014
            Date of issue October 3, 2026
            Anthropic, PBC @anthropic
            548 Market Street
            Bill to
            Example Organization
            Total €96.50
            """

        init() throws {
            container = try TestSupport.makeContainer()
            let (defaults, name) = TestSupport.makeDefaults()
            defaultsName = name
            AutoClassifier.defaults = defaults
            MistralStub.reset()
        }

        deinit {
            AutoClassifier.defaults = .standard
            TestSupport.removeDefaults(defaultsName)
            MistralStub.reset()
        }

        private func makeDocument(_ text: String, fileName: String = "Invoice-0014.pdf") -> Document {
            let doc = Document(title: (fileName as NSString).deletingPathExtension, pdfData: Data(),
                               source: .file, originalFileName: fileName)
            doc.extractedText = text
            context.insert(doc)
            return doc
        }

        private func correspondents() throws -> [Correspondent] {
            try context.fetch(FetchDescriptor<Correspondent>())
        }

        /// A Mistral stub that always suggests the given classification.
        private func stubMistral(title: String = "Rechnung Max-Abo", correspondent: String? = "Anthropic, PBC",
                                 type: String? = "Rechnung", tags: [String] = [], date: String? = "2026-10-03") {
            func value(_ string: String?) -> Any { string.map { $0 as Any } ?? NSNull() }
            MistralStub.install(config: MistralStub.config()) { _, _ in
                .chat([
                    "title": title, "correspondent": value(correspondent), "document_type": value(type),
                    "tags": tags, "date": value(date),
                ])
            }
        }

        // MARK: Without Mistral

        @Test func rulesAndHeuristicsWithoutMistral() async throws {
            for (name, symbol, match) in DocumentType.defaults {
                context.insert(DocumentType(name: name, symbol: symbol, matchText: match))
            }
            let doc = makeDocument(Self.invoiceText)

            let outcome = await AutoClassifier.classify(doc, context: context)

            #expect(!outcome.usedAI)
            #expect(outcome.aiError == nil)
            let invoice = DocumentType.defaults[0].0           // "Invoice" in the app language
            #expect(doc.documentType?.name == invoice)          // matched by the "Invoice" keyword
            #expect(doc.correspondent?.name == "Anthropic, PBC") // detected sender, created
            #expect(doc.correspondent?.matchText == "Anthropic")
            #expect(TestSupport.components(of: doc.documentDate) == TestSupport.date(2026, 10, 3))
            #expect(doc.title == "Invoice-0014", "file imports keep their title without AI")
            #expect(outcome.isComplete)
        }

        @Test func doesNotCreateCorrespondentsWhenTurnedOff() async throws {
            AutoClassifier.defaults.set(false, forKey: AutoClassifier.autoCreateCorrespondentsKey)
            let doc = makeDocument(Self.invoiceText)
            await AutoClassifier.classify(doc, context: context)
            #expect(doc.correspondent == nil)
            #expect(try correspondents().isEmpty)
        }

        @Test func scanGetsTitleFromTypeAndCorrespondent() async throws {
            context.insert(DocumentType(name: "Rechnung", matchText: "Rechnung"))
            context.insert(Correspondent(name: "Stadtwerke München GmbH"))
            let doc = Document(title: "Scan 15.10.2026, 14:30", pdfData: Data(), source: .scan)
            doc.extractedText = "Stadtwerke München\nRechnung\n03.09.2026"
            context.insert(doc)

            await AutoClassifier.classify(doc, context: context)

            #expect(doc.title == "Rechnung Stadtwerke München GmbH")
        }

        @Test func reportsWhenNothingWasFound() async throws {
            let doc = makeDocument("Lorem ipsum")
            let outcome = await AutoClassifier.classify(doc, context: context)
            #expect(outcome.changes.isEmpty)
            #expect(!outcome.isComplete)
        }

        // MARK: With Mistral

        @Test func mistralFillsEmptyFields() async throws {
            context.insert(DocumentType(name: "Rechnung"))
            context.insert(ArchiveTag(name: "Software"))
            stubMistral(tags: ["Software"])
            let doc = makeDocument(Self.invoiceText)

            let outcome = await AutoClassifier.classify(doc, context: context)

            #expect(outcome.usedAI)
            #expect(doc.title == "Rechnung Max-Abo")
            #expect(doc.correspondent?.name == "Anthropic, PBC")
            #expect(doc.documentType?.name == "Rechnung")
            #expect(doc.sortedTags.map(\.name) == ["Software"])
            #expect(TestSupport.components(of: doc.documentDate) == TestSupport.date(2026, 10, 3))
            #expect(try correspondents().count == 1)
        }

        @Test func sendsExistingMetadataToMistral() async throws {
            context.insert(DocumentType(name: "Rechnung"))
            context.insert(ArchiveTag(name: "Software"))
            context.insert(Correspondent(name: "Telekom"))
            stubMistral()
            await AutoClassifier.classify(makeDocument(Self.invoiceText), context: context)

            let body = MistralStub.json(try #require(MistralStub.requests.first).body)
            let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            #expect(user.contains("Telekom"))
            #expect(user.contains("Rechnung"))
            #expect(user.contains("Software"))
            #expect(user.contains("Invoice number GIK14I5L-0014"))
        }

        // MARK: Nested tags (#13)

        @Test func classificationSendsTagPathsAndSpecificityRule() async throws {
            let auto = ArchiveTag(name: "Auto")
            let golf = ArchiveTag(name: "Golf")
            [auto, golf].forEach(context.insert)
            golf.parent = auto
            stubMistral()
            await AutoClassifier.classify(makeDocument(Self.invoiceText), context: context)

            let body = MistralStub.json(try #require(MistralStub.requests.first).body)
            let messages = body["messages"] as? [[String: Any]] ?? []
            let system = messages.first?["content"] as? String ?? ""
            let user = messages.last?["content"] as? String ?? ""
            #expect(user.contains("Existing tags: Auto; Auto › Golf"))
            #expect(system.contains("choose the most specific matching tag; never add its parent tag as well"))
            let schema = ((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
            let tags = (schema?["properties"] as? [String: Any])?["tags"] as? [String: Any]
            #expect((tags?["items"] as? [String: Any])?["enum"] as? [String] == ["Auto", "Auto › Golf"])
        }

        @Test func suggestedTagPathMapsToNestedTag() async throws {
            let auto = ArchiveTag(name: "Auto")
            let golf = ArchiveTag(name: "Golf")
            let werkstatt = ArchiveTag(name: "Werkstatt")
            let otherWerkstatt = ArchiveTag(name: "Werkstatt")
            let polo = ArchiveTag(name: "Polo")
            [auto, golf, werkstatt, otherWerkstatt, polo].forEach(context.insert)
            golf.parent = auto
            werkstatt.parent = golf
            polo.parent = auto
            otherWerkstatt.parent = polo
            stubMistral(tags: ["auto › golf › werkstatt", "Polo"])
            let doc = makeDocument(Self.invoiceText)

            await AutoClassifier.classify(doc, context: context)

            #expect(doc.sortedTags.map(\.id) == [werkstatt.id, polo.id],
                    "the path picks the right Werkstatt; a unique leaf name works too; no parent is added")
        }

        /// Before a merge, two roots share the path "Werkstatt", and a tag literally named
        /// "Auto › Golf" has the same path as the real Auto › Golf. The oldest wins, no crash.
        @Test func duplicatePathsDoNotCrash() async throws {
            func tag(_ name: String, _ seconds: TimeInterval, under parent: ArchiveTag? = nil) -> ArchiveTag {
                let tag = ArchiveTag(name: name)
                tag.createdAt = Date(timeIntervalSince1970: seconds)
                context.insert(tag)
                tag.parent = parent
                return tag
            }
            let newerWerkstatt = tag("Werkstatt", 2000)
            let olderWerkstatt = tag("Werkstatt", 1000)
            let auto = tag("Auto", 500)
            let realGolf = tag("Golf", 3000, under: auto)
            let literal = tag("Auto › Golf", 4000)

            let byPath = AutoClassifier.tagsByPath([newerWerkstatt, olderWerkstatt, auto, realGolf, literal])
            #expect(byPath["werkstatt"]?.id == olderWerkstatt.id)
            #expect(byPath["auto › golf"]?.id == realGolf.id)

            stubMistral(tags: ["Werkstatt", "Auto › Golf"])
            let doc = makeDocument(Self.invoiceText)
            await AutoClassifier.classify(doc, context: context)
            #expect(Set(doc.tags?.map(\.id) ?? []) == [olderWerkstatt.id, realGolf.id])

            let body = MistralStub.json(try #require(MistralStub.requests.first).body)
            let schema = ((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
            let tags = (schema?["properties"] as? [String: Any])?["tags"] as? [String: Any]
            #expect((tags?["items"] as? [String: Any])?["enum"] as? [String] == ["Auto", "Auto › Golf", "Werkstatt"],
                    "each path is sent once")
        }

        @Test func userRulesWinOverMistralForCorrespondents() async throws {
            let rule = Correspondent(name: "Anthropic")
            context.insert(rule)
            stubMistral(correspondent: "Some Other Company Inc.")
            let doc = makeDocument(Self.invoiceText)

            await AutoClassifier.classify(doc, context: context)

            #expect(doc.correspondent?.id == rule.id)
            #expect(try correspondents().count == 1)
        }

        @Test func mistralSuggestionMatchesExistingCorrespondentByCoreName() async throws {
            let existing = Correspondent(name: "Anthropic")
            existing.matchMode = .none   // no rule, so only the AI suggestion can assign it
            context.insert(existing)
            stubMistral(correspondent: "Anthropic, PBC")
            let doc = makeDocument("Some text without the name")

            await AutoClassifier.classify(doc, context: context)

            #expect(doc.correspondent?.id == existing.id)
            #expect(try correspondents().count == 1)
        }

        @Test func manualChangesAreNeverOverwritten() async throws {
            let manual = Correspondent(name: "Mein Korrespondent")
            manual.matchMode = .none
            context.insert(manual)
            stubMistral()
            let doc = makeDocument(Self.invoiceText)
            doc.title = "Mein eigener Titel"
            doc.correspondent = manual
            let manualDate = Calendar.current.date(byAdding: .day, value: -400, to: doc.createdAt)!
            doc.documentDate = manualDate

            await AutoClassifier.classify(doc, context: context)

            #expect(doc.title == "Mein eigener Titel")
            #expect(doc.correspondent?.id == manual.id)
            #expect(doc.documentDate == manualDate)
        }

        @Test func mistralTypeMustBeAnExistingOne() async throws {
            stubMistral(type: "Erfundener Typ")
            let doc = makeDocument(Self.invoiceText)
            await AutoClassifier.classify(doc, context: context)
            #expect(doc.documentType == nil)
            #expect(try context.fetch(FetchDescriptor<DocumentType>()).isEmpty)
        }

        @Test func fallsBackToHeuristicsWhenMistralFails() async throws {
            MistralStub.install(config: MistralStub.config()) { _, _ in .json(["message": "Unauthorized"], status: 401) }
            let doc = makeDocument(Self.invoiceText)

            let outcome = await AutoClassifier.classify(doc, context: context)

            #expect(outcome.aiError != nil)
            #expect(!outcome.usedAI)
            #expect(doc.correspondent?.name == "Anthropic, PBC")
            #expect(TestSupport.components(of: doc.documentDate) == TestSupport.date(2026, 10, 3))
        }

        @Test func skipsMistralWhenTurnedOff() async throws {
            MistralStub.install(config: MistralStub.config(useLLM: false)) { _, _ in .json([:]) }
            await AutoClassifier.classify(makeDocument(Self.invoiceText), context: context)
            #expect(MistralStub.requests.isEmpty)
        }

        /// Regression: documents imported together each created their own copy of the same correspondent.
        @Test func concurrentClassificationCreatesOneCorrespondent() async throws {
            stubMistral(correspondent: "Deutsche Rentenversicherung Westfalen", type: nil, date: nil)
            MistralStub.delay = 0.3
            let documents = (1...3).map { makeDocument("Deutsche Rentenversicherung Westfalen\nSchreiben \($0)",
                                                       fileName: "Brief-\($0).pdf") }
            let context = context

            await withTaskGroup(of: Void.self) { group in
                for doc in documents {
                    group.addTask { @MainActor in _ = await AutoClassifier.classify(doc, context: context) }
                }
            }

            let all = try correspondents()
            #expect(all.count == 1)
            #expect(documents.allSatisfy { $0.correspondent?.id == all.first?.id })
        }
    }
}
