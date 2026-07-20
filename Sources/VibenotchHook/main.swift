// vibenotch-hook: executed by agent CLIs (Claude Code) on hook events.
//
// Contract: NEVER block or fail the calling agent. Any error path exits 0
// with no output, which Claude Code treats as "no decision" (passthrough).
// Only an explicit allow/deny decision from the app produces stdout.
import Foundation
import VibenotchCore

let connectTimeoutMs: Int32 = 50
// Hard ceiling below the installed hook `timeout: 60`, so we exit cleanly
// (passthrough) instead of being killed by the agent CLI.
let decisionDeadline = Date().addingTimeInterval(58)

func failOpen() -> Never { exit(0) }

// `--agent <name>` identifies the calling CLI (default claude-code).
var agent = "claude-code"
let args = CommandLine.arguments
if let flag = args.firstIndex(of: "--agent"), flag + 1 < args.count {
    agent = args[flag + 1]
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? JSONDecoder().decode(HookEvent.self, from: input) else {
    failOpen()
}

let envelope = HookEnvelope(agent: agent, event: event)
guard
    let line = try? NDJSON.encodeLine(envelope),
    let client = SocketClient.connect(path: IPC.socketPath(), timeoutMs: connectTimeoutMs),
    client.send(line)
else {
    failOpen()
}
defer { client.closeSocket() }

// Fire-and-forget events end here; only PermissionRequest waits for a reply.
guard event.kind == .permissionRequest else {
    failOpen()
}

guard
    let replyLine = client.readLine(deadline: decisionDeadline),
    let reply = try? NDJSON.decode(DecisionMessage.self, from: replyLine),
    reply.requestId == envelope.requestId,
    let output = PermissionRequestOutput.stdout(for: reply.decision)
else {
    failOpen()
}

FileHandle.standardOutput.write(output)
exit(0)
