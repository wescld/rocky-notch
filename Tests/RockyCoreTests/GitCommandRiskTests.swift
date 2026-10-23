import XCTest
@testable import RockyCore

final class GitCommandRiskTests: XCTestCase {
    private func risk(_ command: String) -> CommandRiskLevel {
        ToolRiskClassifier.risk(toolName: "Bash", toolInput: .object(["command": .string(command)]))
    }

    private func assertRisk(
        _ expected: CommandRiskLevel, _ commands: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        for command in commands {
            XCTAssertEqual(risk(command), expected, command, file: file, line: line)
        }
    }

    func testForceAndDeletePushesAreCritical() {
        assertRisk(.critical, [
            "git push --force origin main",
            "git push -f origin main",
            "git push -uf origin feat",
            "git push --force-with-lease origin feat",
            "git push --force-with-lease=main:abc origin main",
            "git push origin +main",
            "git push origin +HEAD:main",
            "git push origin :old-branch",
            "git push origin ':old-branch'",
            "git push origin \":old-branch\"",
            "git push origin -d old-branch",
            "git push --delete origin old-branch",
            "git push --mirror backup",
            "git push --prune origin 'refs/heads/*:refs/heads/*'",
            "git -C ../repo push -f",
            "cd repo && git push origin :x",
            "GIT_SSH_COMMAND=ssh git push origin +main",
            "/usr/bin/git push --force",
            "bash -lc 'git push origin :gone'",
            "echo $(git push -f) ; true",
        ])
    }

    func testPushRefspecsAfterDoubleDash() {
        assertRisk(.critical, [
            "git push -- origin +HEAD:main", "git push origin -- '+HEAD:main'",
            "git push -- origin ':old-branch'", "git push origin -- :old-branch",
        ])
        assertRisk(.elevated, [
            "git push -- origin HEAD:main", "git push -- origin --force",
            "git push --dry-run -- origin +HEAD:main",
        ])
    }

    func testDestructiveGitOperations() {
        assertRisk(.destructive, [
            "git commit --amend --no-edit",
            "git commit -a --amend -m \"msg\"",
            "git reset --hard HEAD~1",
            "git clean -fd",
            "git clean -xdf",
            "git clean -f",
            "git clean --force -d",
            "git checkout -- .",
            "git checkout -- src/file.swift",
            "git checkout HEAD -- src/file.swift",
            "git checkout .",
            "git checkout -f main",
            "git restore .",
            "git restore src/file.swift",
            "git restore --staged --worktree .",
            "git restore -SW .",
            "git restore --source HEAD~2 -- file",
            "git branch -D feature",
            "git branch --delete --force feature",
            "git branch -df feature",
            "git stash drop",
            "git stash drop stash@{1}",
            "git stash clear",
            // Destructive outranks critical.
            "git commit --amend && git push -f",
        ])
    }

    func testHookBypassIsHigh() {
        assertRisk(.high, [
            "git commit --no-verify -m wip",
            "git commit -n -m wip",
            "git commit -anm wip",
            "git push --no-verify origin feat",
        ])
    }

    func testWrapperOptionValuesDoNotHideGit() {
        assertRisk(.destructive, [
            "sudo -u deploy git stash drop", "sudo -g staff -u deploy git stash drop",
            "sudo -C 4 -h host -p prompt git stash drop", "sudo --user=deploy git stash drop",
            "sudo -nu deploy git stash drop", "nice -n 10 git clean -fd",
            "nice --adjustment=10 git stash drop", "env -u TOKEN -C /workspace git stash drop",
            "env -S 'MODE=test' git stash drop", "sudo -u deploy nice -n 10 git clean -fd",
        ])
        assertRisk(.critical, [
            "nice -n 10 git push origin :main", "xargs -I {} git push origin :{}",
            "xargs -n 1 -P 2 -L 3 -s 4096 -d , -E end git push origin :main",
            "xargs -I{} git push origin :{}", "timeout 10 git push origin :main",
            "timeout -s TERM -k 2 10 git push origin :main",
        ])
        assertRisk(.elevated, [
            "echo nice -n 10 git clean -fd", "echo xargs -I {} git push origin :{}",
            "nice -n 10 git status", "env -- git status",
        ])
    }

    func testWarningLabelsMatchEachRiskTier() {
        for tier in [CommandRiskLevel.none, .low, .elevated] { XCTAssertNil(tier.warning) }
        XCTAssertTrue(CommandRiskLevel.high.warning?.hasPrefix("high risk —") == true)
        XCTAssertTrue(CommandRiskLevel.critical.warning?.hasPrefix("critical —") == true)
        XCTAssertTrue(CommandRiskLevel.destructive.warning?.hasPrefix("destructive —") == true)
        XCTAssertEqual(Set(CommandRiskLevel.allCases.compactMap(\.warning)).count, 3)
    }

    func testOrdinaryGitStaysElevated() {
        assertRisk(.elevated, [
            "git push origin main",
            "git push -u origin feat",
            "git push --set-upstream origin feat",
            "git push origin HEAD:refs/heads/main",
            "git push origin main --tags",
            "git commit -m \"fix: handle a:b refs\"",
            "git commit -m 'docs: mention git push origin :x and --amend'",
            "git commit -m \"--amend\"",
            "git commit -am \"wip\"",
            "git commit -m 'note: -f is force'",
            "git commit -S -m signed",
            "git commit -Sjohn -m signed",
            "git commit -m \"see; git push -f\"",
            "git status && git diff",
            "git checkout main",
            "git checkout -b feat/new origin/main",
            "git restore --staged src/file.swift",
            "git restore --staged .",
            "git branch -d merged",
            "git branch feat",
            "git stash",
            "git stash pop",
            "git stash list",
            "git clean -n",
            "git clean --dry-run -d",
            "git reset HEAD file",
            "git reset --soft HEAD~1",
            "git log --oneline 2>&1 | head",
            "echo 'git push -f'",
            "grep -r \"git clean -f\" docs",
        ])
    }

