import Foundation

public enum LinkWarning: String, Sendable, CaseIterable, Hashable {
    case insecureHTTP
    case internationalizedDomain
    case mixedScripts
    case possibleLookalike
    case ipAddressHost
    case credentialsInURL
    case nonStandardPort
}

public enum LinkRejection: Error, Equatable, Sendable {
    case malformed
    case unsupportedScheme(String)
    case missingHost
}

/// The result of inspecting an external link before showing the confirmation dialog
/// (spec §26: "display the actual destination domain").
public struct LinkInspection: Equatable, Sendable {
    public let url: URL
    public let scheme: String
    /// Host as transmitted on the wire (ASCII / punycode).
    public let asciiHost: String
    /// Host decoded for display (Unicode). Shown together with `asciiHost` when they differ.
    public let displayHost: String
    public let warnings: [LinkWarning]
}

public enum LinkSafety {
    static let allowedSchemes: Set<String> = ["https", "http"]

    public static func inspect(_ text: String) -> Result<LinkInspection, LinkRejection> {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .failure(.malformed) }
        return inspect(url)
    }

    public static func inspect(_ url: URL) -> Result<LinkInspection, LinkRejection> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return .failure(.malformed) }
        guard allowedSchemes.contains(scheme) else { return .failure(.unsupportedScheme(scheme)) }
        // `encodedHost` is the on-the-wire (IDNA/punycode) form; `host` may already be decoded.
        guard let rawHost = components.encodedHost ?? components.host, !rawHost.isEmpty else { return .failure(.missingHost) }
        let asciiHost = rawHost.lowercased()

        var warnings: [LinkWarning] = []
        if scheme == "http" { warnings.append(.insecureHTTP) }
        if components.user != nil || components.password != nil { warnings.append(.credentialsInURL) }
        if let port = components.port, port != 443, port != 80 { warnings.append(.nonStandardPort) }
        if isIPAddress(asciiHost) { warnings.append(.ipAddressHost) }

        var displayLabels: [String] = []
        var sawIDN = false
        for label in asciiHost.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            if label.hasPrefix("xn--"), let decoded = Punycode.decode(String(label.dropFirst(4))) {
                sawIDN = true
                displayLabels.append(decoded)
                let scripts = Script.scripts(in: decoded)
                if scripts.count > 1 { warnings.append(.mixedScripts) }
                if Script.looksLikeLatin(decoded) { warnings.append(.possibleLookalike) }
            } else {
                // Non-ASCII hosts that were not punycode-encoded are also IDNs.
                if label.unicodeScalars.contains(where: { !$0.isASCII }) {
                    sawIDN = true
                    if Script.scripts(in: label).count > 1 { warnings.append(.mixedScripts) }
                    if Script.looksLikeLatin(label) { warnings.append(.possibleLookalike) }
                }
                displayLabels.append(label)
            }
        }
        if sawIDN { warnings.insert(.internationalizedDomain, at: 0) }
        var unique: [LinkWarning] = []
        for warning in warnings where !unique.contains(warning) { unique.append(warning) }
        return .success(LinkInspection(url: url, scheme: scheme, asciiHost: asciiHost,
                                       displayHost: displayLabels.joined(separator: "."), warnings: unique))
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.contains(":") { return true } // IPv6 literal
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

/// RFC 3492 Punycode decoder (used only to *display* IDN hosts; not security-critical on its own).
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    static func decode(_ input: String) -> String? {
        let scalars = Array(input.unicodeScalars)
        guard scalars.allSatisfy({ $0.isASCII }) else { return nil }
        var output: [UnicodeScalar] = []
        let delimiterIndex = scalars.lastIndex(of: "-")
        if let delimiterIndex { output = Array(scalars[..<delimiterIndex]) }
        var position = delimiterIndex.map { $0 + 1 } ?? 0
        var n = initialN, i = 0, bias = initialBias
        while position < scalars.count {
            let oldI = i
            var weight = 1
            var k = base
            while true {
                guard position < scalars.count, let digit = digitValue(scalars[position]) else { return nil }
                position += 1
                let (product, overflow1) = digit.multipliedReportingOverflow(by: weight)
                let (sum, overflow2) = i.addingReportingOverflow(product)
                guard !overflow1, !overflow2 else { return nil }
                i = sum
                let threshold = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < threshold { break }
                let (newWeight, overflow3) = weight.multipliedReportingOverflow(by: base - threshold)
                guard !overflow3 else { return nil }
                weight = newWeight
                k += base
            }
            let count = output.count + 1
            bias = adapt(delta: i - oldI, numPoints: count, firstTime: oldI == 0)
            n += i / count
            i %= count
            guard let scalar = UnicodeScalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func digitValue(_ scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 48...57: return Int(scalar.value) - 22 // '0'…'9' → 26…35
        case 65...90: return Int(scalar.value) - 65 // 'A'…'Z'
        case 97...122: return Int(scalar.value) - 97 // 'a'…'z'
        default: return nil
        }
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }
}

enum Script: Hashable {
    case latin, cyrillic, greek, other

    static func of(_ scalar: UnicodeScalar) -> Script? {
        switch scalar.value {
        case 0x30...0x39, 0x2D: return nil // digits and hyphen are script-neutral
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        case 0x370...0x3FF: return .greek
        case 0x400...0x52F: return .cyrillic
        default: return .other
        }
    }

    static func scripts(in label: String) -> Set<Script> {
        Set(label.unicodeScalars.compactMap(of))
    }

    /// Cyrillic/Greek letters that are visually identical to Latin ones (homograph attacks).
    private static let latinLookalikes: Set<UnicodeScalar> = Set("аеорсухіјѕԁӏһԛԝаАВЕКМНОРСТХοαрνκτΑΒΕΗΙΚΜΝΟΡΤΥΧ".unicodeScalars)

    /// True when a non-Latin label consists only of characters that look Latin.
    static func looksLikeLatin(_ label: String) -> Bool {
        let letters = label.unicodeScalars.filter { of($0) != nil }
        guard !letters.isEmpty, letters.contains(where: { of($0) != .latin }) else { return false }
        return letters.allSatisfy { of($0) == .latin || latinLookalikes.contains($0) }
    }
}
