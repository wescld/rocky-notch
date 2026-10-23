import Foundation

/// Risk of the `git` invocations inside a shell command line.
///
/// The generic classifier only matched a few substrings (`--force`,
/// `git reset --hard`), so delete pushes, `+refspec` force pushes, amends,
/// hook bypasses and working-tree discards all read as an ordinary shell
/// command. This walks the command with a small quote-aware lexer instead of
/// substring matching, so a commit message such as `-m "fix: drop :x"` or
/// `git push origin main` is never mistaken for a dangerous operation.
///
/// Tiers (`CommandRiskLevel` ranks destructive above critical):
/// - critical: force push (`--force`, `-f`, `--force-with-lease`, `+refspec`),
///   delete push (`:branch`, `-d`, `--delete`), `--mirror`, `--prune`;
///   `branch -f`; any `--force*` on a subcommand without its own tier
///   (`tag`, `fetch`, `worktree`, `rebase --force-rebase`, `lfs push`, …);
/// - destructive: `commit --amend`, `reset --hard`, `clean -f…`,
///   `branch -D` / `-d -f`, `rm -f`, `stash drop|clear`, `checkout -- <paths>|.|-f`,
///   `restore <paths>` touching the working tree;
/// - high: `--no-verify` (commit `-n` too). Plain shell already rates
///   `elevated`, so bypassing hooks has to sit one tier above it to show at all.
///
/// Dry runs (`push --dry-run|-n`, `clean -n|--dry-run`) add nothing, so they
/// stay at the plain-shell tier.
enum GitCommandRisk {

    /// The git tier plus the text of everything that is *not* a git
    /// invocation, so the generic substring rules (`--force`, `rm -rf`, …)
    /// can run without re-reading git arguments the git pass already judged —
    /// a dry run or a commit message must not be bumped back up by them.
struct Analysis: Equatable, Sendable {
    let level: CommandRiskLevel
        /// Non-git segments verbatim, plus the prefix words (`sudo`,
        /// `VAR=x`, …) of git segments, joined by ` ; `.
    let nonGitText: String
    }

static func analyze(_ command: String) -> Analysis {
        guard command.contains("git") else { return Analysis(level: .none, nonGitText: command) }
        var level = CommandRiskLevel.none
        var rest: [String] = []
        for segment in segments(of: command) {
            guard let start = commandStart(of: segment) else {
                rest.append(segment.joined(separator: " "))
                continue
            }
            if basename(segment[start]) == "git" {
                level = max(level, gitRisk(Array(segment[(start + 1)...])))
                rest.append(segment[..<start].joined(separator: " "))
            } else {
                level = max(level, risk(ofSegment: segment, start: start, depth: 0))
                rest.append(segment.joined(separator: " "))
            }
        }
        return Analysis(level: level, nonGitText: rest.joined(separator: " ; ") + " ")
    }

    private static func risk(of command: String, depth: Int) -> CommandRiskLevel {
        guard depth < 3, command.contains("git") else { return .none }
        var level = CommandRiskLevel.none
        for segment in segments(of: command) {
            guard let start = commandStart(of: segment) else { continue }
            level = max(level, risk(ofSegment: segment, start: start, depth: depth))
        }
        return level
    }

    // MARK: - Segments

