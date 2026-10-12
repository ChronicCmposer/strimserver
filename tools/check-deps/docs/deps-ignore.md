# deps-ignore.json

`deps-ignore.json` is the checked-in, git-tracked list of **intentional pins**
— dependencies that a plain `check-deps` run would report as an available
update, but that a reviewer has decided to tolerate for a documented reason and
(for most rules) a bounded time.

A rule does not change the pin. It marks a matching finding — or a matching
`unknown` — as ignored in the report and satisfies `--strict` for the pin it
covers, so the noise of a knowingly-held pin does not drown out real drift. The
file lives at the **repository root**. It is read when the tool runs with
`--ignore`, and also whenever `--strict` is in effect (the default), because
strict consults the ignore set:

```bash
make check-deps                                       # applies --ignore
bazel run //tools/check-deps:check-deps -- --ignore    # equivalent
```

Without `--ignore`, matched pins are not reported as ignored, but the file is
still read whenever `--strict` is in effect (the default), since strict consults
it to decide whether an unknown is a reviewed exception. It is not read at all
only on an `--strict=false` run without `--ignore`.

## Schema

The file is a JSON array of rule objects:

```json
[
  {
    "id": "npm/typescript",
    "file": "tools/streamdeck-plugin/package.json",
    "reason": "typescript upgrade to 7.x has breaking changes per previous investigation; wait until at least 7.1 before investigating again.",
    "until": "2027-01-31"
  }
]
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | The dependency identity, `category/name` (for example `npm/typescript`, `go/github.com/containerd/ttrpc`, `script-pin/CUDA`, `bzl-pin/qemu`). |
| `file` | no | Scopes the rule to one repo-relative source file. Omitted or empty matches **any** file. |
| `reason` | yes | The human justification for holding the pin. An empty or whitespace-only reason is not honored (the rule fails closed). |
| `until` | no | Expiry as a calendar date `YYYY-MM-DD`. Omitted means the rule never expires. |

### `id`

The identity is `category + "/" + name`, exactly as the finding's category and
name appear in the report. The categories are the same ones documented in the
tool README (`bazel-module`, `tool-binary`, `base-image`, `runtime`,
`toolchain`, `ci-action`, `script-pin`, `bzl-pin`, `go`, `npm`, `ami`). A name
may itself contain slashes (e.g. `go/github.com/containerd/ttrpc`,
`npm/@rollup/rollup-linux-arm64-gnu`); everything after the first `/` is the
name.

### `file`

Because the same logical pin can be declared in more than one file, a rule is
usually scoped to the file it applies to. For example, the CUDA pin is declared
in both `tools/ffmpeg-dist/build.sh` and `tools/ffmpeg-dist/publish.sh`, so it
takes **two** rules — one per file. A rule with no `file` matches the
dependency in every file (used for the `bzl-pin/qemu` rule, which has a single
declaration).

### `reason`

A short, factual justification that tells a future reviewer **why** the pin is
held and **when** to revisit it. An empty (or whitespace-only) `reason` is
**not** a reviewed exception: the loader keeps the rule but fails it closed, so
it never matches, and the tool warns
(`deps-ignore.json rule "…" has an empty reason; it is not honored`). It also
never satisfies `--strict`.

### `until`

A calendar date (`YYYY-MM-DD`). The rule **applies on and before** its `until`
date and stops applying once the current date is strictly after it. A rule with
no `until` never expires. When a rule expires, the pin it covered surfaces
again — as an `update` for a version pin, or as an `unknown` that, under the
default `--strict`, fails the run.

`until` bounds how long an exception is tolerated, so the intentional pin
reappears in the report and cannot be forgotten indefinitely. An expired rule
no longer satisfies `--strict`. Give every "wait for upstream" rule a realistic
`until`.

## Matching semantics

A rule matches a report entry (a finding or a resolved `unknown`) when all of
the following hold:

1. `id` equals the entry's `category/name`.
2. The rule's `file` is empty, **or** equals the entry's source file.
3. The rule is not expired: it has no `until`, or the current date is on or
   before `until`.

A Phase-1 extraction unknown carries no `id`, so it is matched by **file**
alone (rule 2 must hold; the rule's `id` is not consulted).

**Malformed `until` fails closed.** If an `until` value cannot be parsed as
`YYYY-MM-DD`, the rule is treated as **already expired** and never matches.
This is deliberate: a typo in an expiry date must not silently pin a dependency
forever. The rule stops applying and the entry surfaces again — an `update` for
a version pin, or an `unknown` that fails a `--strict` run — which is the safe
direction.

Expiry is compared against the **calendar date only** (not the time of day), so
a rule still applies on its `until` date regardless of the clock time.

## What an ignore applies to

- **Findings** — a matched finding is flagged `"ignored": true` in the JSON and
  listed under the `Ignored` section of the console report. The `counts.ignored`
  tally counts them. A collapsed multi-file finding is marked ignored only when
  **every** one of its pins is ignored.
- **Integrity and inventory entries are exempt** — these are never findings and
  carry no `ignored` field, so a rule cannot mark them. An integrity (hash) pin
  has no version to update, and an inventory (lockfile-transitive) pin is
  recorded for completeness only; neither is a review target.
- **Unknowns** — a rule can cover an unknown, and doing so satisfies
  `--strict`. A resolved `unknown` is matched by its `id` (`category/name`) and
  optional `file`; a Phase-1 extraction unknown (which carries only a `file`,
  no id) is matched by a **file-scoped** rule. The `unknowns[]` array is not
  filtered — the honest record stays — but each entry carries
  `"ignored": true` when a live rule covers it, so a reviewer can tell a
  reviewed exception from an open question.

## Loading behavior

`deps-ignore.json` is read once at the start of a run that uses it — either
`--ignore`, or `--strict` (on by default). Loading is robust:

- A **missing** or **unreadable** file yields an empty ignore set — the run
  continues with no ignores.
- A file that is **not valid JSON** yields an empty set and prints a warning
  (`check-deps: warning: ignoring malformed deps-ignore.json: …`) so the
  failure is never silent.
- A rule with an unparseable `until` is kept but treated as expired (fail
  closed), as described above.
- A rule with an empty (or whitespace-only) `reason` is kept but never matches
  (fail closed) and prints a warning.

An ignore-loading problem never aborts the run.

## `--strict` and the ignore set

`--strict` (on by default) fails the run when an extraction unknown or an
undeterminable (`unknown`) pin remains. A live rule that covers it turns that
into a reviewed exception, so the run succeeds:

- A resolved `unknown` is satisfied by a rule whose `id` matches its
  `category/name` and whose `file` is empty or equals the pin's source file.
- A Phase-1 extraction unknown is satisfied by a rule scoped to its file.
- Integrity and inventory pins are exempt from strict entirely.

The match fails **closed**: a rule whose `until` is malformed or already
expired, or whose `reason` is empty, never satisfies strict. The enforcing PR
check and the advisory weekly job are described in
[`../README.md`](../README.md).

## Adding a rule

1. Run the tool and note the finding's `category`, `name`, and source `file`.
2. Add an object to the array with `id` = `category/name`, `file` = the source
   file (omit only if the pin is declared in exactly one place), a clear
   `reason`, and an `until` date.
3. Keep the file valid JSON; a malformed file disables **all** rules and prints
   a warning, so the failure is never silent.

To satisfy `--strict` for a pin the tool cannot resolve, add a rule with the
pin's `category/name` — or, for a Phase-1 extraction failure, a rule scoped to
the failing `file`.

Add a rule only for a pin that is **knowingly floating** — held back from an
available update on purpose — or for an unknown a reviewer has accepted. A pin
that should be updated belongs in the report, not in this file.
