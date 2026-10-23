import Foundation

/// Read-only parser for Codex's plugin table/key forms, not a TOML rewriter.
/// Quoted keys, comments and strings are lexed before interpreting booleans.
/// Unrelated values (including multiline strings) are never searched for text.
enum TOMLPluginSettings {
    static let plugin = "gitkraken-hooks@gitkraken"

    static func gitkrakenEnabled(in text: String) -> Bool {
        var table: [String] = []
        var present = false
        var enabled: Bool?
        for statement in split(text, separator: "\n") {
            let line = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") {
                table = keys(String(line.dropFirst().dropLast())) ?? []
                if table == ["plugins", plugin] { present = true }
                continue
            }
            guard let (key, value) = assignment(line), let path = keys(key) else { continue }
            let full = table + path
            if full == ["plugins", plugin, "enabled"] {
                present = true
                enabled = value == "true"
            } else if full == ["plugins", plugin], value.hasPrefix("{"), value.hasSuffix("}") {
                present = true
                for entry in split(String(value.dropFirst().dropLast()), separator: ",") {
                    if let (key, value) = assignment(entry), keys(key) == ["enabled"] {
                        enabled = value == "true"
                    }
                }
            }
        }
        return present && enabled != false
    }

    private static func assignment(_ text: String) -> (String, String)? {
        let parts = split(text, separator: "=")
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts.dropFirst().joined(separator: "=")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func keys(_ text: String) -> [String]? {
        var result: [String] = []
        for part in split(text, separator: ".") {
            let key = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("\"") {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(key.utf8))
                else { return nil }
                result.append(value)
            } else if key.hasPrefix("'"), key.hasSuffix("'"), key.count >= 2 {
                result.append(String(key.dropFirst().dropLast()))
            } else if !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                result.append(key)
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    static func isComplete(_ text: String) -> Bool {
        scan(text, separator: "\n").complete
    }

    private static func split(_ text: String, separator: Character) -> [String] {
        scan(text, separator: separator).parts
    }

    /// Separates only outside strings/containers; comments end at a newline.
    private static func scan(_ text: String, separator: Character) -> (parts: [String], complete: Bool) {
        let chars = Array(text)
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var triple = false
        var escaped = false
        var comment = false
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if comment {
                if char == "\n" {
                    comment = false
                    if separator == "\n", depth == 0 {
                        parts.append(current)
                        current = ""
                    } else { current.append(char) }
                }
                index += 1
                continue
            }
            if let open = quote {
                current.append(char)
                if escaped { escaped = false }
                else if char == "\\", open == "\"" { escaped = true }
                else if char == open {
                    if !triple { quote = nil }
                    else if index + 2 < chars.count, chars[index + 1] == open, chars[index + 2] == open {
                        current.append(open)
                        current.append(open)
                        index += 2
                        quote = nil
                        triple = false
                    }
                }
            } else if char == "#" {
                comment = true
            } else if char == "'" || char == "\"" {
                quote = char
                current.append(char)
                if index + 2 < chars.count, chars[index + 1] == char, chars[index + 2] == char {
                    triple = true
                    current.append(char)
                    current.append(char)
                    index += 2
                }
            } else if char == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                if char == "[" || char == "{" { depth += 1 }
                if char == "]" || char == "}" { depth = max(0, depth - 1) }
                current.append(char)
            }
            index += 1
        }
        parts.append(current)
        return (parts, quote == nil && depth == 0 && !escaped)
    }
}
