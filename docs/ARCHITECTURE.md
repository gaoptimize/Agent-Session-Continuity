# Architecture

Agent Session Continuity is a transaction-like coordinator around independent
vendor CLIs. It does not proxy model traffic or own conversation content.

## Lifecycle

1. **Discover** known CLI processes and installed commands.
2. **Identify** a durable conversation/session identifier for every target.
3. **Record** PID, session identity, name, working directory, matching evidence,
   and restart adapter in the inventory and cycle journal.
4. **Confirm** the complete plan and require an idle-session acknowledgement.
5. **Stop** the mapped process trees.
6. **Update** each installed CLI through its vendor/package-manager command.
7. **Resume** each saved conversation in its recorded working directory.
8. **Audit** the operation in state and log files.
9. **Present** a local, message-free session registry in the optional browser
   dashboard.

The transaction is intentionally conservative before shutdown and
best-effort afterward. Once processes have stopped, an update or restart can
fail; the saved cycle journal is the recovery source.

## Identity versus process

A PID identifies one running process and is invalid after restart. A durable
session UUID or vendor-supported name identifies the resumable conversation.
The inventory stores both:

- PID plus process-start time: discovery and ownership checks;
- session ID/name: restoration;
- working directory: project context;
- evidence/confidence: safety decision and audit.

## Matching confidence

- `Exact`: direct journal lock, PID runtime metadata, or explicit resume
  argument.
- `Tracked`: the PID and process-start time match a prior saved inventory.
- `High`: exactly one temporal candidate falls inside the adapter window.
- `Unmapped`: no durable identity; blocks `cycle`.

## State machine

`last-cycle.json` normally advances through:

```text
captured -> stopped -> updated -> restarted
```

If one or more resumes fail after every saved session has been attempted, the
final status is `restart-partial` and the per-session failures are recorded.

If the coordinator exits between states, the last written state and session
list support manual recovery. Automated rollback/recovery is future work.

## Dashboard registry

Every scan updates `session-registry.json`. Sessions observed in the current
scan are active; previously observed sessions absent from it become inactive.
Grok's, Kimi Code's, and DeepCode's local metadata catalogs are also imported
as inactive history. Grok entries are promoted from the vendor-maintained
active-session registry after their live executable path and PID are verified;
Kimi entries are promoted when an exact resume argument, an exclusive
event-stream file lock, a process-start-validated prior inventory, or one
unique session creation timestamp inside the conservative startup window maps
the running process. DeepCode entries are promoted from a resume argument, a
process-start-validated prior inventory, or one unique index timestamp inside
the same kind of window.
The registry preserves up to four recent coordinator actions per session and
sorts by the vendor journal/index activity timestamp, falling back to process
start or last observation when necessary. `session-dashboard.html` embeds a
local snapshot of that registry. It does not read message bodies, make network
requests, or infer the semantic content of an agent's work.

## Boundaries

The provider lifecycle remains in one PowerShell program. Small, side-effect-
free safety predicates live in `src/Safety.psm1` so PID identity and ambiguity
rules can be tested without stopping processes.
