package common

import "time"

// ResolverFunc resolves one dependency's latest version.
type ResolverFunc func(dep Dependency) VersionInfo

// ResolverEntry matches a dependency (usually by category/name) to its
// resolver. Entries are evaluated in order; the first match wins. Network
// marks resolvers that perform upstream I/O worth caching (registry calls,
// scrapers); the no-op resolvers (digest, toolchain) are not network-backed
// and never cached.
type ResolverEntry struct {
	// Match reports whether the entry owns the dependency.
	Match func(dep Dependency) bool
	// Resolve answers the dependency's latest version once matched.
	Resolve ResolverFunc
	// Network marks resolvers that perform upstream I/O worth caching.
	Network bool
}

// Matches builds a matcher that accepts a dependency of the given category and
// name.
func Matches(category, name string) func(Dependency) bool {
	return func(dep Dependency) bool {
		return dep.Category == category && dep.Name == name
	}
}

// BatchResolver resolves a whole family of pinned dependencies (the Go module
// graph, the npm tree) from one native-tools invocation, returning one record
// per pinned dependency instead of a single version answer.
type BatchResolver func(root string, timeout time.Duration) []Resolved
