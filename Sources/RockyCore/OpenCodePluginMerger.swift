import Foundation

/// OpenCode does not use Claude-style shell hooks. It loads JavaScript plugins
/// from `~/.config/opencode/plugins/` that export async functions returning
/// hook handlers (`permission.ask`, `event`, `tool.execute.after`, …).
///
/// Rocky installs a single bridge plugin that spawns `rocky-hook --agent opencode`
/// with Claude-shaped JSON on stdin. Pure render/merge logic lives here; the
/// app layer owns filesystem I/O (mirrors `KimiPluginMerger` / Grok's dedicated
/// config file pattern).
public enum OpenCodePluginMerger {
    public static let pluginId = "rocky-notch"
    public static let pluginFileName = "rocky-notch.js"
    public static let commandMarker = "rocky-hook"
    public static let legacyMarker = "vibenotch-hook"

    /// Renders the bridge plugin source with the absolute hook binary path baked
    /// in (OpenCode plugins have no shared hooks.json for us to merge a command
    /// string into). Re-install rewrites the path when the app bundle moves.
    public static func pluginSource(
        hookBinaryPath: String,
        commandArguments: String = "--agent opencode"
    ) -> String {
        let args = commandArguments
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let argsLiteral = args.map { "\"\(escapeJS($0))\"" }.joined(separator: ", ")

        return """
        // Rocky ↔ OpenCode bridge. Auto-generated — do not edit by hand.
        // Install/uninstall from the Rocky app; re-install after moving Rocky.app.
        // Marker: \(commandMarker)
        import { spawn } from "node:child_process"

        const HOOK = \(jsString(hookBinaryPath))
        const HOOK_ARGS = [\(argsLiteral)]
        const CONNECT_FAIL_OPEN_MS = 200

        function runHook(payload, { wait } = { wait: false }) {
          return new Promise((resolve) => {
            let settled = false
            const finish = (value) => {
              if (settled) return
              settled = true
              resolve(value)
            }

            let child
            try {
              child = spawn(HOOK, HOOK_ARGS, {
                stdio: ["pipe", "pipe", "pipe"],
              })
            } catch {
              finish(null)
              return
            }

            let stdout = ""
            child.stdout.on("data", (chunk) => {
              stdout += String(chunk)
            })
            child.on("error", () => finish(null))
            child.on("close", () => {
              const text = stdout.trim()
              if (!text) {
                finish(null)
                return
              }
              try {
                const parsed = JSON.parse(text)
                finish(typeof parsed.decision === "string" ? parsed.decision : null)
              } catch {
                finish(null)
              }
            })

            try {
              child.stdin.write(JSON.stringify(payload))
              child.stdin.end()
            } catch {
              try { child.kill() } catch {}
              finish(null)
              return
            }

            // Fire-and-forget events should not hang the plugin if Rocky is down.
            if (!wait) {
              setTimeout(() => finish(null), CONNECT_FAIL_OPEN_MS)
            }
          })
        }

        function textFromParts(parts) {
          if (!Array.isArray(parts)) return ""
          return parts
            .map((p) => {
              if (!p || typeof p !== "object") return ""
              if (typeof p.text === "string") return p.text
              if (p.type === "text" && typeof p.text === "string") return p.text
              return ""
            })
            .filter(Boolean)
            .join(" ")
            .trim()
        }

        // Only export functions — OpenCode treats every named export as a plugin.
        export const RockyNotch = async ({ directory }) => {
          const cwd = directory || process.cwd()

          return {
            // When OpenCode would prompt (permission: "ask"), Rocky can allow/deny.
            // Leave status as "ask" on timeout/fail so OpenCode's own UI remains.
            "permission.ask": async (perm, output) => {
              const tool = perm?.type || "tool"
              const metadata =
                perm?.metadata && typeof perm.metadata === "object" ? perm.metadata : {}
              const decision = await runHook(
                {
                  session_id: perm?.sessionID || "unknown",
                  hook_event_name: "PermissionRequest",
                  tool_name: tool,
                  tool_input: metadata,
                  cwd,
                },
                { wait: true }
              )
              if (decision === "allow") output.status = "allow"
              else if (decision === "deny") output.status = "deny"
            },

            event: async ({ event }) => {
              if (!event || typeof event !== "object") return
              const props = event.properties || {}
              switch (event.type) {
                case "session.created": {
                  const info = props.info || {}
                  if (info.parentID) return
                  const id = info.id
                  if (!id) return
                  await runHook({
                    session_id: id,
                    hook_event_name: "SessionStart",
                    source: "startup",
                    cwd: info.directory || cwd,
                  })
                  return
                }
                case "session.idle": {
                  const id = props.sessionID
                  if (!id) return
                  await runHook({
                    session_id: id,
                    hook_event_name: "Stop",
                    cwd,
                  })
                  return
                }
                case "session.deleted": {
                  const info = props.info || props
                  const id = info.id || props.sessionID
                  if (!id) return
                  await runHook({
                    session_id: id,
                    hook_event_name: "SessionEnd",
                    cwd,
                  })
                  return
                }
                default:
                  return
              }
            },

            "chat.message": async (input, output) => {
              const sessionID = input?.sessionID
              if (!sessionID) return
              const prompt =
                textFromParts(output?.parts) ||
                (typeof output?.message?.content === "string"
                  ? output.message.content
                  : "")
              await runHook({
                session_id: sessionID,
                hook_event_name: "UserPromptSubmit",
                prompt: prompt || undefined,
                cwd,
              })
            },

            "tool.execute.after": async (input) => {
              if (!input?.sessionID || !input?.tool) return
              await runHook({
                session_id: input.sessionID,
                hook_event_name: "PostToolUse",
                tool_name: input.tool,
                tool_input: input.args || {},
                cwd,
              })
            },
          }
        }
        """
    }

    public static func isInstalled(pluginSource data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(commandMarker) || text.contains(legacyMarker)
    }

    /// True when the on-disk plugin still points at this hook binary and agent flag.
    public static func isCurrent(
        pluginSource data: Data?,
        hookBinaryPath: String,
        commandArguments: String = "--agent opencode"
    ) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        guard text.contains(commandMarker) else { return false }
        // Path may appear escaped in the JS string literal.
        guard text.contains(hookBinaryPath) else { return false }
        // Agent flag must still identify us as opencode.
        return commandArguments.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .allSatisfy { text.contains($0) }
    }

    // MARK: - Internals

    private static func jsString(_ value: String) -> String {
        "\"\(escapeJS(value))\""
    }

    private static func escapeJS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
