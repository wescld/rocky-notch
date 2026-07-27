import Foundation

/// One piece of work a session registered as in flight while its main loop
/// parked: a subagent, a background shell, an MCP monitor, a workflow.
///
/// Claude Code reports these on `Stop` and `SubagentStop` as `background_tasks`
/// — the field exists precisely to "distinguish 'session is done' from 'session
/// is paused waiting for background work to wake it'". Without it a session
/// that delegated reads as finished, and the notch says "done · click to jump"
/// while three agents work.
///
/// This list is also the *filter*. Claude Code fires `SubagentStop` for its own
/// internal helpers (session titling and friends), which never appear here;
/// rendering from this array instead of from the subagent events keeps them out
/// without Rocky having to recognize them.
public struct BackgroundTask: Identifiable, Equatable, Sendable, Codable {
    /// For a subagent this is its `agent_id`, so tool events from the subagent
    /// join straight onto the row.
    public let id: String
    /// Raw discriminant — "subagent", "shell", "monitor", "workflow", … Kept
    /// verbatim so a type we have never seen still renders as itself.
    public let kind: String
    /// "running" / "pending". The payload only carries in-flight work, so this
    /// is recorded rather than filtered on.
    public let status: String?
    /// Written by the agent for a human ("Fable design review of brainstorm"),
    /// which is why it outranks anything Rocky could synthesize from the type.
    public let description: String?
    /// Subagent only ("general-purpose").
    public let agentType: String?
    /// Shell only.
    public let command: String?
    /// Last tool the subagent ran. Enrichment from its own tool events, not
    /// part of the payload.
    public var lastAction: String?
    /// Model behind a subagent ("fable"). Read from the on-disk meta sidecar —
    /// see `metaPath(transcriptPath:agentId:)` — because no hook payload
    /// carries it.
    public var model: String?

