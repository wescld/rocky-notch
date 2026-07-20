// vibenotch-hook: executed by agent CLIs (Claude Code) on hook events.
// Contract: NEVER block or fail the calling agent. Any error path exits 0
// with no output, which the agent treats as "no decision" (passthrough).
import Foundation

exit(0)
