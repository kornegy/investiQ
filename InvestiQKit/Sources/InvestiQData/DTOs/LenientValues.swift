import Foundation
import InvestiQCore

/// A number that providers may send as JSON number, numeric string, or a sentinel for "missing"
/// ("None", "-", ".", "", "N/A", null, NaN). Missing is `nil` — never zero (spec §13).
struct LenientDecimal: Decodable, Sendable, Hashable {
    let value: Decimal?

    static let missingSentinels: Set<String> = ["", "none", "-", ".", "n/a", "na", "nan", "null", "--"]

    init(_ value: Decimal?) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil; return }
        if let text = try? container.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            value = Self.missingSentinels.contains(trimmed.lowercased()) ? nil : DecimalSupport.parse(trimmed)
            return
        }
        if let number = try? container.decode(Double.self) {
            value = Decimal(finite: number)
            return
        }
        value = nil
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional lenient decimal; absent keys and sentinels become `nil`.
    func lenientDecimal(_ key: Key) -> Decimal? {
        (try? decodeIfPresent(LenientDecimal.self, forKey: key))??.value
    }

    func lenientString(_ key: Key) -> String? {
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return LenientDecimal.missingSentinels.contains(trimmed.lowercased()) ? nil : trimmed
    }
}

/// Coding key for dynamic/odd keys such as Alpha Vantage's `"05. price"`.
struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum JSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderFailure.invalidResponse("unexpected JSON structure for \(T.self)")
        }
    }

    /// Detects an HTML error page delivered with HTTP 200 (common with CDNs/captive portals).
    static func rejectNonJSON(_ data: Data) throws {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) else {
            throw ProviderFailure.invalidResponse("empty body")
        }
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else {
            throw ProviderFailure.invalidResponse("not JSON")
        }
    }
}

extension URLComponents {
    static func make(_ base: String, path: String = "", query: [String: String?]) throws -> URL {
        guard var components = URLComponents(string: base + path) else { throw ProviderFailure.misconfigured("bad URL") }
        components.queryItems = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        guard let url = components.url, url.scheme == "https" else { throw ProviderFailure.misconfigured("bad URL") }
        return url
    }
}
