# Adapter contract

Each provider adapter must answer six questions without reading conversation
message bodies.

## 1. Command discovery

- Which executable or wrapper names are valid?
- Are fallback paths necessary?
- How is command shadowing or an unexpected installation rejected?

## 2. Process discovery

- Which process names and executable paths belong to the CLI?
- How are desktop applications, services, and unrelated Node processes
  excluded?
- Which PID is the narrowest safe process-tree root?

## 3. Durable session identity

- What stable ID or name does the vendor's resume command accept?
- What evidence maps the running PID to that identity?
- What confidence is assigned?
- Does ambiguity produce `Unmapped` and abort the cycle?

## 4. Update

- What vendor-supported or package-manager command installs the desired
  release channel?
- Can the current version and candidate version be inspected before shutdown?
- What exit code and post-update check prove success?

## 5. Resume

- What exact argument form resumes by durable identity?
- How is the recorded working directory restored?
- What happens if the project directory no longer exists?

## 6. Verification and failure

- How is the restarted session shown to be alive and attached to the intended
  conversation?
- What data is written to the audit journal?
- How can a user recover manually?

## Current adapters

The alpha keeps adapters as named functions inside
`src/AgentSessionContinuity.ps1`:

- `Get-CodexSessions`
- `Get-ClaudeSessions`
- `Get-GrokSessions`
- `Get-KimiSessions`
- `Get-DeepCodeSessions`
- `Invoke-Updates`
- `Get-RestartScript`

Shared, side-effect-free safety predicates are isolated in `src/Safety.psm1`
for direct tests. Provider discovery, update, and restart behavior remains in
the coordinator.

A future module interface should preserve the six requirements above rather
than merely moving functions into separate files.

The Grok adapter uses `active_sessions.json` only for live PID-to-session
identity and reads selected lifecycle fields from each `summary.json`
(`generated_title`, creation/update timestamps). It does not read
`chat_history.jsonl`, prompt history, recaps, or turn summaries.

The Kimi Code adapter reads `session_index.jsonl` for durable IDs and locations,
then only `cwd`, `title`, `createdAt`, and `updatedAt` from each `state.json`.
For live identity it checks whether the verified Kimi process exclusively locks
that session's `agents/main/wire.jsonl`; the event stream itself is never read.
An explicit `--session`/`--resume` argument or a process-start-validated prior
inventory can also establish identity. As a final fallback, `High` confidence
requires exactly one session creation timestamp within ten minutes of process
start. Ambiguous locks or timestamps remain `Unmapped`.

The DeepCode adapter reads each `projects\<project>\sessions-index.json` for
the durable id, the vendor `summary` label, `originalPath`, and the create and
update timestamps. Reply, thinking, refusal, tool-call, and usage fields in
that index are not copied. Session `.jsonl` transcripts are not opened. Live
identity uses a resume argument, a process-start-validated prior inventory, or
one unique index timestamp within ten minutes of process start.
