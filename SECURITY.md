# Security policy

## Supported version

Only the latest tagged release is intended to receive security fixes while the
project is in alpha.

## Threat model

This program discovers processes, reads local session metadata, terminates
selected process trees, runs package-manager or vendor update commands, and
starts new terminal processes. Bugs in identity mapping or command resolution
can therefore interrupt unrelated work or execute an unintended local binary.

The implementation reduces those risks by:

- resolving only known CLI command names;
- requiring durable session identity before shutdown;
- requiring the recorded process-start time to match the live process;
- acquiring process objects before termination so PID reuse cannot substitute
  a different process;
- rejecting temporal matches with any in-window runner-up and duplicate
  session IDs;
- refusing partial cycles when a supported process is unmapped;
- recording the complete plan before termination;
- checking that the coordinator is not hosted by a target process;
- using fixed update command arguments rather than state-file commands; and
- keeping automatic confirmation bypass opt-in.

The tool does not defend against an attacker who can already modify the script,
replace executables on the current user's `PATH`, or tamper with the user's
session databases. Review `PATH`, package-manager configuration, and state-file
permissions in higher-risk environments.

## Sensitive data

State files and the generated dashboard may contain session UUIDs, session
names, Windows user paths, repository paths, process metadata, and local
session-file locations. Do not attach them to public issues without reviewing
and redacting them.

The tool should never copy conversation message bodies. Dashboard action
summaries are limited to coordinator lifecycle events. Treat any regression
that copies message content as a security/privacy defect.

The Grok catalog adapter reads only directory identity and selected summary
metadata: generated title plus creation/activity timestamps. It deliberately
does not read chat history, prompt history, recap, or turn-summary fields.

The Kimi Code adapter reads only its session index and selected `state.json`
metadata: working directory, title, and creation/activity timestamps. It may
ask Windows which PID locks `agents/main/wire.jsonl`, but never opens or reads
that conversation event stream. It also excludes `lastPrompt`, prompt history,
search indexes, and other message-bearing files.

The DeepCode adapter reads the project session index for id, summary label,
project path, and timestamps. It does not copy reply, thinking, refusal,
tool-call, or usage fields, and it does not open session transcript files.

## Reporting

Until a private disclosure channel is published, do not open a public issue for
an unpatched vulnerability. Contact the repository owner privately through the
GitHub account that publishes the project.
