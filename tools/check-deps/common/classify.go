package common

import "slices"

// This file contains the pure tier/status classifier. It has no network or
// filesystem access: every branch is a pure function of the dependency record
// and the VersionInfo a resolver returned, so the whole matrix is
// unit-testable. The concrete policy dispatch and resting-tier tables are
// supplied by the composition root via NewClassifier (see the main package's
// classify.go); this file owns the Classifier object itself.

// Classifier owns the ordered classification tables that decide a pinned
// dependency's tier and status: the tierPolicies dispatch (first claim wins)
// and the baseTierRules resting-tier table. It is built once by the
// composition root via NewClassifier and threaded through the resolution
// pipeline. The instance is immutable after construction: it never mutates the
// slices it was given.
type Classifier struct {
	tierPolicies  []TierPolicy
	baseTierRules []BaseTierRule
}

// NewClassifier builds a classifier from the ordered tier-policy dispatch and
// the resting-tier base rules. The slices are used as-is and never mutated, so
// callers keep ownership of their backing arrays.
func NewClassifier(tierPolicies []TierPolicy, baseTierRules []BaseTierRule) *Classifier {
	return &Classifier{tierPolicies: tierPolicies, baseTierRules: baseTierRules}
}

// Classify assigns a tier and status to a pinned dependency given the latest
// upstream version. It is the single decision point that turns raw resolver
// output into an actionable record. After the two resolution guards (error,
// empty version), it dispatches through the classifier's ordered tierPolicies
// table, each entry of which reports whether it owns the dependency; the
// generic semver policy is the fallback.
func (c *Classifier) Classify(dep Dependency, vi VersionInfo) Resolved {
	r := Resolved{
		Dep:    dep,
		Tier:   c.baseTier(dep),
		Latest: vi.Version,
		Date:   vi.Date,
		Infos:  slices.Clone(vi.Infos),
	}

	// Resolution failure: never fatal, surface the reason.
	if vi.Err != nil {
		r.Status = StatusUnknown
		r.Reasons = []string{vi.Err.Error()}
		return r
	}

	// No version to compare.
	if vi.Version == "" {
		if dep.DigestPinned {
			r.Status = StatusOK
			r.Reasons = append(r.Reasons, "digest-pinned; no tag to compare")
			return r
		}
		r.Status = StatusUnknown
		r.Reasons = []string{"no latest version returned by resolver"}
		return r
	}

	var res Resolved
	firstMatch(c.tierPolicies, func(policy TierPolicy) bool {
		var claimed bool
		res, claimed = policy(r, dep)
		return claimed
	})
	return res
}

// TierPolicy is one classifier entry in the ordered tierPolicies dispatch: it
// claims a dependency (ok = true) or declines, and when it claims, produces
// the final record.
type TierPolicy func(r Resolved, dep Dependency) (Resolved, bool)

// BaseTierRule is one entry in the baseTierRules table: a category/name match
// key and the resting tier it assigns. An empty Name is the category default;
// a named rule is a security-critical override that must sit before its
// category's default so it wins the first-match dispatch.
type BaseTierRule struct {
	Category string
	Name     string
	Tier     Tier
}

// baseTier returns the dependency's resting review priority from the
// first-match-wins baseTierRules table, defaulting to TierT3.
func (c *Classifier) baseTier(dep Dependency) Tier {
	rule, ok := firstMatch(c.baseTierRules, func(rule BaseTierRule) bool {
		return dep.Category == rule.Category && (rule.Name == "" || dep.Name == rule.Name)
	})
	if !ok {
		return TierT3
	}
	return rule.Tier
}

// firstMatch returns the first entry in the ordered table whose predicate
// holds, plus whether one was found. Order matters: the first claim wins. It
// is the one generic first-match-wins dispatch primitive; the classifier's
// tierPolicies and baseTierRules tables both express their ordered rules as
// instances of it, so the "iterate until the first rule claims" loop lives in
// exactly one place. It is defined here because classify.go is its only
// consumer.
func firstMatch[T any](table []T, holds func(entry T) bool) (T, bool) {
	for _, entry := range table {
		if holds(entry) {
			return entry, true
		}
	}
	var zero T
	return zero, false
}
