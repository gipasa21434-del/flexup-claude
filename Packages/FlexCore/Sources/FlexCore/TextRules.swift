import Foundation

// MARK: - Hashtags

public enum HashtagParser {
    public static let maxTagsPerVideo = 10
    public static let maxTagLength = 40

    /// Lower-cases a tag and strips a leading `#`. Supports Cyrillic and other Unicode letters.
    public static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        return String(t.lowercased().prefix(maxTagLength))
    }

    /// Extracts unique hashtags in order of appearance: "#Тренд и #dance_2026!" -> ["тренд", "dance_2026"].
    public static func extract(from text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var current: String?
        func flush() {
            if let c = current, !c.isEmpty {
                let n = normalize(c)
                if !n.isEmpty, !seen.contains(n), result.count < maxTagsPerVideo {
                    seen.insert(n); result.append(n)
                }
            }
            current = nil
        }
        for ch in text {
            if ch == "#" {
                flush()
                current = ""
            } else if current != nil {
                if ch.isLetter || ch.isNumber || ch == "_" {
                    current!.append(ch)
                } else {
                    flush()
                }
            }
        }
        flush()
        return result
    }

    /// The partially typed tag at the end of the text, used for autocomplete ("hello #tre" -> "tre").
    public static func trailingPartialTag(in text: String) -> String? {
        guard let hashIndex = text.lastIndex(of: "#") else { return nil }
        let tail = text[text.index(after: hashIndex)...]
        guard tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return String(tail).lowercased()
    }
}

// MARK: - Validation

public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyEmail, invalidEmail
    case shortPassword, weakPassword, passwordsDoNotMatch
    case usernameLength, usernameCharacters, usernameReserved
    case displayNameLength
    case textTooLong(limit: Int)
    case emptyText

    public var errorDescription: String? {
        switch self {
        case .emptyEmail: return "Введи email"
        case .invalidEmail: return "Похоже, в email ошибка"
        case .shortPassword: return "Пароль должен быть не короче \(Validator.minPasswordLength) символов"
        case .weakPassword: return "Добавь в пароль хотя бы одну букву и одну цифру"
        case .passwordsDoNotMatch: return "Пароли не совпадают"
        case .usernameLength: return "Никнейм — от 3 до 24 символов"
        case .usernameCharacters: return "Только латиница, цифры, «_» и «.»"
        case .usernameReserved: return "Этот никнейм зарезервирован"
        case .displayNameLength: return "Имя — от 1 до 40 символов"
        case let .textTooLong(limit): return "Слишком длинно: максимум \(limit) символов"
        case .emptyText: return "Текст не может быть пустым"
        }
    }
}

public enum Validator {
    public static let minPasswordLength = 8
    public static let captionLimit = 300
    public static let commentLimit = 500
    public static let bioLimit = 160
    static let reservedUsernames: Set<String> = ["admin", "flexup", "support", "moderator", "root", "system"]

    public static func email(_ value: String) -> ValidationError? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return .emptyEmail }
        let parts = v.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !v.contains(" "), !parts[1].contains("..") else { return .invalidEmail }
        return nil
    }

    public static func password(_ value: String) -> ValidationError? {
        if value.count < minPasswordLength { return .shortPassword }
        let hasLetter = value.contains { $0.isLetter }
        let hasDigit = value.contains { $0.isNumber }
        return (hasLetter && hasDigit) ? nil : .weakPassword
    }

    public static func passwordConfirmation(_ a: String, _ b: String) -> ValidationError? {
        a == b ? nil : .passwordsDoNotMatch
    }

    public static func username(_ value: String) -> ValidationError? {
        let v = value.lowercased()
        guard (3...24).contains(v.count) else { return .usernameLength }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")
        guard v.allSatisfy({ allowed.contains($0) }), !v.hasPrefix("."), !v.hasSuffix(".") else {
            return .usernameCharacters
        }
        if reservedUsernames.contains(v) { return .usernameReserved }
        return nil
    }

    public static func displayName(_ value: String) -> ValidationError? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(v.count) ? nil : .displayNameLength
    }

    public static func text(_ value: String, limit: Int, allowEmpty: Bool = false) -> ValidationError? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty && !allowEmpty { return .emptyText }
        return v.count > limit ? .textTooLong(limit: limit) : nil
    }
}

// MARK: - Formatting

public enum CountFormatter {
    /// 950 -> "950", 1_250 -> "1,2 тыс.", 3_400_000 -> "3,4 млн"
    public static func short(_ value: Int) -> String {
        let v = Double(value)
        func fmt(_ x: Double) -> String {
            let rounded = (x * 10).rounded(.down) / 10
            let s = rounded.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return s.replacingOccurrences(of: ".", with: ",")
        }
        switch abs(value) {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return "\(fmt(v / 1_000)) тыс."
        case ..<1_000_000_000: return "\(fmt(v / 1_000_000)) млн"
        default: return "\(fmt(v / 1_000_000_000)) млрд"
        }
    }
}

public enum RelativeTime {
    public static func short(from date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "сейчас"
        case ..<3600: return "\(s / 60) мин"
        case ..<86_400: return "\(s / 3600) ч"
        case ..<(7 * 86_400): return "\(s / 86_400) д"
        default: return "\(s / (7 * 86_400)) нед"
        }
    }
}
