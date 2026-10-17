import Foundation
import os

/// Settings for the Mistral connection. The API key lives in the Keychain,
/// everything else in UserDefaults (per device).
struct MistralConfig: Sendable {
    static let apiKeyAccount = "mistral-api-key"
    static let useOCRKey = "mistralUseOCR"
    static let useLLMKey = "mistralUseLLM"
    static let ocrModelKey = "mistralOCRModel"
    static let chatModelKey = "mistralChatModel"
    static let defaultOCRModel = "mistral-ocr-latest"
    static let defaultChatModel = "mistral-medium-latest"

    var apiKey: String
    var ocrModel: String
    var chatModel: String
    var useOCR: Bool
    var useLLM: Bool

    /// Removes characters pasted by accident: spaces, line breaks, invisible characters,
    /// quotation marks and a leading "Bearer ".
    static func sanitize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") { key = String(key.dropFirst(7)) }
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00A0}\"'“”„‘’‚«»")
            .union(.whitespacesAndNewlines)
        return String(key.unicodeScalars.filter { !invisible.contains($0) })
    }

    /// A short form that is safe to show, e.g. "AbCd…wXyZ (32 characters)".
    static func fingerprint(_ key: String) -> String {
        guard key.count > 8 else { return String(localized: "\(key.count) characters") }
        return String(localized: "\(String(key.prefix(4)))…\(String(key.suffix(4))) (\(key.count) characters)")
    }

    /// The configuration of `ProcessingEnvironment.current`; `nil` when no API key is stored.
    /// Unit and UI test runs never use the stored key.
    static func current() -> MistralConfig? { ProcessingEnvironment.current.mistralConfig() }

    /// Reads the key from the Keychain and the switches from the given defaults.
    static func live(defaults: UserDefaults = .standard) -> MistralConfig? {
        guard let key = KeychainStore.read(apiKeyAccount).map(sanitize), !key.isEmpty else { return nil }
        func string(_ name: String, _ fallback: String) -> String {
            let value = defaults.string(forKey: name)?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? fallback : value
        }
        return MistralConfig(
            apiKey: key,
            ocrModel: string(ocrModelKey, defaultOCRModel),
            chatModel: string(chatModelKey, defaultChatModel),
            useOCR: defaults.object(forKey: useOCRKey) as? Bool ?? true,
            useLLM: defaults.object(forKey: useLLMKey) as? Bool ?? true
        )
    }
}

enum MistralError: LocalizedError {
    case http(Int, String)
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(401, let message):
            String(localized: "Mistral rejects the API key (401\(message.isEmpty ? "" : ": \(message)")). New keys often only work after a few minutes, and the Mistral workspace needs an active plan.")
        case .http(403, let message):
            String(localized: "Mistral denies access (403\(message.isEmpty ? "" : ": \(message)")). Is the model included in your plan?")
        case .http(429, _): String(localized: "Mistral: too many requests, or the quota is used up.")
        case .http(let code, let message): String(localized: "Mistral error \(code): \(message)")
        case .invalidResponse: String(localized: "Mistral: unexpected response.")
        case .network(let message): String(localized: "Mistral cannot be reached: \(message)")
        }
    }
}

/// Access to the Mistral API: Mistral OCR for text recognition, and a chat model
/// (default: Mistral Medium) for auto-assignment through a structured JSON answer.
struct MistralClient: Sendable {
    let config: MistralConfig
    /// Session for all requests; tests use one with a `URLProtocol` stub.
    private let session: URLSession
    private let encodeHook: (@Sendable (Data) -> Void)?
    private let baseURL = URL(string: "https://api.mistral.ai/v1/")!

    /// - Parameter environment: Gives the session and the test hooks. There is deliberately no
    ///   default: a default would be read where the client is created, which inside
    ///   `Task.detached` is `.live` and not the caller's environment. Pass the environment the
    ///   caller captured (`ProcessingEnvironment.current` on the caller's side).
    init(config: MistralConfig, environment: ProcessingEnvironment) {
        self.config = config
        session = environment.session
        encodeHook = environment.encodeHook
    }

    // MARK: OCR

