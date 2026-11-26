import Foundation
import InvestiQCore

/// A language-model backend. Providers get a system prompt, a user prompt and the JSON schema of the
/// expected answer, and return raw text. They have no tools: they cannot act, browse or change data.
public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    /// True when requests leave the Mac.
    var sendsDataOffDevice: Bool { get }
    func complete(system: String, prompt: String, schema: [String: any Sendable]) async throws -> String
}

/// The answer schema shared by all providers (validated again on our side).
public enum AIAnswerSchema {
    public static var jsonSchema: [String: any Sendable] {
        ["type": "object",
         "properties": ["answer": ["type": "string"] as [String: any Sendable],
                        "keyPoints": ["type": "array", "items": ["type": "string"] as [String: any Sendable]] as [String: any Sendable],
                        "caveats": ["type": "array", "items": ["type": "string"] as [String: any Sendable]] as [String: any Sendable]]
            as [String: any Sendable],
         "required": ["answer", "keyPoints", "caveats"],
         "additionalProperties": false]
    }
}

/// Claude Messages API (raw HTTPS — Swift has no official SDK). The user's own key lives in the Keychain.
/// Model default `claude-opus-5-5` (user-changeable), effort set explicitly, structured output through
/// `output_config.format`, server-side refusal fallback enabled; no tools are declared.
public struct AnthropicMessagesProvider: AIProvider {
    public static let providerID = "anthropic"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public static let defaultModel = "claude-opus-5-5"
    /// Non-streaming default from the API guidance (thinking tokens count toward it on current models).
    static let maxTokens = 16_000
    static let timeout: TimeInterval = 120

    public let kind = AIProviderKind.externalAPI
    public let sendsDataOffDevice = true
    private let client: any HTTPClient
    private let credentials: any CredentialSource
    private let model: String

    public init(client: any HTTPClient, credentials: any CredentialSource, model: String?) {
        self.client = client
        self.credentials = credentials
        let trimmed = model?.trimmingCharacters(in: .whitespaces) ?? ""
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
    }

    func requestBody(system: String, prompt: String, schema: [String: any Sendable]) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public func complete(system: String, prompt: String, schema: [String: any Sendable]) async throws -> String {
        guard let key = credentials.apiKey(for: Self.providerID), !key.isEmpty else { throw AIError.missingConfiguration }
        let request = HTTPRequest(url: Self.endpoint,
                                  headers: ["x-api-key": key, "anthropic-version": Self.apiVersion, "content-type": "application/json",
                                            "anthropic-beta": "server-side-fallback-2026-07-01"],
                                  maximumResponseBytes: 2 * 1024 * 1024, timeout: Self.timeout, method: "POST",
                                  body: try requestBody(system: system, prompt: prompt, schema: schema))
        let response: HTTPResponse
        do { response = try await client.send(request) } catch { throw AIError.transport }
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode == 401 || response.statusCode == 403 ? AIError.missingConfiguration : AIError.transport
        }
        return try Self.text(from: response.body)
    }

    /// Checks `stop_reason` before reading content; concatenates the `text` blocks only.
    static func text(from body: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw AIError.invalidResponse }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw AIError.refused }
        if stop == "max_tokens" { throw AIError.invalidResponse }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.invalidResponse }
        return text
    }
}

/// Local model through Ollama on this Mac (loopback only; nothing leaves the device).
public struct OllamaProvider: AIProvider {
    public let kind = AIProviderKind.ollama
    public let sendsDataOffDevice = false
    private let client: any HTTPClient
    private let endpoint: URL
    private let model: String
    static let timeout: TimeInterval = 180

    /// Returns nil unless the endpoint is a loopback address and a model name is set.
    public init?(client: any HTTPClient, endpoint: String, model: String?) {
        guard let url = URL(string: endpoint), HTTPRequest(url: url).usesAllowedTransport,
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host?.lowercased() ?? ""),
              let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        self.client = client
        self.endpoint = url.appendingPathComponent("api/chat")
        self.model = model
    }

    public func complete(system: String, prompt: String, schema: [String: any Sendable]) async throws -> String {
        let body: [String: Any] = ["model": model, "stream": false, "format": schema,
                                   "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        let request = HTTPRequest(url: endpoint, headers: ["content-type": "application/json"], maximumResponseBytes: 2 * 1024 * 1024,
                                  timeout: Self.timeout, method: "POST",
                                  body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        let response: HTTPResponse
        do { response = try await client.send(request) } catch { throw AIError.providerUnavailable }
        guard (200..<300).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }
        return content
    }
}
