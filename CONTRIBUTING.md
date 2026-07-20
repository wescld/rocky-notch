# Contributing to Rocky

Thanks for wanting to help!

## Ground rules

- **Fail-open is sacred.** No change may allow Rocky to block an agent
  session. The hook must always exit fast and silent on any failure.
- **Official APIs only.** Agent integrations use documented hook systems,
  never terminal injection or screen scraping.
- **Conservative with user config.** Merges into settings files must keep a
  backup, preserve foreign keys and stay idempotent. See
  `ClaudeSettingsMerger` and its tests.

## Getting started

```sh
make test               # unit tests must pass
Tests/integration.sh    # e2e harness must pass (11 checks)
make run                # build and launch
```

New agent integrations: implement an `AgentIntegration` entry (config path +
hook events) and, if the agent's input schema differs, extend `HookEvent`
tolerantly. Open an issue first if unsure.

## Style

Swift 5 mode, SwiftUI + AppKit. Match the surrounding code. Keep files
focused. Tests for everything in `VibenotchCore`.