    private static let wrappers: Set<String> = [
        "sudo", "env", "command", "exec", "nohup", "time", "xargs", "builtin", "nice", "timeout",
    ]
    /// Shell keywords that may precede a command in the same segment
    /// (`if x; then git push -f; fi`, `for b in …; do git push origin :$b; done`).
    private static let keywords: Set<String> = [
        "if", "then", "do", "else", "elif", "while", "until", "{", "!", "(",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    private static let wrapperOptionsWithValues: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-C", "-h", "-p", "--user", "--group", "--close-from", "--host", "--prompt"],
        "nice": ["-n", "--adjustment"],
        "xargs": ["-I", "-n", "-P", "-L", "-s", "-d", "-E", "--max-args", "--max-procs",
                  "--max-lines", "--max-chars", "--delimiter"],
        "env": ["-u", "-S", "-C", "--unset", "--split-string", "--chdir"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "exec": ["-a"],
        "time": ["-o", "-f", "--output", "--format"],
    ]

    /// Skip assignments, shell keywords and transparent wrappers. Known options
    /// consume their required value (separate or attached); timeout also consumes
    /// its duration positional before looking for the wrapped program.
    private static func commandStart(of words: [String]) -> Int? {
        var index = 0
        var wrapper: String?
        while index < words.count {
            let word = words[index]
            if isAssignment(word) || keywords.contains(word) {
                index += 1
                continue
            }
            if wrappers.contains(basename(word)) {
                wrapper = basename(word)
                index += 1
                continue
            }
            if let active = wrapper, word == "--" {
                index += active == "timeout" ? 2 : 1
                wrapper = nil
                continue
            }
            if let active = wrapper, word.hasPrefix("-") {
                let withValues = wrapperOptionsWithValues[active] ?? []
                var consumesNext = withValues.contains(word)
                if !word.hasPrefix("--") {
                    let letters = Array(word.dropFirst())
                    for (position, letter) in letters.enumerated() {
                        if withValues.contains("-" + String(letter)) {
                            consumesNext = position == letters.count - 1
                            break
                        }
                    }
                }
                index += consumesNext ? 2 : 1
                continue
            }
            if wrapper == "timeout" {
                index += 1
                wrapper = nil
                continue
            }
            break
        }
        return index < words.count ? index : nil
    }

    private static func risk(ofSegment words: [String], start index: Int, depth: Int) -> CommandRiskLevel {
        let program = basename(words[index])
        if program == "git" {
            return gitRisk(Array(words[(index + 1)...]))
        }
        // `bash -c "git push -f"` and friends: classify the inline script.
        if shells.contains(program) {
            var level = CommandRiskLevel.none
            var position = index + 1
            while position < words.count {
                let word = words[position]
                if word.hasPrefix("-"), !word.hasPrefix("--"), word.contains("c"),
                   position + 1 < words.count {
                    level = max(level, risk(of: words[position + 1], depth: depth + 1))
                    position += 2
                    continue
                }
                position += 1
            }
            return level
        }
        return .none
    }

    // MARK: - git

    private static func gitRisk(_ arguments: [String]) -> CommandRiskLevel {
        var index = 0
        // Global options before the subcommand (`git -C repo push …`).
        let globalWithValue: Set<String> = [
            "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix",
            "--config-env", "--exec-path",
        ]
        while index < arguments.count, arguments[index].hasPrefix("-") {
            index += globalWithValue.contains(arguments[index]) ? 2 : 1
        }
        guard index < arguments.count else { return .none }
        let subcommand = arguments[index]
        let rest = Array(arguments[(index + 1)...])
        switch subcommand {
        case "push": return pushRisk(rest)
        case "commit": return commitRisk(rest)
        case "reset": return resetRisk(rest)
        case "clean": return cleanRisk(rest)
        case "checkout": return checkoutRisk(rest)
        case "restore": return restoreRisk(rest)
        case "branch": return branchRisk(rest)
        case "stash": return stashRisk(rest)
        // `git rm -f` deletes files even with uncommitted changes (the old
        // `rm -rf` substring rule rated `git rm -rf` destructive too).
        case "rm": return untieredRisk(subcommand: "rm", rest, shortForce: true) == .none ? .none : .destructive
        default: return untieredRisk(subcommand: subcommand, rest)
        }
    }

    /// Subcommands whose short `-f` means `--force`. Others use `-f` for
    /// something else (`grep -f <file>`, `config -f <file>`), so they only
    /// count the long form.
    private static let shortForceSubcommands: Set<String> = [
        "add", "tag", "fetch", "pull", "switch", "worktree", "submodule", "filter-branch",
        "mv", "rebase", "notes", "replace", "checkout-index",
    ]

    /// Subcommands without a tier of their own keep the old generic rule:
    /// any force (`worktree remove --force`, `tag --force`, `fetch --force`,
    /// `rebase --force-rebase`, `lfs push --force`, …) is critical.
    private static func untieredRisk(
        subcommand: String, _ arguments: [String], shortForce: Bool = false
    ) -> CommandRiskLevel {
        let allowShort = shortForce || shortForceSubcommands.contains(subcommand)
        for argument in arguments {
            if argument == "--" { break }
            if argument == "--force" || argument.hasPrefix("--force-") || argument.hasPrefix("--force=") {
                return .critical
            }
            if allowShort, argument.count > 1, argument.hasPrefix("-"), !argument.hasPrefix("--"),
               argument.dropFirst().contains("f") {
                return .critical
            }
        }
        return .none
    }

    private static func pushRisk(_ arguments: [String]) -> CommandRiskLevel {
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["o"],
            longWithValue: ["--push-option", "--repo", "--receive-pack", "--exec"]
        )
        // `--dry-run` / `-n` only reports what would happen.
        if parsed.hasLong("--dry-run") || parsed.hasShort("n") { return .none }
        var level = CommandRiskLevel.none
        if parsed.hasLong("--no-verify") { level = max(level, .high) }
        if parsed.hasLong("--force") || parsed.hasLong("--force-with-lease")
            || parsed.hasLong("--mirror") || parsed.hasLong("--delete")
            || parsed.hasLong("--prune")
            || parsed.hasShort("f") || parsed.hasShort("d") {
            return max(level, .critical)
        }
        // Refspecs: `+src:dst` forces, `:dst` (empty source) deletes. A
        // remote name cannot start with either character, so every
        // positional can be checked (`git push :x` has no remote at all).
        // For push, post-`--` arguments are repos/refspecs, not file paths.
        if (parsed.positionals + parsed.pathspecs).contains(where: { $0.hasPrefix("+") || ($0.hasPrefix(":") && $0.count > 1) }) {
            return max(level, .critical)
        }
        return level
    }

