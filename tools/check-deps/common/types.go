// Package common defines the shared contract surface of check-deps: the types
// every resolver, extractor, and report pass through (Dependency, Resolved,
// VersionInfo), the classification and semver primitives, and the bounded HTTP
// fetcher. It imports only the standard library so the resolver and extractor
// packages can build on it without dragging in implementation-specific
// dependencies.
package common

// types.go owns the full shared contract surface: Dependency, ExtractionUnknown,
// VersionInfo, Status, Tier, DepKey, and their methods.
import "strings"

// Dependency is one pinned dependency extracted from the repository. Every
// field describes what is pinned, where it is pinned, and to which version.
type Dependency struct {
	// Category classifies the dependency; the Category* constants enumerate
	// the supported values (e.g. CategoryBazelModule, CategoryToolBinary).
	Category string
	// Name is the dependency's name, e.g. "rules_go" or "golangci-lint".
	Name string
	// Version is the currently pinned version exactly as written in the
	// source file. Empty when the pin carries no version (digest-only pins).
	Version string
	// Source is where the dependency comes from: a URL, registry reference, or
	// digest. Empty when the source file records no location.
	Source string
	// File is the repo-relative path of the file the dependency was extracted
	// from.
	File string
	// Note carries an optional informational annotation, e.g. "git tag
	// V_10_3_P1". It is not rendered in any output; it is purely descriptive.
	Note string
	// Branch carries an optional structured upstream branch the pin selects
	// (e.g. the Alpine branch "v3.23" an iperf3 apk comes from). It is set
	// alongside Note by the extractors that know the branch, so resolvers can
	// read it without regex-parsing the display-only Note.
	Branch string
	// DigestPinned marks a base image pinned by digest (sha256) rather than a
	// mutable tag; there is no tag to compare.
	DigestPinned bool
}

// Category* constants enumerate the dependency categories the extractors
// produce. They are the one source of truth for the category strings; the
// classifier and the base-tier table reference them instead of re-typing the
// literals.
const (
	CategoryBazelModule = "bazel-module"
	CategoryToolBinary  = "tool-binary"
	CategoryBaseImage   = "base-image"
	CategoryRuntime     = "runtime"
	CategoryToolchain   = "toolchain"
	CategoryCIAction    = "ci-action"
	CategoryScriptPin   = "script-pin"
	CategoryGo          = "go"
	CategoryNPM         = "npm"
)

// ExtractionUnknown records an entry that could not be extracted. Extraction
// failures are never silent: every entry either becomes a Dependency or an
// ExtractionUnknown. (The resolved "unknown" report shape is the distinct
// unknownEntry type in the main package's output.)
type ExtractionUnknown struct {
	// File is the repo-relative path of the file that failed to yield the
	// entry.
	File string
	// Reason describes why the entry could not be extracted.
	Reason string
}

// VersionInfo is the pure datum a resolver produces: the latest upstream
// version, an optional release date, informational notes, and the error when
// resolution failed (never fatal, always surfaced as "unknown"). The fields
// are exported because resolvers construct this value directly; Classify
// treats it as an untrusted boundary input and clones the slice before
// storing it.
type VersionInfo struct {
	// Version is the latest/wanted version ("" when there is none to compare).
	Version string
	// Date is an optional upstream release date.
	Date string
	// Infos are informational notes (yanked, deprecated, staleness, exemptions).
	Infos []string
	// Err is the resolution failure; nil means success.
	Err error
}

// Status classifies what action a resolved dependency needs.
type Status string

const (
	// StatusUpdate means a newer upstream version exists and the pin should
	// move forward.
	StatusUpdate Status = "update"
	// StatusUnknown means the latest version could not be determined (a
	// network failure, missing toolchain, or unparseable version). Resolution
	// failures are never fatal: they surface here with a reason.
	StatusUnknown Status = "unknown"
	// StatusOK means the pin is current (or properly pinned with no tag to
	// compare, e.g. a digest).
	StatusOK Status = "ok"
	// StatusHygiene means the pin is valid but floats upstream (a rolling tag
	// or year-major base image); the reviewer should consider a digest or
	// date pin.
	StatusHygiene Status = "hygiene"
)

// Tier ranks the review priority of a dependency.
type Tier int

const (
	TierT1 Tier = 1 // security-critical; treat every change with care
	TierT2 Tier = 2 // review: build graph, toolchain, supply chain, breaking bumps
	TierT3 Tier = 3 // minor: patch-level or build-time tooling updates
)

// String renders the review-tier label. It routes through Normalized(), the
// one canonical "unrecognized tier -> T3" rule, so a future or unrecognized
// tier value renders as T3 rather than panicking or inventing a label.
func (t Tier) String() string {
	switch t.Normalized() {
	case TierT1:
		return "T1"
	case TierT2:
		return "T2"
	case TierT3:
		return "T3"
	}
	panic("Tier.String: Normalized() returned an unrecognized tier")
}

// Normalized maps any tier value to the three report tiers, resting
// unrecognized or future values at TierT3. TierT3 is the explicit catch-all
// resting tier (baseTier defaults every unclaimed dependency to it), so an
// unrecognized value intentionally renders, counts, and buckets as T3 rather
// than panicking. It is the one canonical "unrecognized tier -> T3" rule:
// String(), the count accumulator, and the console renderer all route through
// it so the fallback never diverges.
func (t Tier) Normalized() Tier {
	switch t {
	case TierT1:
		return TierT1
	case TierT2:
		return TierT2
	default:
		return TierT3
	}
}

// DepKey is the single identity tuple for a dependency: (category, name,
// source, version). It is the shared key both dedupe and the cache use, so a
// "deduplicated" set and a "cached" set always mean the same thing.
type DepKey [4]string

// depKeySep is the unit separator (\x1f) that joins the identity fields into
// the stable JSON cache key. It cannot appear in a version string, so the
// joined key is unambiguous and deterministic.
const depKeySep = "\x1f"

// String renders the identity as the stable cache key: category, name, source,
// and version joined by depKeySep. Field order is deliberate and fixed, so the
// string form is byte-identical for identical dependencies.
func (k DepKey) String() string {
	return strings.Join(k[:], depKeySep)
}

// DepIdentity returns dep's identity key; see DepKey.
func DepIdentity(dep Dependency) DepKey {
	return DepKey{dep.Category, dep.Name, dep.Source, dep.Version}
}
