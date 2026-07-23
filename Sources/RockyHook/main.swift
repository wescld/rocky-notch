// rocky-hook: executed by agent CLIs on hook events.
//
// Contract: NEVER block or fail the calling agent. Any error path exits 0
// with no output, which agents treat as "no decision" (passthrough / fail-open).
// Only an explicit allow/deny decision from the app produces stdout.
import Foundation
import RockyCore

let connectTimeoutMs: Int32 = 50
// Hard ceiling below the installed hook `timeout: 60`, so we exit cleanly
// (passthrough) instead of being killed by the agent CLI.
let decisionDeadline = Date().addingTimeInterval(58)

/// Debug trail next to the socket. Best-effort only — logging must never
/// affect the fail-open contract.
func debugLog(_ message: String) {
    let path = (IPC.socketPath() as NSString).deletingLastPathComponent + "/hook.log"
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        if (try? handle.seekToEnd()) ?? 0 > 1 << 20 {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

func failOpen(_ reason: String) -> Never {
    debugLog("fail-open: \(reason)")
    exit(0)
}

// Agent identity: explicit `--agent` from our installs wins; the GROK_* env
// sniff only covers Grok running Claude-compat hooks.
let agent = AgentIdentity.resolve(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
)

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? JSONDecoder().decode(HookEvent.self, from: input) else {
    failOpen("decode: \(String(data: input.prefix(300), encoding: .utf8) ?? "binary")")
}
debugLog("event \(event.hookEventName) session=\(event.sessionId) agent=\(agent) tool=\(event.toolName ?? "-") subagent=\(event.agentId ?? "-")")

// Grok PreToolUse fires for every tool (even in always-approve). Skip the
// Rocky gate for read-only tools and when Grok is already in YOLO /
// always-approve — otherwise Rocky becomes a second approval UI the user
// never asked for. Silent exit is fail-open (allow).
if agent == "grok",
   event.kind == .permissionRequest,
   GrokToolPolicy.shouldSkipRockyGate(
       toolName: event.toolName,
       permissionMode: event.permissionMode
   ) {
    debugLog(
        "auto-pass tool=\(event.toolName ?? "-") mode=\(event.permissionMode ?? "config")"
    )
    exit(0)
}

// Cursor blocking hooks: beforeShellExecution / beforeMCPExecution.
// beforeReadFile and anything non-shell/MCP: silent exit (fail-open) so we
// never override Cursor's own allow-list with an explicit {"permission":"allow"}.
if agent == "cursor",
   event.kind == .permissionRequest,
   CursorToolPolicy.shouldAutoPass(
       toolName: event.toolName,
       hookEventName: event.hookEventName
   ) {
    debugLog("auto-pass tool=\(event.toolName ?? "-") event=\(event.hookEventName)")
    exit(0)
}

// Resolve the agent CLI PID **now**, while this process is still a child of
// the agent tree. The app used to walk ancestry after we exit; by then the
// hook PID is often reaped and agentProcessPid stayed nil → sticky cards.
let hookPid = ProcessInfo.processInfo.processIdentifier
let agentPid = ProcessAncestry.agentAncestor(of: hookPid, agent: agent)
if let agentPid {
    debugLog("agentPid=\(agentPid) for agent=\(agent)")
} else {
    debugLog("agentPid unresolved for agent=\(agent)")
}

let envelope = HookEnvelope(
    agent: agent,
    event: event,
    agentProcessPid: agentPid
)
guard let line = try? NDJSON.encodeLine(envelope) else {
    failOpen("encode")
}
guard let client = SocketClient.connect(path: IPC.socketPath(), timeoutMs: connectTimeoutMs) else {
    failOpen("connect")
}
guard client.send(line) else {
    failOpen("send")
}
defer { client.closeSocket() }

// Fire-and-forget events end here; PermissionRequest / PreToolUse wait.
guard event.kind == .permissionRequest else {
    exit(0)
}

guard let replyLine = client.readLine(deadline: decisionDeadline) else {
    failOpen("no reply before deadline")
}
guard
    let reply = try? NDJSON.decode(DecisionMessage.self, from: replyLine),
    reply.requestId == envelope.requestId
else {
    failOpen("invalid reply")
}
debugLog("decision \(reply.decision.rawValue) session=\(event.sessionId)")
guard let output = PermissionRequestOutput.stdout(
    for: reply.decision,
    agent: agent,
    updatedInput: reply.updatedInput
) else {
    exit(0)
}

FileHandle.standardOutput.write(output)
exit(0)
