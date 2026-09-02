// Package common defines the shared contract surface of check-deps: the types
// every resolver, extractor, and report pass through (Dependency, Resolved,
// VersionInfo), the classification and semver primitives, and the bounded HTTP
// fetcher. It imports only the standard library so the resolver and extractor
// packages can build on it without dragging in implementation-specific
// dependencies.
package common

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
