import Foundation

/// Removes secrets from URLs and headers before they are logged, cached as keys, or displayed
/// (docs/SECURITY.md §5).
public enum Redactor {
    static let sensitiveNames: Set<String> = [
        "apikey", "api_key", "api-key", "token", "access_token", "key", "secret", "password", "auth",
        "authorization", "signature", "x-api-key", "x-finnhub-token", "x-goog-api-key",
    ]
    public static let placeholder = "REDACTED"

    public static func isSensitive(_ name: String) -> Bool { sensitiveNames.contains(name.lowercased()) }

    public static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<invalid-url>" }
        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.map { item in
            isSensitive(item.name) ? URLQueryItem(name: item.name, value: placeholder) : item
        }
        return components.string ?? "<invalid-url>"
    }

    public static func redact(headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers { result[name] = isSensitive(name) ? placeholder : value }
        return result
    }
}
