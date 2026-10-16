import Foundation
import Testing
@testable import DocumentArchive

/// The Mistral stub routes each request by its fake API key, so stub sessions used by tests
/// running in parallel never see each other's requests (#44).
@Suite struct MistralStubTests {
    @Test func parallelSessionsKeepTheirRequestsApart() async throws {
        let stubs = ["A", "B"].map { name in
            MistralStub.install { _, _ in .json(["pages": [["index": 0, "markdown": "Text \(name)"]]]) }
        }
        stubs[0].delay = 0.05
        #expect(stubs[0].config.apiKey != stubs[1].config.apiKey)
        #expect(stubs.allSatisfy { $0.config.apiKey.hasPrefix("stub-") })

        let texts = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for (index, stub) in stubs.enumerated() {
                group.addTask {
                    let client = MistralClient(config: stub.config, environment: stub.environment)
                    var texts: [String] = []
                    for request in 0..<3 {
                        texts.append(try await client.ocr(pdfData: Data("\(index)-\(request)".utf8)))
                    }
                    return (index, texts)
                }
            }
            var results: [Int: [String]] = [:]
            for try await (index, texts) in group { results[index] = texts }
            return results
        }

        #expect(texts[0] == Array(repeating: "Text A", count: 3))
        #expect(texts[1] == Array(repeating: "Text B", count: 3))
        for (index, stub) in stubs.enumerated() {
            #expect(stub.requests.count == 3)
            let documents = stub.requests.compactMap {
                (MistralStub.json($0.body)["document"] as? [String: Any])?["document_url"] as? String
            }
            let expected = (0..<3).map { "data:application/pdf;base64," + Data("\(index)-\($0)".utf8).base64EncodedString() }
            #expect(documents.sorted() == expected.sorted(), "stub \(index) recorded only its own requests")
            #expect(stub.requests.allSatisfy {
                $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(stub.config.apiKey)"
            })
        }
    }

    /// A request is only answered by the stub session whose key it carries; an unknown or missing
    /// key finds none (the stub then records an issue and fails the request).
    @Test func requestsAreRoutedByTheirKeyOnly() throws {
        let stub = MistralStub.install { _, _ in .json([:]) }
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/models")!)
        #expect(MistralStub.route(for: request) == nil, "no Authorization header")

        request.setValue("Bearer stub-unknown", forHTTPHeaderField: "Authorization")
        #expect(MistralStub.route(for: request) == nil)

        request.setValue(stub.config.apiKey, forHTTPHeaderField: "Authorization")
        #expect(MistralStub.route(for: request) == nil, "the key without \"Bearer \"")

        request.setValue("Bearer \(stub.config.apiKey)", forHTTPHeaderField: "Authorization")
        let route = try #require(MistralStub.route(for: request))
        #expect(route === stub.route)
        #expect(stub.requests.isEmpty, "looking up a route records nothing")
    }
}