    /// Reads the text of a PDF as Markdown (tables stay tables).
    func ocr(pdfData: Data) async throws -> String {
        encodeHook?(pdfData)
        let body: [String: Any] = [
            "model": config.ocrModel,
            "document": [
                "type": "document_url",
                "document_url": "data:application/pdf;base64," + pdfData.base64EncodedString(),
            ],
            "include_image_base64": false,
        ]
        let json = try await post("ocr", body: body, timeout: 180)
        guard let pages = json["pages"] as? [[String: Any]] else { throw MistralError.invalidResponse }
        let markdown = pages
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            .compactMap { $0["markdown"] as? String }
            .joined(separator: "\n\n")
        // Remove placeholders for embedded images, e.g. ![img-0.jpeg](img-0.jpeg)
        return markdown
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Classification

    struct Suggestion: Decodable, Sendable {
        var title: String?
        var correspondent: String?
        var documentType: String?
        var tags: [String]?
        var date: String?

        enum CodingKeys: String, CodingKey {
            case title, correspondent, tags, date
            case documentType = "document_type"
        }

        var parsedDate: Date? {
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date).map { $0.addingTimeInterval(12 * 3600) }
        }
    }

    /// The app's current language in English (e.g. "German"), so titles match the UI language.
    static var appLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    func classify(text: String, fileName: String, correspondents: [String], documentTypes: [String], tags: [String],
                  titleLanguage: String = MistralClient.appLanguageName) async throws -> Suggestion {
        try await classify(text: text, fileName: fileName, request: ClassificationRequest(
            correspondents: correspondents, documentTypes: documentTypes, tags: tags, titleLanguage: titleLanguage))
    }

    func classify(text: String, fileName: String, request: ClassificationRequest) async throws -> Suggestion {
        let schema = request.schema
        let system = request.systemPrompt
        let user = request.userMessage(text: text, fileName: fileName)

        let body: [String: Any] = [
            "model": config.chatModel,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "document_classification", "schema": schema, "strict": true],
            ],
        ]
        let json = try await post("chat/completions", body: body, timeout: 90)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let data = content.data(using: .utf8)
        else { throw MistralError.invalidResponse }
        do {
            return try JSONDecoder().decode(Suggestion.self, from: data)
        } catch {
            throw MistralError.invalidResponse
        }
    }

    // MARK: Connection test

    /// Checks the API key and whether the configured models are available.
    struct ConnectionResult: Sendable {
        /// Configured models the API key cannot use; empty when everything is available.
        var missingModels: [String]
        var isComplete: Bool { missingModels.isEmpty }

        var message: String {
            isComplete ? String(localized: "Connection successful.")
                       : String(localized: "Connected, but model not found: \(missingModels.joined(separator: ", "))")
        }
    }

    func testConnection() async throws -> ConnectionResult {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let json = try await send(request, endpoint: "models")
        let ids = Set((json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let missing = [config.ocrModel, config.chatModel].filter { !ids.isEmpty && !ids.contains($0) }
        return ConnectionResult(missingModels: missing)
    }

    // MARK: HTTP

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, endpoint: path)
    }

    /// Sends a request and logs the endpoint, status, duration and sizes (never the key, the
    /// headers or the body; see `Log`).
    /// - Parameter endpoint: the API path, e.g. `ocr`; logged as `.public`.
    private func send(_ request: URLRequest, endpoint: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        let start = ContinuousClock.now
        let sent = request.httpBody?.count ?? 0
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Log.mistral.error("\(endpoint, privacy: .public): no response after \(Log.milliseconds(since: start), privacy: .public) ms, \(sent, privacy: .public) bytes sent: \(Log.code(of: error), privacy: .public)")
            throw MistralError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `.default` is `.notice`; a failed request is an `.error`.
        Log.mistral.log(level: (200..<300).contains(status) ? .default : .error, "\(endpoint, privacy: .public): status \(status, privacy: .public), \(Log.milliseconds(since: start), privacy: .public) ms, \(sent, privacy: .public) bytes sent, \(data.count, privacy: .public) bytes received")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["message"] as? String)
                ?? ((json?["detail"] as? [[String: Any]])?.first?["msg"] as? String)
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MistralError.http(status, message)
        }
        guard let json else { throw MistralError.invalidResponse }
        return json
    }
}

