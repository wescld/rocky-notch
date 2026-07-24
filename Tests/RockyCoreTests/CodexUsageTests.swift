import XCTest
@testable import RockyCore

final class CodexUsageTests: XCTestCase {
    func testParsesLatestTokenCountRateLimits() throws {
        let root = try makeRoot("parse-latest")
        defer { try? FileManager.default.removeItem(at: root) }

        let rollout = root
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-latest.jsonl")

        try writeRollout(
            [
                eventLine(
                    timestamp: "2026-04-03T01:49:35.000Z",
                    rateLimits: [
                        "limit_id": "codex",
                        "plan_type": "pro",
                        "primary": [
                            "used_percent": 12.0,
                            "window_minutes": 300,
                            "resets_at": 1_775_158_295,
                        ],
                        "secondary": [
                            "used_percent": 24.0,
                            "window_minutes": 10_080,
                            "resets_at": 1_775_635_184,
                        ],
                    ]
                ),
                eventLine(
                    timestamp: "2026-04-03T01:50:35.000Z",
                    rateLimits: [
                        "limit_id": "codex",
                        "plan_type": "pro",
                        "primary": [
                            "used_percent": 13.0,
                            "window_minutes": 300,
                            "resets_at": 1_775_158_295,
                        ],
                        "secondary": [
                            "used_percent": 25.0,
                            "window_minutes": 10_080,
                            "resets_at": 1_775_635_184,
                        ],
                    ]
                ),
            ],
            to: rollout
        )
        try setModified(Date(timeIntervalSince1970: 2_000), on: rollout)

        let snap = try XCTUnwrap(
            CodexUsageLoader.load(
                fromRoot: root,
                now: Date(timeIntervalSince1970: 2_100),
                maxAge: 86_400
            )
        )
        XCTAssertEqual(snap.planType, "pro")
        XCTAssertEqual(snap.limitID, "codex")
        XCTAssertEqual(snap.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(snap.windows.map(\.roundedUsedPercentage), [13, 25])
        XCTAssertEqual(snap.primary?.roundedUsedPercentage, 13)
        XCTAssertEqual(snap.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_775_158_295))
        XCTAssertEqual(snap.capturedAt, iso("2026-04-03T01:50:35.000Z"))
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(snap.sourcePath)).resolvingSymlinksInPath().path,
            rollout.resolvingSymlinksInPath().path
        )
    }

    func testFallsBackWhenNewestRolloutHasNoRateLimits() throws {
        let root = try makeRoot("fallback")
        defer { try? FileManager.default.removeItem(at: root) }

        let older = root
            .appendingPathComponent("2026/04/02", isDirectory: true)
            .appendingPathComponent("rollout-has-limits.jsonl")
        let newer = root
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-no-limits.jsonl")

        try writeRollout(
            [
                eventLine(
                    timestamp: "2026-04-02T17:54:17.621Z",
                    rateLimits: [
                        "primary": [
                            "used_percent": 13.0,
                            "window_minutes": 300,
                            "resets_at": 1_775_158_295,
                        ],
                    ]
                ),
            ],
            to: older
        )
        try writeRollout(
            [
                #"{"timestamp":"2026-04-03T03:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#,
            ],
            to: newer
        )
        try setModified(Date(timeIntervalSince1970: 1_000), on: older)
        try setModified(Date(timeIntervalSince1970: 2_000), on: newer)

        let snap = try XCTUnwrap(
            CodexUsageLoader.load(
                fromRoot: root,
                now: Date(timeIntervalSince1970: 2_100),
                maxAge: 86_400
            )
        )
        XCTAssertEqual(snap.windows.map(\.label), ["5h"])
        XCTAssertEqual(snap.primary?.roundedUsedPercentage, 13)
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(snap.sourcePath)).resolvingSymlinksInPath().path,
            older.resolvingSymlinksInPath().path
        )
    }

    func testWindowLabelsForNonStandardDurations() {
        XCTAssertEqual(CodexUsageLoader.windowLabel(minutes: 90), "1h 30m")
        XCTAssertEqual(CodexUsageLoader.windowLabel(minutes: 1_500), "1d 1h")
        XCTAssertEqual(CodexUsageLoader.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(CodexUsageLoader.windowLabel(minutes: 10_080), "7d")
        XCTAssertEqual(CodexUsageLoader.windowLabel(minutes: 45), "45m")
    }

    func testIgnoresStaleRolloutsOutsideMaxAge() throws {
        let root = try makeRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }

        let rollout = root
            .appendingPathComponent("2026/01/01", isDirectory: true)
            .appendingPathComponent("rollout-old.jsonl")
        try writeRollout(
            [
                eventLine(
                    timestamp: "2026-01-01T00:00:00.000Z",
                    rateLimits: [
                        "primary": [
                            "used_percent": 99.0,
                            "window_minutes": 300,
                        ],
                    ]
                ),
            ],
            to: rollout
        )
        try setModified(Date(timeIntervalSince1970: 100), on: rollout)

        let snap = CodexUsageLoader.load(
            fromRoot: root,
            now: Date(timeIntervalSince1970: 100 + 200_000),
            maxAge: 86_400
        )
        XCTAssertNil(snap)
    }

    func testMissingRootReturnsNil() {
        let missing = URL(fileURLWithPath: "/tmp/rocky-no-codex-\(UUID().uuidString)")
        XCTAssertNil(CodexUsageLoader.load(fromRoot: missing))
    }

    func testSnapshotFromMalformedLineReturnsNil() {
        XCTAssertNil(
            CodexUsageLoader.snapshot(
                fromLine: "not-json",
                sourcePath: "/tmp/x",
                fallbackDate: Date()
            )
        )
        XCTAssertNil(
            CodexUsageLoader.snapshot(
                fromLine: #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
                sourcePath: "/tmp/x",
                fallbackDate: Date()
            )
        )
    }

    // MARK: - Helpers

    private func makeRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-codex-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeRollout(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func setModified(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func iso(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value)
    }

    private func eventLine(timestamp: String, rateLimits: [String: Any]) -> String {
        let object: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": ["total_tokens": 1]],
                "rate_limits": rateLimits,
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