    /// Shell keywords are transparent: the git command after them counts.
    func testShellKeywordsDoNotHideGit() {
        assertRisk(.critical, [
            "if true; then git push -f; fi",
            "for b in a c; do git push origin :$b; done",
            "while read b; do git push origin :$b; done < list",
            "if false; then :; elif true; then git push --force; fi",
            "if false; then :; else git push origin +main; fi",
            "{ git push -f; }",
            "! git push --delete origin x",
            "(git push -f)",
        ])
        assertRisk(.destructive, [
            "until git stash drop; do sleep 1; done",
        ])
    }

    /// Backticks are command substitution: their content is its own command.
    func testBackticksSplitSegments() {
        assertRisk(.critical, ["echo `git push -f origin main`"])
        assertRisk(.destructive, ["x=`git stash drop`"])
        XCTAssertEqual(
            GitCommandRisk.segments(of: "echo `git push -f`"),
            [["echo", "$(…)"], ["git", "push", "-f"]]
        )
    }

    /// A substitution inside the git command no longer cuts off the flags
    /// after it; quoted substitutions are commands too.
    func testSubstitutionKeepsOuterArguments() {
        assertRisk(.critical, [
            "git push `echo origin` -f",
            "git push $(git remote | head -1) --force",
            "git push origin $(git branch --show-current) -f",
            "echo \"$(git push -f)\"",
            "echo \"`git push origin :x`\"",
        ])
        assertRisk(.elevated, [
            "git push origin $(git branch --show-current)",
            "git commit -m \"$(date)\"",
            "echo '$(git push -f)'",
        ])
        XCTAssertEqual(
            GitCommandRisk.segments(of: "git push `echo x` -f"),
            [["git", "push", "$(…)", "-f"], ["echo", "x"]]
        )
    }

    /// Regression guard: subcommands without a tier of their own keep the
    /// old "any force is critical" rule.
    func testUntieredSubcommandsKeepForce() {
        assertRisk(.critical, [
            "git worktree remove --force x",
            "git tag --force v1",
            "git branch --force a b",
            "git fetch --force",
            "git rebase --force-rebase",
            "git submodule update --force",
            "git add --force .env",
            "git switch --force m",
            "git filter-branch --force",
            "git lfs push --force",
            // Short `-f` where it means force.
            "git tag -f v1",
            "git worktree remove -f x",
            "git add -f .env",
            "git branch -f a b",
            "git fetch -f origin",
        ])
        assertRisk(.destructive, ["git rm -rf --cached dir", "git rm --force file"])
        assertRisk(.elevated, ["git rm -r dir", "git rm --cached file"])
        // `-f` that is not force, and untiered commands without force.
        assertRisk(.elevated, [
            "git grep -f patterns.txt",
            "git config -f .gitmodules --list",
            "git tag v1",
            "git fetch origin",
            "git worktree remove x",
            "git add .",
            "git log -- --force",
        ])
    }

    /// Option values are not stash actions.
    func testStashMessageNamedDropIsNotDestructive() {
        assertRisk(.elevated, [
            "git stash -m drop",
            "git stash push -m clear",
            "git stash push --message drop",
            "git stash push --message=drop",
        ])
        assertRisk(.destructive, ["git stash -q drop", "git stash drop -q stash@{0}"])
    }

    /// Dry runs only report; they fall back to the plain-shell tier, and the
    /// generic `--force` substring rule must not bump them back up.
    func testDryRunsDropToElevated() {
        assertRisk(.elevated, [
            "git push --dry-run --force origin main",
            "git push -n -f origin main",
            "git push -nf origin :old",
            "git push --dry-run origin +main",
            "git clean -n -fd",
            "git clean -fdn",
            "git clean --dry-run --force",
        ])
        // A real force push next to a dry run is still critical.
        assertRisk(.critical, ["git push -n origin x && git push -f origin x"])
        // Non-git `--force` keeps the generic rule.
        assertRisk(.critical, ["git status && npm install --force"])
        // A commit message no longer trips the generic substring rules.
        assertRisk(.elevated, ["git commit -m \"docs: never rm -rf or --force\""])
        // A wrapper before git still counts for the generic rules.
        assertRisk(.critical, ["sudo git push origin main"])
    }

    func testCaseMattersForBranchDelete() {
        XCTAssertEqual(risk("git branch -D x"), .destructive)
        XCTAssertEqual(risk("git branch -d x"), .elevated)
    }

    /// The pre-existing substring rules still apply alongside the git pass.
    func testExistingRulesStillHold() {
        XCTAssertEqual(risk("rm -rf /tmp/example"), .destructive)
        XCTAssertEqual(risk("sudo ls"), .critical)
        XCTAssertEqual(risk("ls"), .elevated)
        XCTAssertEqual(
            ToolRiskClassifier.risk(toolName: "Edit", toolInput: .object(["file_path": .string("x")])),
            .low
        )
    }

    func testLexerKeepsQuotedWordsAndSplitsOperators() {
        XCTAssertEqual(
            GitCommandRisk.segments(of: "git commit -m \"a; b\" && git push origin ':x' 2>&1 | cat"),
            [["git", "commit", "-m", "a; b"], ["git", "push", "origin", ":x", "2>&1"], ["cat"]]
        )
    }
}
