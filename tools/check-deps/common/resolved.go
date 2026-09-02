package common

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
}

// MarkUpdate records that a newer upstream version exists, applying the
// already-derived final review tier.
func (r *Resolved) MarkUpdate(final Tier) {
	r.Status = StatusUpdate
	r.Tier = final
}

// UnknownResolved builds a resolved record for a dependency whose latest
// version could not be resolved at all (missing toolchain, missing directory).
func UnknownResolved(category, reason string) Resolved {
	return Resolved{
		Dep:     Dependency{Category: category},
		Tier:    TierT3,
		Status:  StatusUnknown,
		Reasons: []string{reason},
	}
}
