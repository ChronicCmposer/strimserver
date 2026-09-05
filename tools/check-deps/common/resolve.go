// Package common owns the resolver/resolution contract types: the per-dep
// Resolver func answers one dependency's latest version, BatchResolver answers
// a whole family from one native-tools invocation, and Resolved is the record
// produced for each pinned dependency. The resolver-entry matching types
// (ResolverEntry, Matches) live in the main package alongside the resolver
// registrations.
package common

import "time"

// Resolver resolves one dependency's latest version.
type Resolver func(dep Dependency) VersionInfo

// BatchResolver resolves a whole family of pinned dependencies (the Go module
// graph, the npm tree) from one native-tools invocation, returning one record
// per pinned dependency instead of a single version answer. The classifier is
// passed in so each batch resolver can classify its own records.
type BatchResolver func(root string, timeout time.Duration, classifier *Classifier) []Resolved

// Resolved pairs a Phase 1 dependency (the current pin) with the latest
// upstream version and the tier/status the classifier assigned.
type Resolved struct {
	// Dep is the original pinned dependency extracted in Phase 1.
	Dep Dependency
	// Tier is the review priority: T1 security / T2 review / T3 minor.
	Tier Tier
	// Status is update | unknown | ok | hygiene.
	Status Status
	// Latest is the newest upstream version the resolver found (empty when
	// unknown or when there is nothing to compare, e.g. a digest pin).
	Latest string
	// Date is an optional upstream release/publish date for the latest.
	Date string
	// Reasons explain a non-clean status (unknown resolution failures and
	// hygiene notes).
	Reasons []string
	// Infos carry informational notes that are not failures: yanked or
	// deprecated versions, branch staleness, exemption rationale.
	Infos []string
	// Metadata carries informational structured metadata surfaced to the
	// report, e.g. AMI release names/dates; nil when none.
	Metadata map[string]string
}
