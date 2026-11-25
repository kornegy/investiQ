import Foundation

/// Input-side protection for AI requests (docs/SECURITY.md §AI, THREAT_MODEL T-AI). External text is
/// always data: control characters are removed, length is capped, our data delimiters cannot be forged,
/// instruction-like phrases are detected, and secrets never leave the app.
public enum PromptGuard {
    public static let untrustedOpen = "<untrusted_data>"
    public static let untrustedClose = "</untrusted_data>"
    public static let dataOpen = "<data>"
    public static let dataClose = "</data>"

    /// Phrases typical of prompt injection (EN/RU/CS), matched case-insensitively.
    static let injectionPatterns = [
        "ignore previous", "ignore all previous", "ignore the above", "disregard previous", "disregard the above",
        "forget your instructions", "new instructions", "system prompt", "you are now", "act as", "developer mode",
        "jailbreak", "reveal your", "print your instructions", "do anything now", "override",
        "игнорируй", "забудь инструкции", "системный промпт", "ты теперь",
        "ignoruj", "zapomeň instrukce", "systémový prompt", "nyní jsi",
    ]

    /// Removes control characters (keeps line breaks), our delimiter tags and excess whitespace; caps length.
    public static func sanitize(_ text: String, limit: Int) -> String {
        var cleaned = String(text.unicodeScalars.filter { scalar in
            scalar == "\n" || !(CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar))
        })
        for tag in [untrustedOpen, untrustedClose, dataOpen, dataClose, "<untrusted_data", "</untrusted_data", "<data", "</data"] {
            cleaned = cleaned.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    public static func injectionSignals(_ text: String) -> [String] {
        let lowered = text.lowercased()
        return injectionPatterns.filter { lowered.contains($0) }
    }

    /// Wraps external text so the model is told it is data, not instructions.
    public static func untrusted(_ text: String, limit: Int) -> String {
        untrustedOpen + "\n" + sanitize(text, limit: limit) + "\n" + untrustedClose
    }

    /// True when the outgoing prompt contains a stored secret or anything that looks like a credential.
    public static func containsSecret(_ prompt: String, knownSecrets: [String]) -> Bool {
        for secret in knownSecrets where secret.count >= 8 && prompt.contains(secret) { return true }
        let patterns = ["sk-ant-[A-Za-z0-9_-]{8,}", "sk-[A-Za-z0-9]{20,}", "-----BEGIN [A-Z ]*PRIVATE KEY-----", "(?i)password\\s*[:=]",
                        "(?i)api[_-]?key\\s*[:=]\\s*\\S{8,}"]
        return patterns.contains { prompt.range(of: $0, options: .regularExpression) != nil }
    }
}
