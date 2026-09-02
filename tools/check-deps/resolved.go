package main

// status classifies what action a resolved dependency needs.
type status string

const (
	// statusUpdate means a newer upstream version exists and the pin should
	// move forward.
	statusUpdate status = "update"
	// statusUnknown means the latest version could not be determined (a
	// network failure, missing toolchain, or unparseable version). Resolution
	// failures are never fatal: they surface here with a reason.
	statusUnknown status = "unknown"
	// statusOK means the pin is current (or properly pinned with no tag to
	// compare, e.g. a digest).
	statusOK status = "ok"
	// statusHygiene means the pin is valid but floats upstream (a rolling tag
	// or year-major base image); the reviewer should consider a digest or
	// date pin.
	statusHygiene status = "hygiene"
)

// tier ranks the review priority of a dependency.
type tier int

const (
	tierT1 tier = 1 // security-critical; treat every change with care
	tierT2 tier = 2 // review: build graph, toolchain, supply chain, breaking bumps
	tierT3 tier = 3 // minor: patch-level or build-time tooling updates
)

func (t tier) String() string {
	switch t {
	case tierT1:
		return "T1"
	case tierT2:
		return "T2"
	default:
		return "T3"
	}
}

// resolved pairs a Phase 1 dependency (the current pin) with the latest
// upstream version and the tier/status the classifier assigned.
type resolved struct {
	// Dep is the original pinned dependency extracted in Phase 1.
	Dep dependency
	// Tier is the review priority: T1 security / T2 review / T3 minor.
	Tier tier
	// Status is update | unknown | ok | hygiene.
	Status status
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

// unknownResolved builds a resolved record for a dependency whose latest
// version could not be resolved at all (missing toolchain, missing directory).
func unknownResolved(category, reason string) resolved {
	return resolved{
		Dep:     dependency{Category: category},
		Tier:    tierT3,
		Status:  statusUnknown,
		Reasons: []string{reason},
	}
}