    private static func commitRisk(_ arguments: [String]) -> CommandRiskLevel {
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["m", "F", "C", "c", "t"],
            // `-S[<keyid>]` / `-u[<mode>]`: optional value, attached only.
            shortWithInlineValue: ["S", "u"],
            longWithValue: [
                "--message", "--file", "--reuse-message", "--reedit-message", "--template",
                "--author", "--date", "--fixup", "--squash", "--trailer", "--cleanup",
            ]
        )
        if parsed.hasLong("--amend") { return .destructive }
        if parsed.hasLong("--no-verify") || parsed.hasShort("n") { return .high }
        return .none
    }

    private static func resetRisk(_ arguments: [String]) -> CommandRiskLevel {
        ParsedArguments(arguments).hasLong("--hard") ? .destructive : .none
    }

    private static func cleanRisk(_ arguments: [String]) -> CommandRiskLevel {
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["e"],
            longWithValue: ["--exclude"]
        )
        // `-n` / `--dry-run` only lists what would go, even with `-f`.
        if parsed.hasLong("--dry-run") || parsed.hasShort("n") { return .none }
        return parsed.hasLong("--force") || parsed.hasShort("f") ? .destructive : .none
    }

    private static func checkoutRisk(_ arguments: [String]) -> CommandRiskLevel {
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["b", "B"],
            longWithValue: ["--orphan", "--conflict", "--pathspec-from-file"]
        )
        if parsed.hasLong("--force") || parsed.hasShort("f") { return .destructive }
        // `git checkout -- <paths>` / `git checkout HEAD -- f` / `git checkout .`
        if !parsed.pathspecs.isEmpty || parsed.positionals.contains(".") {
            return .destructive
        }
        return .none
    }

    private static func restoreRisk(_ arguments: [String]) -> CommandRiskLevel {
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["s"],
            longWithValue: ["--source", "--pathspec-from-file", "--conflict"]
        )
        let staged = parsed.hasLong("--staged") || parsed.hasShort("S")
        let worktree = parsed.hasLong("--worktree") || parsed.hasShort("W")
        // `--staged` alone only unstages; anything else rewrites the files.
        if staged, !worktree { return .none }
        let touchesPaths = !parsed.positionals.isEmpty || !parsed.pathspecs.isEmpty
        return touchesPaths ? .destructive : .none
    }

    private static func branchRisk(_ arguments: [String]) -> CommandRiskLevel {
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["u", "t"],
            longWithValue: ["--set-upstream-to", "--track", "--sort", "--format",
                            "--contains", "--no-contains", "--merged", "--no-merged",
                            "--points-at"]
        )
        if parsed.hasShort("D") { return .destructive }
        let deletes = parsed.hasLong("--delete") || parsed.hasShort("d")
        let forced = parsed.hasLong("--force") || parsed.hasShort("f")
        if deletes && forced { return .destructive }
        // `branch -f|--force a b` resets an existing branch: commits can be lost.
        return forced ? .critical : .none
    }

    private static func stashRisk(_ arguments: [String]) -> CommandRiskLevel {
        // Option values are skipped: `git stash -m drop` names a stash "drop".
        let parsed = ParsedArguments(
            arguments,
            shortWithValue: ["m"],
            longWithValue: ["--message", "--pathspec-from-file"]
        )
        guard let action = parsed.positionals.first else { return .none }
        return action == "drop" || action == "clear" ? .destructive : .none
    }

    // MARK: - Argument parsing

    /// Splits git subcommand arguments into long options, short flags,
    /// positionals and post-`--` pathspecs. Option values (`-m "msg"`,
    /// `--author=x`, `-Sabc`) are consumed so they are never read as flags.
    private struct ParsedArguments {
        var longs: Set<String> = []
        var shorts: Set<Character> = []
        var positionals: [String] = []
        var pathspecs: [String] = []

        init(
            _ arguments: [String],
            shortWithValue: Set<Character> = [],
            shortWithInlineValue: Set<Character> = [],
            longWithValue: Set<String> = []
        ) {
            var index = 0
            var afterDoubleDash = false
            while index < arguments.count {
                let argument = arguments[index]
                index += 1
                if afterDoubleDash {
                    pathspecs.append(argument)
                    continue
                }
                if argument == "--" {
                    afterDoubleDash = true
                    continue
                }
                if argument.hasPrefix("--") {
                    if let equals = argument.firstIndex(of: "=") {
                        longs.insert(String(argument[..<equals]))
                    } else {
                        longs.insert(argument)
                        if longWithValue.contains(argument) { index += 1 }
                    }
                    continue
                }
                if argument.hasPrefix("-"), argument.count > 1 {
                    let letters = Array(argument.dropFirst())
                    for (position, letter) in letters.enumerated() {
                        shorts.insert(letter)
                        if shortWithInlineValue.contains(letter) { break }
                        if shortWithValue.contains(letter) {
                            // `-mvalue` carries it inline; `-m value` takes the next word.
                            if position == letters.count - 1 { index += 1 }
                            break
                        }
                    }
                    continue
                }
                positionals.append(argument)
            }
        }

        func hasLong(_ name: String) -> Bool { longs.contains(name) }
        func hasShort(_ letter: Character) -> Bool { shorts.contains(letter) }
    }

    // MARK: - Lexer

    /// Words of each simple command, split on `;`, `&`, `|`, `&&`, `||`,
    /// newlines and parentheses. Quotes are removed and their content kept as
    /// one word. Command substitutions — `` `…` `` and `$(…)`, quoted or not —
    /// become their own segments (appended after the others) and leave a
    /// placeholder word behind, so `` git push `echo x` -f `` keeps its `-f`.
    static func segments(of command: String) -> [[String]] {
        segments(of: Array(command), depth: 0)
    }

    private static let substitutionPlaceholder = "$(…)"

    private static func segments(of characters: [Character], depth: Int) -> [[String]] {
        var segments: [[String]] = []
        var substitutions: [[String]] = []
        var words: [String] = []
        var word = ""
        var hasWord = false
        var quote: Character?
        var escaped = false
        var index = 0

        func endWord() {
            if hasWord { words.append(word) }
            word = ""
            hasWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }
        /// Consumes a substitution body starting at `start` (just past the
        /// opener) and returns the index after its closer.
        func substitution(from start: Int, backtick: Bool) -> Int {
            var position = start
            var nesting = 0
            var innerQuote: Character?
            while position < characters.count {
                let character = characters[position]
                if character == "\\" { position += 2; continue }
                if let open = innerQuote {
                    if character == open { innerQuote = nil }
                } else if backtick {
                    if character == "`" { break }
                } else if character == "'" || character == "\"" {
                    innerQuote = character
                } else if character == "(" {
                    nesting += 1
                } else if character == ")" {
                    if nesting == 0 { break }
                    nesting -= 1
                }
                position += 1
            }
            let body = Array(characters[start..<min(position, characters.count)])
            if depth < 4 {
                substitutions.append(contentsOf: GitCommandRisk.segments(of: body, depth: depth + 1))
            }
            word.append(substitutionPlaceholder)
            hasWord = true
            return position + 1
        }

        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                word.append(character)
                hasWord = true
                escaped = false
                continue
            }
            if character == "`", quote != "'" {
                index = substitution(from: index, backtick: true)
                continue
            }
            if character == "$", quote != "'", index < characters.count, characters[index] == "(" {
                index = substitution(from: index + 1, backtick: false)
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "'", "\"":
                quote = character
                hasWord = true
            case " ", "\t":
                endWord()
            case ";", "\n", "|", "(", ")":
                endSegment()
            case "&":
                // `2>&1` / `&>` are redirections, not command separators.
                if word.hasSuffix(">") || word.hasSuffix("<") {
                    word.append(character)
                } else {
                    endSegment()
                }
            default:
                word.append(character)
                hasWord = true
            }
        }
        endSegment()
        return segments + substitutions
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func basename(_ word: String) -> String {
        (word as NSString).lastPathComponent
    }
}
