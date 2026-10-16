import Foundation
import Testing
@testable import DocumentArchive

@Suite struct MistralClientTests {
    /// A client that talks to a new stub session answering with `handler`.
    private func stubbedClient(_ handler: @escaping MistralStub.Handler) -> (MistralClient, MistralStub.Session) {
        let stub = MistralStub.install(handler: handler)
        return (MistralClient(config: stub.config, environment: stub.environment), stub)
    }

    // MARK: OCR

    @Test func ocrSendsThePDFAsDataURI() async throws {
        let (client, stub) = stubbedClient { _, _ in .json(["pages": [["index": 0, "markdown": "Hallo"]]]) }
        let pdf = Data("%PDF-1.4 test".utf8)

        _ = try await client.ocr(pdfData: pdf)

        let request = try #require(stub.requests.first)
        #expect(request.request.url?.absoluteString == "https://api.mistral.ai/v1/ocr")
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(stub.config.apiKey)")
        let body = MistralStub.json(request.body)
        #expect(body["model"] as? String == MistralConfig.defaultOCRModel)
        let document = try #require(body["document"] as? [String: Any])
        #expect(document["type"] as? String == "document_url")
        #expect(document["document_url"] as? String == "data:application/pdf;base64," + pdf.base64EncodedString())
        #expect(body["include_image_base64"] as? Bool == false)
    }

    /// The environment's encode hook sees exactly the PDF that is sent (#44 part 3 checks the thread).
    @Test func ocrPassesThePDFToTheEncodeHook() async throws {
        let stub = MistralStub.install { _, _ in .json(["pages": [["index": 0, "markdown": "Hallo"]]]) }
        let encoded = Recorder<Data>()
        var environment = stub.environment
        environment.encodeHook = { encoded.append($0) }
        let pdf = Data("%PDF-1.4 hook".utf8)

        _ = try await MistralClient(config: stub.config, environment: environment).ocr(pdfData: pdf)

        #expect(encoded.values == [pdf])
        #expect(stub.requests.count == 1)
    }

    @Test func ocrJoinsPagesInOrderAndDropsImagePlaceholders() async throws {
        let (client, _) = stubbedClient { _, _ in
            .json(["pages": [
                ["index": 1, "markdown": "Seite zwei ![img-0.jpeg](img-0.jpeg)"],
                ["index": 0, "markdown": "# Seite eins"],
            ]])
        }
        #expect(try await client.ocr(pdfData: Data()) == "# Seite eins\n\nSeite zwei")
    }

    @Test func ocrRejectsResponsesWithoutPages() async throws {
        let (client, _) = stubbedClient { _, _ in .json(["unexpected": true]) }
        await #expect(throws: MistralError.self) { try await client.ocr(pdfData: Data()) }
    }

    // MARK: Classification

