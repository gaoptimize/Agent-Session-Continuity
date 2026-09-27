# Changelog

All notable changes to this project will be documented here.

## 0.1.0 - 2026-09-27

Initial review release.

### Added

- Windows session inventory and coordinated lifecycle.
- Codex CLI, Claude Code, and DeepCode CLI adapters.
- Exact Codex journal-lock matching through Windows Restart Manager.
- Claude PID metadata matching and timestamp-based legacy fallback.
- Persistent inventory, cycle journal, history, and logs.
- Interactive confirmation and fail-closed handling for unmapped sessions.
- Restart by list number, UUID, or name.
- Dynamic command discovery and configurable vendor data roots.
- Dependency-free static and empty-host tests.
- Local browser dashboard with a persistent active/inactive session registry,
  newest-first ordering, working directories, and coordinator action history.
- Grok adapter using its vendor active-session registry, local session catalog,
  documented update command, and documented resume flag.
- Kimi Code adapter using its local metadata index, exact event-stream lock
  ownership without reading conversation events, documented update command,
  and documented session resume flag.
- DeepCode historical sessions imported from each project's session index,
  excluding reply text and transcript files.
- Dashboard groups sessions by agent: the latest active session stays visible,
  and that agent's other sessions open with a click.

### Fixed after independent review

- Made the entry launcher safe under PowerShell strict mode.
- Bound termination to validated process objects and recorded start times,
  preventing stale or reused PIDs from selecting another process.
- Required prior-inventory matches to retain the same process start time.
- Rejected temporal matches with any in-window runner-up and duplicate durable
  session mappings.
- Scoped Codex process discovery to its resolved installation root.
- Removed last-write cutoffs that excluded idle session journals.
- Aligned Codex updates with the documented `codex update` command and
  rediscovered command paths after updates.
- Attempted every saved restart and recorded partial restart outcomes.
- Resolved exact names before treating numeric selectors as row numbers.

### Known limitations

- Windows only.
- Process termination is not a graceful vendor shutdown protocol.
- No automated rollback when an update succeeds but the new CLI is unhealthy.
- Vendor metadata schemas may change without notice.
- DeepCode process/session matching has less field experience than Codex and
  Claude matching.
