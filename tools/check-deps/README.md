# check-deps

`tools/check-deps` inventories **every dependency-bearing source** in the
repository, resolves the latest upstream version of each pin, and emits a
tiered report so stale or drifting pins are noticed instead of silently
rotting.

It never modifies a pin. `--strict` is **on by default**: a run exits non-zero
when a pin's status cannot be determined (or an extraction unknown remains),
unless `deps-ignore.json` records a reviewed exception. Stale or available
updates alone never fail a run. The weekly
`.github/workflows/deps-check.yml` job is advisory (`--strict=false`) and
attaches the report as an artifact; the required PR check
`.github/workflows/deps-strict.yml` runs the hermetic strict variant. See
*Enforcement & CI* below.

Run it through the `make` facade or the underlying Bazel target (they are
equivalent):

```bash
make check-deps                                       # console report (default)
make check-deps-json                                  # JSON report to stdout
bazel run //tools/check-deps:check-deps -- --ignore    # apply deps-ignore.json
bazel run //tools/check-deps:check-deps -- --json --all # full JSON inventory
```

## What it audits

Every dependency-bearing source is covered by an extractor. A source that
cannot be parsed is never silently dropped: it surfaces as an **extraction
unknown** in the report (and fails a `--strict` run).

| Source | What is extracted | Category |
| --- | --- | --- |
| `MODULE.bazel` | `bazel_dep` modules, `single_version_override` pins, and every repo rule — the built-in `http_archive` / `http_file`, the custom `s3_http_archive` / `s3_http_file` / `qemu_x86_64` rules, and the `tarball_strip_symlinks` / `deb_extract` / `amd64_sysroot` / `apt.install` rules. Version pins come from the rule's version attribute, the URL, or the `strip_prefix`; an artifact pinned only by `sha256` is an **integrity** pin. | `bazel-module`, `tool-binary`, `base-image`, `runtime`, `toolchain` |
| Every `go.mod` | The Go toolchain version from the `go` directive (one finding per module). | `toolchain` |
| Every `go.sum` | Go modules recorded **only transitively** (their `module@version` pair is absent from the sibling `go.mod`'s require directives) → **inventory**. | `go` |
| Every `pnpm-lock.yaml` | npm packages recorded **only transitively** (present in the lockfile's package sections but not declared as an importer dependency) → **inventory**. | `npm` |
| `.bazelversion`, per-sub-repo `.nvmrc` and `package.json` | Bazel from `.bazelversion`; Node from each discovered `.nvmrc`; pnpm from each `package.json` `packageManager` field. | `toolchain` |
| `.github/workflows/*.yml` | Every `uses:` action reference and the toolchain `with:` inputs (`go-version`, `node-version`, …). | `ci-action`, `toolchain` |
| Shell scripts under `tools/`, `scripts/`, `deploy/` | Version / `*_SHA256` / `*_COMMIT` pins in the pinned build scripts (qemu, OpenSSH, FFmpeg, CUDA, GNU m4, fish, distlib, the DLAMI id, the S3 upload checksum, …). Hashes, epochs, and commits are **integrity** pins. A discovered script that carries a pin but has no extractor spec **fails closed** as an extraction unknown. | `script-pin`, `bzl-pin`, `ami`, `tool-binary`, `runtime` |
| `third_party/<lib>/pin.json` | One vendored-library pin per `third_party` subdirectory. A missing or malformed pin is an extraction unknown. | `tool-binary` |
| Stream Deck manifest `tools/streamdeck-plugin/…/manifest.json.tpl` | The plugin's `SDKVersion`, `Software.MinimumVersion`, `Nodejs.Version`, and per-OS `MinimumVersion` requirements. | `toolchain` |
| Repo `.env` | `PROJECT_GO_VERSION_TAG` (normalized `go1.27.2` → `1.27.2`) and `GOROOT_BOOTSTRAP`. | `toolchain` |
| Root `.bazelrc` | The registered toolchain and platform labels: `--platforms`, `--extra_toolchains`, and `register_toolchains(...)` arguments. These become **integrity** pins — a label names a toolchain graph, not a version. A missing `.bazelrc` is optional and yields nothing. | `toolchain` |
| Native toolchains | `go list -u` (Go module graph) and corepack `pnpm outdated` (each discovered node sub-repo) resolve current + latest directly. A missing toolchain is an `unknown`, never a crash. Disabled by `--native-tools=false`; an `--offline` run reports their pins as `skipped` instead. | `go`, `npm` |

Resolution is first-match-wins. A resolver is chosen by an exact
category/name match, an **architecture-normalized name prefix** (so
`golangci_lint_linux_amd64` also owns `…_arm64`, and `mediamtx_dist` owns
`mediamtx_dist_arm64`), or a **URL-derived** GitHub match (owner/repo parsed
from the pin's download URL). Unmatched pins are reported as `unknown` with a
reason.

## Report schema

The JSON report is a single compact line (terse for machine and LLM
consumers). `schemaVersion` is bumped on any incompatible shape change.

```json
{
  "schemaVersion": "2",
  "findings":  [ … ],
  "unknowns":  [ … ],
  "inventory": [ … ],
  "integrity": [ … ],
  "counts":    { … }
}
```

### Sections

A resolved dependency is routed to exactly one section, in this order:

1. **`integrity`** — the pin's identity is a hash, not a version
   (`Dependency.Role == "integrity"`, or a classifier `integrity` status).
   `current` carries the pinned hash. There is no upstream version to compare,
   so these are never `update`/`unknown` findings.
2. **`inventory`** — a lockfile-transitive pin recorded for completeness but
   not reviewed (it has no top-level upstream version). `current` carries the
   locked version.
3. **`findings`** — every reviewable dependency, carrying a tier.

`integrity` and `inventory` entries are **untiered** and are never counted in
the T1/T2/T3 tallies. A pin that is both an integrity pin and inventory-tagged
is reported as `integrity` (the stronger classification).

### `findings[]`

| Field | Meaning |
| --- | --- |
| `category`, `name` | The dependency's category and name. |
| `current` | The version pinned in the source file. |
| `wanted` | The version to pin toward (the latest); empty when the latest is unknown. |
| `latest` | The latest resolved upstream version. |
| `tier` | `T1`, `T2`, or `T3` (see *Tiers*). |
| `source` | Where the pin comes from (URL, registry ref, or digest). |
| `url` | `source` when it is an `http(s)` URL, else empty. |
| `releaseDate` | Optional upstream release date. |
| `status` | `update`, `unknown`, `ok`, `hygiene`, `integrity`, or `skipped`. |
| `ignored` | `true` when a `deps-ignore.json` rule matches this pin. |
| `file` | The repo-relative source file that declared the pin. |
| `pins` | Every distinct `{file, version}` declaration when a logical dependency is declared in several files (or as per-arch twins). |
| `reasons` | Human-readable explanations (e.g. a floating tag, a resolution failure). |
| `infos` | Informational notes (yanked, exempt, staleness). |
| `metadata` | Optional structured metadata (e.g. AMI release names, `drift`). |

Findings that describe one logical dependency — same category and
architecture-normalized name — are **collapsed** into a single finding: `pins`
lists every declaration, the representative takes the most severe member's
status and the most severe tier, `ignored` is set only when every member is
ignored, and `metadata.drift` records `mixed-version` and/or `mixed-arch`.

### `unknowns[]`

One entry per extraction failure (`file` + `reason`) or per resolved
dependency whose latest version could not be determined (`name` + `file` +
`reason`). Each entry carries `ignored: true` when a live `deps-ignore.json`
rule covers it. A resolution failure never aborts the run outright; it is
surfaced here, and (under the default `--strict`) an unknown **not** covered by
a live rule fails the run.

### `inventory[]` and `integrity[]`

`{ category, name, current, file?, source?, note? }` — flat rows with the
locked version (inventory) or pinned hash (integrity).

### `counts`

| Key | Meaning |
| --- | --- |
| `total` | Report entries = `t1 + t2 + t3 + inventory + integrity` (logical dependencies; a collapsed pair counts once). |
| `t1`, `t2`, `t3` | Finding tallies per tier. |
| `update`, `unknown`, `ok`, `hygiene` | Finding tallies per status. |
| `ignored` | Findings matched by an ignore rule. |
| `unknowns` | Length of the `unknowns` array (distinct from the `unknown` status count). |
| `inventory`, `integrity` | Section sizes. |
| `skipped` | Finding tallies with status `skipped` (resolution deliberately not attempted, e.g. a network-backed or native pin left unrun by `--offline`). It completes the status tallies, so `update + unknown + ok + hygiene + skipped` covers every finding. |

### Statuses

| Status | Meaning |
| --- | --- |
| `update` | A newer upstream version exists; the pin should be reviewed. |
| `unknown` | The latest version could not be determined (network failure, missing toolchain, unparseable version, or no resolver). |
| `ok` | The pin is current (or properly pinned with no tag to compare, e.g. a digest). |
| `hygiene` | The pin is valid but floats upstream (a rolling tag or year-major base image); consider a digest or date pin. |
| `integrity` | The pin is a hash; there is no version to compare. |
| `skipped` | Resolution was deliberately not attempted — an `--offline` run left a network-backed resolver or a native (`go list -u` / `pnpm outdated`) pin unrun. Counted in `counts.skipped`. |

### Roles

`Dependency.Role` distinguishes a comparable version pin from a hash pin. The
empty value is treated as `version`, so extractors that do not set a role keep
their version semantics.

| Role | Meaning |
| --- | --- |
| `version` (or empty) | A pin with a comparable upstream version. |
| `integrity` | A pin whose identity is an integrity hash (SRI / sha256 / commit / epoch) with no upstream version to compare. |

## Tiers

Each finding gets a **review priority**. The resting tier comes from a
first-match-wins category/name table; an update can promote it.

| Tier | Meaning |
| --- | --- |
| `T1` (security) | Security-critical surface: network services, base images, media/emulation parsers. Listed individually, highest priority. |
| `T2` (review) | Build graph, toolchain, and supply chain. Listed individually. |
| `T3` (minor) | Everything else. Collapsed into a count in the console report. |

Resting-tier rules (from `main.go`):

| Category | Resting tier |
| --- | --- |
| `base-image`, `runtime`, `ami` | T1 |
| `bazel-module`, `toolchain`, `ci-action` | T2 |
| `tool-binary` | T2 — except `mediamtx_dist` (T1) |
| `script-pin` | T1 for `openssh-portable`, `ffmpeg`, `CUDA`, `nv-codec-headers`; T2 for `qemu`; otherwise T3 |
| `bzl-pin` | T2 for `qemu`; otherwise T3 |
| anything else | T3 |

An update's final tier: a resting T1 **stays T1**; any other pin **promotes to
T2** on a breaking bump; routine updates rest at T3. A breaking bump is a
major-version change for 1.x+ modules and a minor-version change on the 0.x
line.

## Flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--json` | off | Emit the JSON report to **stdout**. |
| `--console` | off | Emit the human-readable console report. |
| `--fresh` | off | Bypass the TTL cache and refetch every upstream result. |
| `--ignore` | off | Apply `deps-ignore.json` to mark intentional pins as ignored. |
| `--all` | off | Include current (`ok`) findings in the findings list. By default only non-`ok` findings are listed; counts still cover the full inventory. |
| `--offline` | off | Skip every network-backed resolver and replace the native batch resolvers with an offline reporter; matched pins are reported as `skipped` rather than fetched. No-op/digest resolvers are unaffected. `--offline` alone is hermetic. |
| `--strict` | **on** | Exit non-zero when any extraction unknown or undeterminable pin remains. Integrity and inventory pins are exempt; an unknown covered by a live `deps-ignore.json` rule satisfies strict. The report is written before the non-zero exit. |
| `--native-tools` | **on** | Run the native `go list -u` / `pnpm outdated` batch resolvers. Set `false` to disable them entirely for a hermetic, network-free run. `--offline` takes precedence, so an offline run reports the native pins as `skipped` regardless of this flag. |

Output routing: JSON always goes to stdout. The console report goes to
**stderr** when `--json` is also set (so stdout stays clean for the
machine-readable report) and to stdout otherwise. When neither `--json` nor
`--console` is given, the console report is the default.

Exit codes: `0` success (updates may exist); `1` operational failure (repo
root unresolvable, JSON serialization failed) or a `--strict` violation. A
strict failure writes the full report before exiting, so the reviewer always
sees the findings.

### Hermetic / offline runs

`--offline` replaces every network-backed resolver **and** the native
`go list -u` / `pnpm outdated` batch resolvers with a skip reporter: matched
pins are reported as `skipped` with no network access, so **`--offline` alone
is hermetic**. The native batch resolvers are separately gated by the
`--native-tools` flag (default `true`); `--native-tools=false` registers no
native resolver at all. `--offline` takes precedence over `--native-tools`, so
both `--offline` and `--native-tools=false` produce a network-free run. The
required PR check runs `--strict --offline --native-tools=false` (see
*Enforcement & CI*).

### Cache

Network-backed resolvers cache upstream results for 24 hours at
`tools/check-deps/.cache/deps-cache.json`, so repeated runs are fast and
offline-friendly. The cache is git-ignored. Only network resolvers are cached:
the no-op/digest resolvers are never cached, and the native resolvers
(`go list -u`, `pnpm outdated`) resolve live online and are reported `skipped`
on an `--offline` run. A transient resolution
failure is never cached, so a one-off network blip is not replayed as
`unknown` for the whole TTL.

## How to add a dependency source

Adding a new kind of dependency-bearing source is a five-part contract. Do all
five; a source without a resolver or a tier silently degrades to `unknown` /
T3.

1. **Write the extractor.** Add a pure parser and a reader under
   `extractorimpl/`. For a fixed file, register a `common.SourceSpec`
   (`RelPath` + pure `Parse(data, file)`) and run it through
   `common.RunSourceSpecs`; for a discovered tree, write a top-level
   `func ExtractX(root string) ([]common.Dependency, []common.ExtractionUnknown)`
   that satisfies the `common.Extractor` contract. Return an
   `ExtractionUnknown` — never a silent drop — for anything you cannot parse.
   Hash/commit/epoch pins should set `Role: common.RoleIntegrity`.

2. **Register it.** Add a top-level extractor to the `extractors` slice in
   `main.go`; scripts register through `scriptSourceSpecs` (plus the
   fail-closed discovery pass); aggregate extractors (`ExtractWorkflows`,
   `ExtractToolchains`, `ExtractVendoredPins`) pick up their own sub-sources
   automatically. Add the new source file to the `go_library` `srcs` in
   `BUILD.bazel`.

3. **Add a resolver, or mark the pin integrity.**
   - Network-backed: add `networkedDep(Matches(category, name), resolverimpl.XResolve(fetcher))`
     to the `resolvers` slice in `main.go`.
   - GitHub owner/repo: use `githubDep(...)` or `githubMatchDep(...)`.
   - No upstream version (digest/toolchain): use `noopDep(...)`.
   - Integrity hash: set `Role: common.RoleIntegrity` on the emitted
     `Dependency` — it classifies as `integrity` and needs no resolver.

4. **Assign a tier.** Add a `common.BaseTierRule{Category, Name, Tier}` to the
   classifier in `main.go`. A named rule must sit **before** its category's
   default rule (first match wins). An unlisted category rests at T3.

5. **Add an ignore entry only if the pin knowingly floats.** If the pin is
   intentionally held back from an available update, add a rule to
   `deps-ignore.json` with a `reason` and (usually) an `until` date. See
   [`docs/deps-ignore.md`](docs/deps-ignore.md).

## Enforcement & CI

- **Local runs enforce by default.** `--strict` is on, so `make check-deps`
  (which passes `--ignore`) and any plain
  `bazel run //tools/check-deps:check-deps` fail — non-zero exit — when a pin
  cannot be determined or an extraction unknown remains. The full report is
  written before the failure, so the reviewer always sees it. Pass
  `--strict=false` for a purely advisory run.
- **The PR check is hermetic.** `.github/workflows/deps-strict.yml` runs on
  every pull request with `--strict --offline --native-tools=false`: no
  network-backed resolver and no native toolchain shell-out runs, so the check
  is reproducible on any runner, and a new unaccounted pin cannot land
  silently.
- **The weekly job is advisory.** `.github/workflows/deps-check.yml` runs every
  Monday at 03:00 UTC (and on demand via `workflow_dispatch`) with
  `--strict=false --ignore`; it exits `0` even when updates exist and uploads
  the JSON report and console log as the `deps-check` artifact.
- **The ignore file is the escape hatch.** A finding or unknown covered by a
  live `deps-ignore.json` rule satisfies `--strict` (an ignored unknown is not
  a failure). Integrity and inventory pins never need a rule — they are exempt.
  A rule with an empty `reason`, or an `until` that is malformed or already
  expired, fails closed and does **not** satisfy strict. See
  [`docs/deps-ignore.md`](docs/deps-ignore.md).

## Related docs

- [`docs/deps-ignore.md`](docs/deps-ignore.md) — the `deps-ignore.json` schema
  and policy.
- The repo root `README.md` — the *Dependency check* section and the build
  dependencies and versions table.
