# Independent review checklist

Reviewers should assume that vendor metadata changes, paths contain hostile
characters, several sessions share one working directory, and updates fail
halfway through.

## Process safety

- Can a process matcher select a desktop app, service, or unrelated Node task?
- Can PID reuse cause a stale inventory to stop a different process?
- Are child processes terminated without touching a parent terminal?
- Does ancestry detection reliably prevent coordinator self-termination?

## Session identity

- Is every stopped process mapped to exactly one durable session ID?
- Can two running processes claim the same session?
- Are temporal heuristics bounded and visibly labeled?
- Does any ambiguity abort before the first process is stopped?

## Update transaction

- Is the complete recovery list durable before shutdown?
- Are update commands fixed and independent of mutable state files?
- Does every failure leave enough information for manual recovery?
- Should update failures prevent restart, or is the current best-effort restart
  policy preferable?

## Restart

- Are command paths rediscovered after update?
- Are UUIDs, names, and terminal titles quoted safely?
- Is the recorded working directory restored without command injection?
- Can duplicate restarts attach to an already running session safely?

## Privacy and distribution

- Can any message body enter state, logs, tests, or error output?
- Are personal paths and session IDs absent from the repository?
- Are vendor names used only for interoperability descriptions?
- Do tests run without installed vendor CLIs or network access?

## Suggested review output

Classify each finding as:

- **Blocker**: could stop the wrong process, lose recoverability, or execute an
  unintended command;
- **Major**: mapping/update/restart failure in a plausible environment;
- **Minor**: usability, diagnostics, documentation, or maintainability issue;
- **Future**: useful hardening outside the v0.1 release boundary.

