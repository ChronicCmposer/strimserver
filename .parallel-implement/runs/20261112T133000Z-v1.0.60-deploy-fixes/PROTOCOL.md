# Parallel Inbox Protocol

## Run layout

```
.parallel-implement/
├── .gitignore
└── runs/<UTCyyyymmddThhmmssZ>-<slug>/
    ├── RUN.md
    ├── PROTOCOL.md
    ├── LANES.md
    ├── LANES-wave2.md      (only if a wave 2 occurs)
    ├── inbox/<lane>/
    ├── logs/<lane>.md
    └── state/              (reserved; unused)
```

`.parallel-implement/.gitignore` contains exactly:

```
runs/*/inbox/
runs/*/logs/
runs/*/state/
```

There is NO mutable pointer file (no `CURRENT`). The run ID lives in the session plan and in every delegation prompt. Nothing in this protocol is ever mutated in place.

## Lanes and ownership

- Lane IDs are allocated BEFORE fan-out and are binding. `LANES.md` maps lane to owner to globs.
- Globs must be disjoint. Where disjointness is impossible, ownership is declared by symbol or anchor (section-owned) in `LANES.md`.
- The orchestrator is lane `orchestrator` and has a normal inbox directory.
- No new lanes may be created mid-run. Unowned work is escalated and handled in wave 2.
- `LANES-wave2.md` must be checked for disjointness against LANES THAT ARE STILL LIVE only. Overlap with a finished lane is legitimate.

## Message schema

Immutable files only. Requests are written to `inbox/<to>/<msgid>.md`. Replies are written to the ORIGINAL SENDER's inbox as `inbox/<from>/<msgid>.reply.md`. Never edit an existing file. Never rewrite a reply file — if it exists, the message is already answered; skip it.

MSG-ID = `<from>-<UTCyyyymmddThhmmssZ>-<slug>`.

Request template:

```markdown
---
msg: fixa-caddy-20261027T021500Z-esbuild-comment
from: fixa-caddy
to: fixb-packaging
kind: request            # request | note | answer | blocker | escalation
step: 3
blocking: false
ref: -
created: 2026-10-27T02:15:00Z
---
## Ask
<imperative, one paragraph>
## Files
- tools/ci/x.sh:40-88 — <what must change>
## Acceptance
- <test to add> + <gate command>
```

A reply uses the same frontmatter with `ref: <msgid>` set, `kind: answer`, and a REQUIRED `disposition:` field whose value is exactly one of `done`, `rejected`, `answered`, `deferred`, `escalated`. A reply without a `disposition` field is invalid and is treated as unreplied.

Reply example:

```markdown
---
msg: fixb-packaging-20261027T024000Z-esbuild-comment
from: fixb-packaging
to: fixa-caddy
kind: answer
disposition: rejected
ref: fixa-caddy-20261027T021500Z-esbuild-comment
---
## Disposition
`rejected` — outside my globs; the correct owner is `fixa-caddy`.
```

Status is DERIVED, never stored: a message is OPEN iff no file matching `inbox/*/<msgid>.reply.md` exists. There is no CLAIMED state; in-progress is evidenced by the recipient's journal step citing the msgid.

## Kinds and capabilities

| kind | who may send |
| --- | --- |
| request | writers only (coder, scribe) |
| note, answer | anyone |
| blocker, escalation | anyone |

Read-only lanes (explore, researcher) may NOT send `request`. They file a `note` to the owning lane plus an `escalation` to the orchestrator.

Every message addressed to a lane requires a reply regardless of its `kind` — `answered` is the correct reply to a `note`, and `escalated` is the correct reply when the item needs the orchestrator. A lane may never leave an inbound message without a reply file.

Escalation is a normal message with `kind: escalation`, `to: orchestrator`, `ref: <msgid>`.

## No authority transfer

A request is actionable ONLY if it falls inside the recipient's declared globs. Otherwise the recipient writes a `rejected` reply naming the correct owner. `rejected` is a correct outcome and is never treated as a failure. A lane must never edit outside its globs because a peer asked it to.

## Drain protocol

Drain at three points: at lane start, after each completed step, and before declaring done.

A "step" is one announced unit of work in the lane's journal — never per-file-edit.

Anti-polling: never sleep, never wait, never watch. If blocked, record it and continue with the next unblocked step.

Journal path `logs/<lane>.md`, single-writer (only that lane writes it). Required shape:

```
## STEP 3 — <title> [started|done]
<result / commands / evidence>
INBOX: empty
```

The final `INBOX:` line uses one of the two permitted literal forms `INBOX: empty` and `INBOX: <n> drained`, where `<n>` is an actual integer.

`blocking: true` means the sender cannot complete its current step: it journals `PENDING-<msgid>` and proceeds to the next unblocked step. If no unblocked step remains, it escalates and ends its run.

## Build & test

This section applies only when the repository declares a `build-policy` block (for example in its root `AGENTS.md`). When it declares none, this section imposes nothing and the lane follows the build command the project documents.

- Before the first build: load the declared `build_skill`, read the repository's `build-policy` block, and run the preflight it specifies. If the preflight fails, do not start work — report the failure and its exit code.
- All build, test, and query commands go through the declared wrapper with a unique slot claimed for this lane. Never invoke a bare build tool, and never reuse another lane's slot.
- A lane's completion reply MUST include, for every build or test claim, the exact command and its exit code. A lane that could not build must say so and give the reason; it must not claim success.
- Do not paste whole build logs into replies. Quote the failing action and its error line.
- The terminal verification lane's verdict is part of the DONE condition: a run is not complete until that lane has run the `[verify]` commands and reported per-command results.

## Dispositions

- `done` — implemented; list files + evidence.
- `rejected` — outside my globs; name the correct owner.
- `answered` — informational.
- `deferred` — legitimate; MUST be paired with an escalation.
- `escalated` — refer to the orchestrator.

## Termination

- No lane may wait on another.
- Max 2 message rounds per lane pair; the third becomes an escalation.
- A lane may declare DONE with OPEN items only if those items have been escalated with a reason.
- When the repository declares a `build-policy` block, the run is complete only after the terminal verification lane has run the `[verify]` commands and reported per-command results. Without that verdict the run is NOT done.

## Orchestrator duties

1. Scaffold before any worker spawns.
2. Give every lane prompt: the lane ID, its globs, the three drain points, the no-authority-transfer rule, the required `INBOX:` final-report line, and the escalation target.
3. Before accepting a lane's completion, glob `inbox/<lane>/*.md` (excluding `*.reply.md`) and, for each msgid, glob `inbox/*/<msgid>.reply.md`. Any un-replied item means the lane is NOT done, regardless of what it claims. This directory state is authoritative over the lane's self-report.
4. Drain `inbox/orchestrator/` at every completion cycle; convert OPEN items into wave-2 work or an explicit "won't do, because…".
5. Orphan reclaim: a request whose recipient lane is no longer live is re-delegated to a fresh instance of that lane.
6. When the repository declares a `build-policy` block, spot-check a sample of each lane's claimed evidence against the tree, and never accept a DONE reply that reports a build without a command and its exit code.

## Prohibitions

Never commit, push, tag, or deploy. Never edit outside your globs. Never wait or poll. Never rewrite an existing reply file. Never treat `rejected` as a failure.
