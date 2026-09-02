// Package main implements check-deps, a stdlib-only inventory of every
// pinned dependency in the strimserver repository. Phase 1 extracts the pins
// from the repo's build files and scripts; later phases add upstream version
// checks, a tiered report, caching, and ignore support.
package main

// dependency is one pinned dependency extracted from the repository. Every
// field describes what is pinned, where it is pinned, and to which version.
type dependency struct {
	// Category classifies the dependency, e.g. "bazel-module", "tool-binary",
	// "runtime", "base-image", "toolchain", "ci-action", or "script-pin".
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
	// Note carries an optional annotation, e.g. "digest-pinned".
	Note string
}

// unknown records an entry that could not be extracted. Extraction failures
// are never silent: every entry either becomes a dependency or an unknown.
type unknown struct {
	// File is the repo-relative path of the file that failed to yield the
	// entry.
	File string
	// Reason describes why the entry could not be extracted.
	Reason string
}