/// The structured-output request of the classification, assembled from parts. Each part brings
/// its JSON schema property, its prompt rule and the context line listing what exists. Later
/// features add their parts here (#16 subjects, #11 deadlines).
///
/// Mistral's strict mode requires every property of every object to be in `required` and
/// `additionalProperties: false` on every object; the schema is built that way, and
/// `requestSchemaIsStrictEverywhere` checks it for every part, nested objects included.
struct ClassificationRequest {
    struct Part {
        /// The property name in the answer.
        var property: String
        var schema: [String: Any]
        /// One line under "Rules:" in the system prompt.
        var rule: String
        /// A line of the user message, e.g. "Existing tags: …"; `nil` for none.
        var context: String?
    }

    var parts: [Part]

    /// The standard parts: title, correspondent, document type, tags and date.
    /// - Parameter tags: the tags' display paths ("Auto › Golf"), see `TagHierarchy`.
    init(correspondents: [String], documentTypes: [String], tags: [String],
         titleLanguage: String = MistralClient.appLanguageName) {
        parts = [
            Self.title(language: titleLanguage),
            Self.correspondent(correspondents),
            Self.documentType(documentTypes),
            Self.tags(tags),
            Self.date,
        ]
    }

    init(parts: [Part]) {
        self.parts = parts
    }

    var schema: [String: Any] {
        [
            "type": "object",
            "properties": Dictionary(parts.map { ($0.property, $0.schema) }, uniquingKeysWith: { first, _ in first }),
            "required": parts.map(\.property),
            "additionalProperties": false,
        ]
    }

    var systemPrompt: String {
        """
        You are the assistant of a personal document archive (similar to paperless-ngx). \
        Analyze the document and answer only with JSON that follows the schema.
        Rules:
        \(parts.map { "- \($0.property): \($0.rule)" }.joined(separator: "\n"))
        """
    }

    func userMessage(text: String, fileName: String) -> String {
        let lines = parts.compactMap(\.context) + ["File name: \(fileName)"]
        return """
        \(lines.joined(separator: "\n"))

        Document text:
        \(String(text.prefix(16000)))
        """
    }

    // MARK: Parts

    private static let nullableString: [String: Any] = ["type": ["string", "null"]]

    private static func list(_ names: [String]) -> String {
        names.isEmpty ? "(none)" : names.joined(separator: "; ")
    }

    static func title(language: String) -> Part {
        Part(property: "title", schema: ["type": "string"],
             rule: "a short, meaningful title in \(language) (at most 60 characters), without a date and without "
                + "the sender's name, e.g. for German \"Rechnung Max-Abo\", \"Stromabschlag September\", "
                + "\"Kfz-Versicherung Beitragsrechnung\".")
    }

    static func correspondent(_ names: [String]) -> Part {
        Part(property: "correspondent", schema: nullableString,
             rule: "the sender or issuer of the document (not the recipient). If it is one of the existing "
                + "correspondents, use exactly that name; otherwise the official name of the company or authority. "
                + "null if unclear.",
             context: "Existing correspondents: \(list(names))")
    }

    static func documentType(_ names: [String]) -> Part {
        var schema = nullableString
        if !names.isEmpty { schema["enum"] = names + [NSNull()] }
        return Part(property: "document_type", schema: schema,
                    rule: "exactly one of the existing document types, or null if none fits.",
                    context: "Existing document types: \(list(names))")
    }

    /// Tags are sent as display paths; duplicates (before a merge) are sent once.
    static func tags(_ paths: [String]) -> Part {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        var items: [String: Any] = ["type": "string"]
        if !unique.isEmpty { items["enum"] = unique }
        return Part(property: "tags", schema: ["type": "array", "items": items],
                    rule: "only fitting existing tags, otherwise an empty list. Nested tags are written as paths "
                        + "(\"Parent\(TagHierarchy.separator)Child\"): choose the most specific matching tag; never "
                        + "add its parent tag as well.",
                    context: "Existing tags: \(list(unique))")
    }

    static let date = Part(property: "date", schema: nullableString,
                           rule: "the issue date of the document as YYYY-MM-DD (not a due date or service period), "
                               + "null if there is none.")
}
