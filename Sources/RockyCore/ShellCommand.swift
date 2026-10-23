import Foundation

/// Shell command construction and read-only recognition of older installs.
public enum ShellCommand {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Old Rocky used raw paths, or double quotes for paths containing spaces.
    /// Recognition never evaluates the command; new writes always use `quote`.
    public static func matches(_ command: String?, expected: String) -> Bool {
        guard let command else { return false }
        if command == expected { return true }
        guard let (path, suffix) = firstWord(in: expected) else { return false }
        let legacy = path.contains(" ") ? "\"\(path)\"" : path
        return command == legacy + suffix
    }

    public static func startsWithBinary(_ command: String, path: String) -> Bool {
        let legacy = path.contains(" ") ? "\"\(path)\"" : path
        return [quote(path), legacy, path].contains { spelling in
            command == spelling || command.hasPrefix(spelling + " ")
        }
    }

    /// Decode just the executable word, without substitutions or execution.
    static func firstWord(in command: String) -> (String, String)? {
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for index in command.indices {
            let character = command[index]
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if started { return (word, String(command[index...])) }
                continue
            } else {
                word.append(character)
            }
            started = true
        }
        guard started, quote == nil, !escaped else { return nil }
        return (word, "")
    }
}
