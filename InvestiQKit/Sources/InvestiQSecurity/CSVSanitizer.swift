import Foundation
import InvestiQCore

/// Protects exported CSV files against formula injection (OWASP "CSV Injection"; THREAT_MODEL T12).
public enum CSVSanitizer {
    static let dangerousPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Escapes one cell: neutralises formulas (prefix `'`) unless the cell is a plain number,
    /// then applies RFC 4180 quoting.
    public static func cell(_ value: String) -> String {
        var text = value
        if let first = text.first, dangerousPrefixes.contains(first), DecimalSupport.parse(text) == nil {
            text = "'" + text
        }
        let needsQuoting = text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" })
            || text.hasPrefix(" ") || text.hasSuffix(" ")
        if needsQuoting {
            text = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    public static func row(_ cells: [String]) -> String {
        cells.map(cell).joined(separator: ",")
    }
}