    /// Deliberately the payload's own spelling, so the wire shape, the IPC hop
    /// and the on-disk snapshot are all one format — there is no second
    /// representation to keep in sync. `last_action` and `model` are Rocky's
    /// additions and simply never appear in an agent's payload.
    enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case status
        case description
        case agentType = "agent_type"
        case command
        case lastAction = "last_action"
        case model
    }

    public init(
        id: String,
        kind: String,
        status: String? = nil,
        description: String? = nil,
        agentType: String? = nil,
        command: String? = nil,
        lastAction: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.description = description
        self.agentType = agentType
        self.command = command
        self.lastAction = lastAction
        self.model = model
    }

    /// Decodes one payload entry, falling back to a synthetic id.
    public init(payload: JSONValue, fallbackID: String) {
        let reported = payload["id"]?.stringValue
        id = (reported?.isEmpty == false ? reported! : fallbackID)
        kind = payload["type"]?.stringValue ?? "task"
        status = payload["status"]?.stringValue
        description = payload["description"]?.stringValue
        agentType = payload["agent_type"]?.stringValue
        command = payload["command"]?.stringValue
        lastAction = nil
        model = nil
    }

    /// Decodes the whole `background_tasks` array.
    ///
    /// An entry without a usable id is kept under a synthetic one rather than
    /// dropped. Dropping looked tolerant — one bad entry costing only its own
    /// row — but a payload whose entries were *all* malformed then decoded to
    /// an empty list, and an empty list is precisely how a session says it has
    /// nothing left to wait for. A malformed entry could therefore announce a
    /// completion that never happened. A synthetic id never matches an
    /// `agent_id`, which is the right behaviour for work we cannot identify:
    /// the row is counted and drawn, it just never claims a live action.
    ///
    /// Repeated ids collapse to the first, because they reach SwiftUI as
    /// duplicate identities and two rows sharing one would conflate updates.
    public static func list(from payloads: [JSONValue]) -> [BackgroundTask] {
        var seen: Set<String> = []
        var tasks: [BackgroundTask] = []
        for (index, payload) in payloads.enumerated() {
            let task = BackgroundTask(payload: payload, fallbackID: "unidentified-\(index)")
            guard seen.insert(task.id).inserted else { continue }
            tasks.append(task)
        }
        return tasks
    }

    public var isSubagent: Bool { kind == "subagent" }

    /// The single line standing in for work past the row cap.
    ///
    /// "Who" survives grouping even where "what" cannot: a shell whose
    /// description never moves is still a Codex run the user launched, and
    /// knowing two agents are out there beats knowing two *things* are. The
    /// count leads because it is the part that is always true; the names are
    /// enrichment and simply thin out when nothing was identifiable.
    public static func groupedLabel(_ tasks: [BackgroundTask], maxNames: Int = 3) -> String {
        let base = "\(tasks.count) \(groupedNoun(tasks))"
        var names: [String] = []
        for name in tasks.compactMap(\.providerLabel) where !names.contains(name) {
            names.append(name)
        }
        guard !names.isEmpty else { return base }
        let shown = names.prefix(maxNames).joined(separator: " · ")
        return names.count > maxNames ? "\(base) · \(shown) …" : "\(base) · \(shown)"
    }

    /// Names what the group *is*, because a bare count reads as "two more of
    /// something" and leaves the user to guess. Shell and subagent are the
    /// cases that actually occur; anything mixed or unknown stays generic
    /// rather than claiming a type it did not see.
    private static func groupedNoun(_ tasks: [BackgroundTask]) -> String {
        let plural = tasks.count != 1
        switch Set(tasks.map(\.kind)) {
        case ["shell"]: return plural ? "shell jobs" : "shell job"
        case ["subagent"]: return plural ? "more agents" : "more agent"
        default: return plural ? "more tasks" : "more task"
        }
    }

    /// What the notch row reads. The agent already wrote a human sentence for
    /// this work, so Rocky shows it rather than inventing a label; the command
    /// and the raw type are fallbacks for a task registered without one.
    public var title: String {
        if let description, !description.isEmpty { return description }
        if let command, !command.isEmpty { return command }
        return kind
    }

    /// Short chip identifying *who* is doing the work — "Fable" for a subagent
    /// whose model we resolved, "Codex" / "Grok" for a shell that is clearly
    /// driving another CLI.
    ///
    /// The shell side is a keyword guess over free text the agent wrote, so it
    /// is display only: a miss shows no chip and a wrong hit shows the wrong
    /// name, neither of which moves any state. The exact answer, when it
    /// matters, comes from the task's own `description`.
    public var providerLabel: String? {
        if isSubagent {
            if let model, !model.isEmpty { return Self.titleCased(model) }
            if let agentType, !agentType.isEmpty { return agentType }
            return nil
        }
        // Whole words only: a substring search called `/opt/notclaude/run` a
        // Claude job. Splitting on non-alphanumerics keeps `mon-codex.sh`
        // working, since the marker is still a token of its own there.
        let haystack = ((description ?? "") + " " + (command ?? "")).lowercased()
        let words = Set(
            haystack
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        for (marker, label) in Self.providerMarkers where words.contains(marker) {
            return label
        }
        return nil
    }

    /// Ordered so a more specific marker wins: "opencode" before "code", and
    /// "claude" last because half the paths on this machine contain it.
    static let providerMarkers: [(String, String)] = [
        ("opencode", "OpenCode"),
        ("codex", "Codex"),
        ("grok", "Grok"),
        ("kimi", "Kimi"),
        ("gemini", "Gemini"),
        ("cursor", "Cursor"),
        ("claude", "Claude"),
    ]

    private static func titleCased(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// Sidecar Claude Code writes next to a subagent's transcript:
    /// `<transcript without .jsonl>/subagents/agent-<agentId>.meta.json`.
    /// It is the only place the subagent's model appears.
    public static func metaPath(transcriptPath: String, agentId: String) -> String? {
        guard !agentId.isEmpty else { return nil }
        let base = (transcriptPath as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        return (base as NSString)
            .appendingPathComponent("subagents")
            .appending("/agent-\(agentId).meta.json")
    }
}

/// The subagent sidecar, as written by Claude Code:
/// `{"agentType":"general-purpose","description":"…","model":"fable", …}`.
public struct SubagentMeta: Equatable, Sendable {
    public let agentType: String?
    public let description: String?
    public let model: String?

    public init?(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        agentType = root["agentType"] as? String
        description = root["description"] as? String
        model = root["model"] as? String
        if agentType == nil, description == nil, model == nil { return nil }
    }
}
