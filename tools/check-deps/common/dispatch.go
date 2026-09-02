package common

// firstMatch returns the first entry in the ordered table whose predicate
// holds, plus whether one was found. Order matters: the first claim wins. It
// is the one generic first-match-wins dispatch primitive; the classifier table
// (tierPolicies) and the resting-tier table (baseTierRules) both express their
// ordered rules as instances of it, so the "iterate until the first rule
// claims" loop lives in exactly one place.
func firstMatch[T any](table []T, holds func(entry T) bool) (T, bool) {
	for _, entry := range table {
		if holds(entry) {
			return entry, true
		}
	}
	var zero T
	return zero, false
}
