import Foundation

/// Einstellungen für die Mistral-Anbindung. Der API-Schlüssel liegt im Schlüsselbund,
/// alles andere in den UserDefaults (pro Gerät).
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

    /// Entfernt beim Einfügen versehentlich mitkopierte Zeichen: Leerzeichen, Zeilenumbrüche,
    /// unsichtbare Zeichen, Anführungszeichen und ein vorangestelltes „Bearer “.
    static func sanitize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") { key = String(key.dropFirst(7)) }
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00A0}\"'“”„‘’‚«»")
            .union(.whitespacesAndNewlines)
        return String(key.unicodeScalars.filter { !invisible.contains($0) })
    }

    /// Unkritische Kurzform zur Kontrolle, z. B. „AbCd…wXyZ (32 Zeichen)“.
    static func fingerprint(_ key: String) -> String {
        guard key.count > 8 else { return "\(key.count) Zeichen" }
        return "\(key.prefix(4))…\(key.suffix(4)) (\(key.count) Zeichen)"
    }

    /// Source of the current configuration; tests replace it with a stub.
    nonisolated(unsafe) static var provider: () -> MistralConfig? = { TestEnvironment.isRunningTests ? nil : live() }

    /// `nil`, wenn kein API-Schlüssel hinterlegt ist.
    static func current() -> MistralConfig? { provider() }

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
            "Mistral lehnt den API-Schlüssel ab (401\(message.isEmpty ? "" : ": \(message)")). Neue Schlüssel sind oft erst nach einigen Minuten aktiv; außerdem muss im Mistral-Workspace ein Tarif aktiviert sein."
        case .http(403, let message):
            "Mistral verweigert den Zugriff (403\(message.isEmpty ? "" : ": \(message)")). Ist das Modell in deinem Tarif enthalten?"
        case .http(429, _): "Mistral: Zu viele Anfragen oder Kontingent aufgebraucht."
        case .http(let code, let message): "Mistral-Fehler \(code): \(message)"
        case .invalidResponse: "Mistral: Unerwartete Antwort."
        case .network(let message): "Mistral nicht erreichbar: \(message)"
        }
    }
}

/// Zugriff auf die Mistral-API: Mistral OCR für die Texterkennung und
/// ein Chat-Modell (Standard: Mistral Medium) für die Zuordnung per strukturierter JSON-Antwort.
struct MistralClient: Sendable {
    /// Session for all requests; tests replace it with one that uses a `URLProtocol` stub.
    nonisolated(unsafe) static var session: URLSession = .shared

    let config: MistralConfig
    private let baseURL = URL(string: "https://api.mistral.ai/v1/")!

    // MARK: OCR

    /// Liest den Text eines PDFs als Markdown (Tabellen bleiben dabei als Tabellen erhalten).
    func ocr(pdfData: Data) async throws -> String {
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
        // Platzhalter für eingebettete Bilder entfernen, z. B. ![img-0.jpeg](img-0.jpeg)
        return markdown
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Klassifizierung

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

    func classify(text: String, fileName: String, correspondents: [String], documentTypes: [String], tags: [String]) async throws -> Suggestion {
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        var typeSchema = nullableString
        if !documentTypes.isEmpty { typeSchema["enum"] = documentTypes + [NSNull()] }
        var tagItems: [String: Any] = ["type": "string"]
        if !tags.isEmpty { tagItems["enum"] = tags }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "correspondent": nullableString,
                "document_type": typeSchema,
                "tags": ["type": "array", "items": tagItems],
                "date": nullableString,
            ],
            "required": ["title", "correspondent", "document_type", "tags", "date"],
            "additionalProperties": false,
        ]

        let system = """
        Du bist ein Assistent für ein persönliches Dokumentenarchiv (ähnlich paperless-ngx). \
        Analysiere das Dokument und antworte ausschließlich mit JSON nach dem Schema.
        Regeln:
        - title: kurzer, aussagekräftiger deutscher Titel (max. 60 Zeichen) ohne Datum und ohne Absendernamen, \
        z. B. „Rechnung Max-Abo“, „Stromabschlag September“, „Kfz-Versicherung Beitragsrechnung“.
        - correspondent: Absender bzw. Aussteller des Dokuments (nicht der Empfänger). Wenn er einem vorhandenen \
        Korrespondenten entspricht, exakt dessen Namen verwenden; sonst den offiziellen Firmen- oder Behördennamen. null, wenn unklar.
        - document_type: genau einer der vorhandenen Dokumenttypen oder null, wenn keiner passt.
        - tags: nur passende vorhandene Tags, sonst leere Liste.
        - date: Ausstellungsdatum des Dokuments im Format YYYY-MM-DD (nicht Fälligkeits- oder Leistungsdatum), null wenn keins erkennbar.
        """

        let user = """
        Vorhandene Korrespondenten: \(correspondents.isEmpty ? "(keine)" : correspondents.joined(separator: "; "))
        Vorhandene Dokumenttypen: \(documentTypes.isEmpty ? "(keine)" : documentTypes.joined(separator: "; "))
        Vorhandene Tags: \(tags.isEmpty ? "(keine)" : tags.joined(separator: "; "))
        Dateiname: \(fileName)

        Dokumenttext:
        \(String(text.prefix(16000)))
        """

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

    // MARK: Verbindungstest

    /// Prüft den API-Schlüssel und ob die eingestellten Modelle verfügbar sind.
    func testConnection() async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let json = try await send(request)
        let ids = Set((json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let missing = [config.ocrModel, config.chatModel].filter { !ids.isEmpty && !ids.contains($0) }
        if missing.isEmpty { return "Verbindung erfolgreich." }
        return "Verbunden, aber Modell nicht gefunden: \(missing.joined(separator: ", "))"
    }

    // MARK: HTTP

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw MistralError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
