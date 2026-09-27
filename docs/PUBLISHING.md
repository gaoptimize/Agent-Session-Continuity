# Publishing checklist

This folder is prepared as the repository root. Review it before creating the
public repository; do not publish the surrounding workspace.

## Before publication

1. Complete `REVIEW_CHECKLIST.md` and resolve all blocker findings.
2. Run `pwsh -NoProfile -File .\tests\Run-Tests.ps1`.
3. Run `AgentSessionContinuity.bat doctor` and `scan` on at least one machine
   with supported CLIs installed.
4. Inspect the entire tree for personal paths, session IDs, logs, state files,
   credentials, and conversation content.
5. Confirm the copyright line in `LICENSE` is acceptable to the publisher.
6. Keep the first release marked **prerelease** while shutdown and restart
   behavior receives field testing.

## Suggested repository name

Use `gaoptimize/Agent-Session-Continuity` as the URL-safe repository slug while
keeping **Agent Session Continuity** as the display name in documentation.

## Suggested GitHub CLI sequence

Run these commands from this folder only after review:

```powershell
git init
git add .
git commit -m "Initial MIT-licensed review release"
gh repo create gaoptimize/Agent-Session-Continuity --public --source . --remote origin --push
git tag -a v0.1.0 -m "Agent Session Continuity 0.1.0"
git push origin v0.1.0
```

Then create a GitHub prerelease from `v0.1.0`, using the `CHANGELOG.md` entry as
the release notes. Repository creation and publication are intentionally not
performed by the local packaging workflow.

