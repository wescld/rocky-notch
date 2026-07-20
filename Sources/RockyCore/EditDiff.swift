import Foundation

/// Line diff derived from an Edit/Write tool_input, for the approval card.
public struct EditDiff: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        case context(String)
        case removed(String)
        case added(String)
    }

    public let lines: [Line]
    public let additions: Int
    public let removals: Int

    /// Builds a diff when the tool input carries one (Edit's old/new_string,
    /// Write's content). Nil for tools without file mutations.
    public static func from(toolName: String, input: JSONValue?) -> EditDiff? {
        switch toolName {
        case "Edit":
            guard let old = input?["old_string"]?.stringValue,
                  let new = input?["new_string"]?.stringValue
            else { return nil }
            return diff(old: old, new: new)
        case "Write", "NotebookEdit":
            guard let content = input?["content"]?.stringValue
                ?? input?["new_source"]?.stringValue
            else { return nil }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            return EditDiff(
                lines: lines.map { .added(String($0)) },
                additions: lines.count,
                removals: 0
            )
        default:
            return nil
        }
    }

    static func diff(old: String, new: String) -> EditDiff {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = newLines.difference(from: oldLines)

        var removedIndices: Set<Int> = []
        var insertedIndices: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedIndices.insert(offset)
            case .insert(let offset, _, _): insertedIndices.insert(offset)
            }
        }

        // Interleave: walk old for context/removed, then new for added,
        // keeping the natural reading order (removed block above added).
        var lines: [Line] = []
        for (index, line) in oldLines.enumerated() {
            if removedIndices.contains(index) {
                lines.append(.removed(line))
            } else if lines.isEmpty {
                // Only the leading unchanged line is worth showing as context.
                lines.append(.context(line))
            }
        }
        for (index, line) in newLines.enumerated() where insertedIndices.contains(index) {
            lines.append(.added(line))
        }

        return EditDiff(
            lines: lines,
            additions: insertedIndices.count,
            removals: removedIndices.count
        )
    }
}
