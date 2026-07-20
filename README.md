<p align="center">
  <img src="Support/Art/rocky/south.png" width="88" alt="Rocky" />
</p>

<h1 align="center">Rocky</h1>

<p align="center">
  Your AI coding agents, living in the notch.<br />
  Watch every Claude Code and Codex session and approve permissions without leaving your flow.
</p>

---

Rocky is a native macOS app that sits in your MacBook notch (or menu bar) and
monitors every AI coding agent session on your machine. When an agent asks
for permission, Rocky chimes, shows you the command or the diff, and lets you
approve or deny with one click. In any terminal: Terminal.app, VS Code,
Cursor, cmux, even over SSH.

## Why it works everywhere

Rocky integrates through the agents' **official hooks APIs**, not terminal
injection or screen scraping. The approval flow:

```
Claude Code ── PermissionRequest hook ──▶ vibenotch-hook ── unix socket ──▶ Rocky
     ◀── allow / deny ◀───────────────────────────────────◀── you click
```

**Fail-open by contract:** if Rocky isn't running, crashes, or takes too
long, the hook exits in milliseconds with no output and the normal terminal
prompt appears. Rocky can never block your work.

## Features

- Live session monitor around the notch: who's running, who needs you
- One-click Approve / Deny / "answer in terminal" for permission requests
- Diff preview for file edits, command preview for shell
- What each agent is doing right now, streamed from the transcript
- Token usage and working time per session
- Rocky speaks in soft musical chimes when something needs you
- Menu bar mode for notchless displays
- Claude Code and Codex supported today; more agents welcome via PRs
- 100% local. No server, no telemetry, no account.

## Install

Build from source (Swift 5.10+, macOS 14+):

```sh
git clone <repo-url>
cd rocky
make run
```

Then click the Rocky icon in the menu bar and install the integration for
your agent. New sessions appear automatically.

Rocky adds its hooks to `~/.claude/settings.json` (with a backup, merging
conservatively, never touching your other settings). Removing the
integration removes only Rocky's entries.

## Development

```sh
make test               # unit tests (VibenotchCore)
Tests/integration.sh    # end-to-end harness: real hook against the real app
make app                # build dist/Rocky.app (ad-hoc signed)
```

- `Sources/VibenotchCore` - event models, IPC protocol, session state
  machine, settings merge. Pure and tested.
- `Sources/VibenotchHook` - the tiny CLI executed by agent hooks.
  Aggressive deadlines, fail-open everywhere.
- `Sources/VibenotchApp` - the app: IPC server, session hub, notch UI,
  agent integrations.

## License

Code is [MIT](LICENSE). The Rocky character and its assets are not, see
[ASSETS-LICENSE.md](ASSETS-LICENSE.md).
