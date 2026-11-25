import Foundation

public enum PasswordIssue: String, Sendable, CaseIterable, Hashable {
    case tooShort
    case repeatedCharacter
    case commonPassword
    case confirmationMismatch
    case surroundingWhitespace
}

public enum PasswordStrength: Int, Sendable, Comparable, CaseIterable {
    case weak, fair, good, strong
    public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PasswordPolicy: Sendable {
    public static let minimumLength = 10

    /// A small embedded list of the most common passwords (no network lookup — privacy).
    static let commonPasswords: Set<String> = [
        "1234567890", "123456789a", "qwertyuiop", "password12", "password123", "1q2w3e4r5t", "qwerty1234",
        "iloveyou12", "0987654321", "abcdefghij", "1111111111", "passw0rd12", "heslo12345", "parol12345",
        "qwertzuiop", "admin12345", "welcome123", "letmein123", "investiq123", "zaq12wsxcde",
    ]

    public init() {}

    public func issues(password: String, confirmation: String) -> [PasswordIssue] {
        var result: [PasswordIssue] = []
        if password.count < Self.minimumLength { result.append(.tooShort) }
        if let first = password.first, password.allSatisfy({ $0 == first }) { result.append(.repeatedCharacter) }
        if Self.commonPasswords.contains(password.lowercased()) { result.append(.commonPassword) }
        if password != password.trimmingCharacters(in: .whitespacesAndNewlines) { result.append(.surroundingWhitespace) }
        if password != confirmation { result.append(.confirmationMismatch) }
        return result
    }

    /// Advisory strength estimate based on length and character variety.
    public func strength(of password: String) -> PasswordStrength {
        let classes = [
            password.contains(where: { $0.isLowercase }),
            password.contains(where: { $0.isUppercase }),
            password.contains(where: { $0.isNumber }),
            password.contains(where: { !$0.isLetter && !$0.isNumber }),
        ].filter { $0 }.count
        let length = password.count
        if length < Self.minimumLength || Self.commonPasswords.contains(password.lowercased()) { return .weak }
        if length >= 16 && classes >= 3 { return .strong }
        if length >= 12 && classes >= 2 || length >= 20 { return .good }
        return .fair
    }
}
