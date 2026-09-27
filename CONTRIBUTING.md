# Contributing

Contributions are welcome after the initial independent review.

Before proposing a change:

1. Read `SECURITY.md` and `docs/ADAPTERS.md`.
2. Keep discovery and mutation separate. `scan` must remain non-destructive.
3. Fail closed when a running process cannot be mapped to a durable session.
4. Do not add vendor conversation content to inventory, logs, fixtures, or
   tests.
5. Do not add machine-specific paths or identities.
6. Add a test for every change to process matching, session mapping, update
   invocation, or restart argument construction.
7. Run `pwsh -NoProfile -File .\tests\Run-Tests.ps1`.

Use focused commits and explain safety consequences in the pull request. New
adapters must document their process identity, durable session identity,
update command, resume command, confidence levels, and failure behavior.