    @Test func classificationUsesAStrictSchemaWithExistingValues() async throws {
        let (client, stub) = stubbedClient { _, _ in
            .chat(["title": "T", "correspondent": NSNull(), "document_type": "Rechnung", "tags": ["Steuer"], "date": "2026-10-03"])
        }

        let suggestion = try await client.classify(text: "Text", fileName: "a.pdf", correspondents: ["Telekom"],
                                                   documentTypes: ["Rechnung", "Vertrag"], tags: ["Steuer"])

        #expect(suggestion.title == "T")
        #expect(suggestion.correspondent == nil)
        #expect(suggestion.documentType == "Rechnung")
        #expect(suggestion.tags == ["Steuer"])
        #expect(TestSupport.components(of: suggestion.parsedDate) == TestSupport.date(2026, 10, 3))

        let body = MistralStub.json(try #require(stub.requests.first).body)
        #expect(body["model"] as? String == MistralConfig.defaultChatModel)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
        let properties = try #require((jsonSchema["schema"] as? [String: Any])?["properties"] as? [String: Any])
        let typeEnum = (properties["document_type"] as? [String: Any])?["enum"] as? [Any]
        #expect(typeEnum?.compactMap { $0 as? String } == ["Rechnung", "Vertrag"])
        #expect(typeEnum?.contains { $0 is NSNull } == true)
        let tagEnum = ((properties["tags"] as? [String: Any])?["items"] as? [String: Any])?["enum"] as? [String]
        #expect(tagEnum == ["Steuer"])
    }

    @Test func classificationAsksForTitlesInTheGivenLanguage() async throws {
        let (client, stub) = stubbedClient { _, _ in
            .chat(["title": "T", "correspondent": NSNull(), "document_type": NSNull(), "tags": [], "date": NSNull()])
        }
        _ = try await client.classify(text: "Text", fileName: "", correspondents: [], documentTypes: [], tags: [],
                                      titleLanguage: "German")
        let body = MistralStub.json(try #require(stub.requests.first).body)
        let system = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(system.contains("title in German"))
    }

    /// Mistral's strict mode: every property of every object, nested ones included, is in
    /// `required`, and every object has `additionalProperties: false`. #16 and #11 add their
    /// parts to `ClassificationRequest`; this test covers them too.
    @Test func requestSchemaIsStrictEverywhere() throws {
        let request = ClassificationRequest(correspondents: ["Telekom"], documentTypes: ["Rechnung"],
                                            tags: ["Auto", "Auto › Golf"])
        var nested = ClassificationRequest.Part(property: "nested", schema: [
            "type": "array",
            "items": [
                "type": "object",
                "properties": ["label": ["type": "string"], "value": ["type": ["string", "null"]]],
                "required": ["label", "value"],
                "additionalProperties": false,
            ],
        ], rule: "test")
        let strict = ClassificationRequest(parts: request.parts + [nested])
        var objects = 0
        #expect(Self.strictnessProblems(in: strict.schema, path: "root", objects: &objects).isEmpty)
        #expect(objects == 2)
        #expect(strict.schema["required"] as? [String] == ["title", "correspondent", "document_type", "tags", "date", "nested"])

        // The check itself finds a missing `required` entry and a missing `additionalProperties`.
        nested.schema = ["type": "object", "properties": ["label": ["type": "string"]], "required": [String]()]
        let loose = ClassificationRequest(parts: request.parts + [nested])
        #expect(Self.strictnessProblems(in: loose.schema, path: "root", objects: &objects).count == 2)
    }

    /// Problems in a JSON schema for Mistral's strict mode, with their paths.
    private static func strictnessProblems(in schema: Any, path: String, objects: inout Int) -> [String] {
        guard let schema = schema as? [String: Any] else { return [] }
        var problems: [String] = []
        let types = (schema["type"] as? [String]) ?? [schema["type"] as? String].compactMap { $0 }
        if types.contains("object") {
            objects += 1
            let properties = schema["properties"] as? [String: Any] ?? [:]
            if Set(schema["required"] as? [String] ?? []) != Set(properties.keys) { problems.append("\(path): required") }
            if schema["additionalProperties"] as? Bool != false { problems.append("\(path): additionalProperties") }
            for (key, value) in properties {
                problems += strictnessProblems(in: value, path: "\(path).\(key)", objects: &objects)
            }
        }
        if let items = schema["items"] {
            problems += strictnessProblems(in: items, path: "\(path)[]", objects: &objects)
        }
        return problems
    }

    @Test func appLanguageNameIsEnglishWord() {
        #expect(["English", "German"].contains(MistralClient.appLanguageName))
    }

    @Test func classificationWithoutTypesOrTagsHasNoEnums() async throws {
        let (client, stub) = stubbedClient { _, _ in
            .chat(["title": "T", "correspondent": NSNull(), "document_type": NSNull(), "tags": [], "date": NSNull()])
        }
        _ = try await client.classify(text: "Text", fileName: "", correspondents: [], documentTypes: [], tags: [])

        let body = MistralStub.json(try #require(stub.requests.first).body)
        let schema = ((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        #expect((properties?["document_type"] as? [String: Any])?["enum"] == nil)
        #expect(((properties?["tags"] as? [String: Any])?["items"] as? [String: Any])?["enum"] == nil)
    }

    @Test func classificationTruncatesLongDocuments() async throws {
        let (client, stub) = stubbedClient { _, _ in
            .chat(["title": "T", "correspondent": NSNull(), "document_type": NSNull(), "tags": [], "date": NSNull()])
        }
        _ = try await client.classify(text: String(repeating: "x", count: 50_000), fileName: "",
                                      correspondents: [], documentTypes: [], tags: [])
        let body = MistralStub.json(try #require(stub.requests.first).body)
        let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        #expect(user.count < 17_000)
    }

    @Test func classificationRejectsInvalidJSON() async throws {
        let (client, _) = stubbedClient { _, _ in
            .json(["choices": [["message": ["content": "not json"]]]])
        }
        await #expect(throws: MistralError.self) {
            _ = try await client.classify(text: "", fileName: "", correspondents: [], documentTypes: [], tags: [])
        }
    }

    @Test func invalidDateIsIgnored() throws {
        let json = Data(#"{"title":"T","correspondent":null,"document_type":null,"tags":[],"date":"03.10.2026"}"#.utf8)
        let suggestion = try JSONDecoder().decode(MistralClient.Suggestion.self, from: json)
        #expect(suggestion.parsedDate == nil)
    }

    // MARK: Errors

    @Test(arguments: [401, 403, 429, 500])
    func httpErrorsKeepStatusAndMessage(status: Int) async throws {
        let (client, _) = stubbedClient { _, _ in .json(["message": "Nope"], status: status) }
        do {
            _ = try await client.ocr(pdfData: Data())
            Issue.record("expected an error")
        } catch let MistralError.http(code, message) {
            #expect(code == status)
            #expect(message == "Nope")
        }
        #expect(MistralError.http(status, "Nope").errorDescription?.contains("\(status)") == true
                || status == 429)
    }

    // MARK: Connection test

    @Test func connectionTestReportsMissingModels() async throws {
        let (client, stub) = stubbedClient { _, _ in .json(["data": [["id": MistralConfig.defaultOCRModel]]]) }
        let result = try await client.testConnection()
        #expect(result.missingModels == [MistralConfig.defaultChatModel])
        #expect(!result.isComplete)
        #expect(result.message.contains(MistralConfig.defaultChatModel))
        #expect(stub.requests.first?.request.url?.path == "/v1/models")
    }

    @Test func connectionTestSucceedsWithBothModels() async throws {
        let (client, _) = stubbedClient { _, _ in
            .json(["data": [["id": MistralConfig.defaultOCRModel], ["id": MistralConfig.defaultChatModel]]])
        }
        let result = try await client.testConnection()
        #expect(result.isComplete)
        #expect(!result.message.contains(MistralConfig.defaultChatModel))
    }

    // MARK: Key handling

    @Test(arguments: [
        "  abc123  ", "\nabc123\n", "Bearer abc123", "\"abc123\"", "„abc123“", "‚abc123‘", "«abc123»",
        "abc\u{200B}123", "abc 123",
    ])
    func sanitizeRemovesPastedExtras(raw: String) {
        #expect(MistralConfig.sanitize(raw) == "abc123")
    }

    @Test func fingerprintHidesTheMiddle() {
        let key = "AbCdEFGHIJKLMNOPQRSTUVWXYZ12wXyZ"
        #expect(MistralConfig.fingerprint(key).hasPrefix("AbCd…wXyZ"))
        #expect(!MistralConfig.fingerprint(key).contains("EFGH"))
    }
}
