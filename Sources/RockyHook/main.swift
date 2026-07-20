// rocky-hook: executed by agent CLIs (Claude Code) on hook events.
//
// Contract: NEVER block or fail the calling agent. Any error path exits 0
// with no output, which Claude Code treats as "no decision" (passthrough).
// Only an explicit allow/deny decision from the app produces stdout.
import Foundation
import RockyCore

let connectTimeoutMs: Int32 = 50
// Hard ceiling below the installed hook `timeout: 60`, so we exit cleanly
// (passthrough) instead of being killed by the agent CLI.
let decisionDeadline = Date().addingTimeInterval(58)

/// Debug trail at ~/Library/Application Support/vibenotch/hook.log.
/// Best-effort only — logging must never affect the fail-open contract.
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

// `--agent <name>` identifies the calling CLI (default claude-code).
var agent = "claude-code"
let args = CommandLine.arguments
if let flag = args.firstIndex(of: "--agent"), flag + 1 < args.count {
    agent = args[flag + 1]
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? JSONDecoder().decode(HookEvent.self, from: input) else {
    failOpen("decode: \(String(data: input.prefix(300), encoding: .utf8) ?? "binary")")
}
debugLog("event \(event.hookEventName) session=\(event.sessionId) agent=\(agent) tool=\(event.toolName ?? "-") subagent=\(event.agentId ?? "-")")

let envelope = HookEnvelope(agent: agent, event: event)
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

// Fire-and-forget events end here; only PermissionRequest waits for a reply.
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
guard let output = PermissionRequestOutput.stdout(for: reply.decision) else {
    exit(0)
}

FileHandle.standardOutput.write(output)
exit(0)
