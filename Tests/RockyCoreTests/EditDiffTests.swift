import XCTest
@testable import RockyCore

final class EditDiffTests: XCTestCase {
    func testEditDiffCountsAndOrder() throws {
        let input = JSONValue.object([
            "file_path": .string("/a/m.ts"),
            "old_string": .string("const verify = (token) =>\n  jwt.verify(token);"),
            "new_string": .string(
                "const verify = (token) =>\n  if (!token) throw new\n  AuthError('missing');\n  return jwt.verify(token);"
            ),
        ])
        let diff = try XCTUnwrap(EditDiff.from(toolName: "Edit", input: input))
        XCTAssertEqual(diff.removals, 1)
        XCTAssertEqual(diff.additions, 3)
        XCTAssertEqual(diff.lines.first, .context("const verify = (token) =>"))
        XCTAssertTrue(diff.lines.contains(.removed("  jwt.verify(token);")))
    }

    func testWriteIsAllAdditions() throws {
        let input = JSONValue.object([
            "file_path": .string("/a/new.ts"),
            "content": .string("line1\nline2"),
        ])
        let diff = try XCTUnwrap(EditDiff.from(toolName: "Write", input: input))
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.removals, 0)
    }

    func testBashHasNoDiff() {
        XCTAssertNil(EditDiff.from(
            toolName: "Bash",
            input: .object(["command": .string("ls")])
        ))
    }

    func testIdenticalStringsProduceEmptyChangeCounts() {
        let diff = EditDiff.diff(old: "same", new: "same")
        XCTAssertEqual(diff.additions, 0)
        XCTAssertEqual(diff.removals, 0)
    }
}
