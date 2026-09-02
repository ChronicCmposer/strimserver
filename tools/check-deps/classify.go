package main

import (
	"regexp"
	"strings"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// This file owns the concrete tier-policy functions for a run: the ordered
// first-match-wins dispatch that the composition root (main) hands to
// common.NewClassifier alongside the resting-tier base rules. The Classifier
// object and the TierPolicy/BaseTierRule types live in the common package.

// classifyFloatingBaseImage flags floating base-image tags (amazonlinux:2023,
// latest, stable) that roll upstream as hygiene rather than a plain update. It
// reports whether the dependency is a floating base image and, when so, the
// final record.
func classifyFloatingBaseImage(r common.Resolved, dep common.Dependency) (common.Resolved, bool) {
	if !isFloatingBaseImage(dep) {
		return r, false
	}
	r.Status = common.StatusHygiene
	r.Tier = common.TierT2
	r.Reasons = append(r.Reasons, "floating tag "+dep.Version+": rolls upstream; consider a digest or date pin")
	return r, true
}

// classifyCIAction handles GitHub Actions pins, which are major-shorthand refs
// (@v4); it compares majors and exempts @vN pins from date-pinning hygiene. It
// reports whether the dependency is a ci-action and, when so, the final record.
func classifyCIAction(r common.Resolved, dep common.Dependency) (common.Resolved, bool) {
	if dep.Category != common.CategoryCIAction {
		return r, false
	}
	// A full-SHA ref is the recommended supply-chain pin; there is no tag
	// major to compare, so it is always current.
	if isFullSHA(dep.Version) {
		r.Status = common.StatusOK
		r.Infos = append(r.Infos, "full-SHA pin @"+dep.Version+"; not compared by major")
		return r, true
	}
	cur, curOK := actionMajor(dep.Version)
	latest, latestOK := actionMajor(r.Latest)
	if !curOK || !latestOK {
		r.Status = common.StatusUnknown
		r.Reasons = append(r.Reasons, "cannot parse action majors "+dep.Version+"/"+r.Latest)
		return r, true
	}
	if latest > cur {
		r.Status = common.StatusUpdate
		r.Tier = common.TierT2
		return r, true
	}
	r.Status = common.StatusOK
	r.Infos = append(r.Infos, "@"+dep.Version+" major pin; exempt from date-pinning hygiene")
	return r, true
}

// classifyDateTag handles date-stamped tags (debian trixie-YYYYMMDD-slim),
// which compare lexicographically — for fixed-width YYYYMMDD that is exactly
// numeric ordering. It reports whether the dependency is date-tagged and, when
// so, the final record.
func classifyDateTag(r common.Resolved, dep common.Dependency) (common.Resolved, bool) {
	if !isDateTagged(dep) {
		return r, false
	}
	cur, latest := utilities.ExtractDate(dep.Version), utilities.ExtractDate(r.Latest)
	if cur == "" || latest == "" {
		r.Status = common.StatusUnknown
		r.Reasons = append(r.Reasons, "cannot compare date tags "+dep.Version+"/"+r.Latest)
		return r, true
	}
	if common.CompareChunks(latest, cur) > 0 {
		// A newer date tag is an update, never a breaking bump; the tier rule
		// still derives the final tier from the resting one (T1 stays T1).
		r.MarkUpdate(updateTier(r.Tier, false))
		return r, true
	}
	r.Status = common.StatusOK
	return r, true
}

// classifySemver applies the generic semver compare to every dependency no
// policy claimed. It is the unconditional fallback policy: it always claims
// the dependency, so its ok flag is always true.
func classifySemver(r common.Resolved, dep common.Dependency) (common.Resolved, bool) {
	// resting is the dependency's review priority before promotion: earlier
	// dispatchers return early when they claim the dependency, so r.Tier is
	// still the untouched resting tier here.
	resting := r.Tier
	switch c := common.CompareSemver(dep.Version, r.Latest); {
	case c == 0:
		r.Status = common.StatusOK
	case c < 0:
		r.MarkUpdate(updateTier(resting, isBreakingBump(dep.Version, r.Latest)))
	default:
		// Pinned at or ahead of the latest known version: nothing to do.
		r.Status = common.StatusOK
	}
	return r, true
}

// isBreakingBump reports whether moving from cur to latest is a breaking
// (review-worthy) change. For Bazel modules on the 0.x line, the minor is the
// breaking axis (0.x minor-as-major); for 1.x+ only a major bump breaks. A
// 0 -> 1 major transition also breaks. On the 0.x axis a minor that is present
// but unparseable is treated conservatively as non-breaking, so a broken
// version string never silently escalates a review.
func isBreakingBump(cur, latest string) bool {
	curMaj, curMin, curOK, curMinorSet, curMinorValid := firstTwoNumeric(cur)
	latestMaj, latestMin, latestOK, latestMinorSet, latestMinorValid := firstTwoNumeric(latest)
	if !curOK || !latestOK {
		return false
	}
	if curMaj == 0 && latestMaj == 0 {
		if (curMinorSet && !curMinorValid) || (latestMinorSet && !latestMinorValid) {
			// A minor present but unparseable/overflowing is not trustworthy
			// enough to escalate: treat the bump as non-breaking.
			return false
		}
		return latestMin > curMin
	}
	return latestMaj > curMaj
}

// firstTwoNumeric parses the leading major and minor integers from a version.
// ok reports whether the major parsed; the minor has three distinct states
// (minorSet, minorValid) as documented at the call site.
func firstTwoNumeric(s string) (major, minor int, ok, minorSet, minorValid bool) {
	s = utilities.CoreVersion(s)
	parts := strings.Split(s, ".")
	major, ok = utilities.LeadingInt(parts[0])
	if !ok {
		return 0, 0, false, false, false
	}
	if len(parts) > 1 {
		minor, minorValid = utilities.LeadingInt(parts[1])
		return major, minor, true, true, minorValid
	}
	return major, 0, true, false, true
}

// actionMajor extracts the leading major integer from a GitHub Actions ref,
// e.g. actionMajor("v4") == (4, true) and actionMajor("v5.0.1") == (5, true).
// The ok flag is false when no major can be parsed, so a genuine v0 major (0,
// true) stays distinguishable from an unparseable ref (0, false).
func actionMajor(ref string) (int, bool) {
	return utilities.LeadingInt(utilities.StripTagPrefix(ref))
}

// isDateTagged reports whether a dependency is versioned by an upstream
// date-stamped tag (the Debian trixie-YYYYMMDD base image).
func isDateTagged(dep common.Dependency) bool {
	return dep.Category == common.CategoryBaseImage && dep.Name == "debian"
}

// updateTier derives the final review tier for an update from the dependency's
// resting tier and whether the bump is breaking: a resting TierT1
// (security-critical) always wins and never demotes, any other dependency
// promotes to TierT2 on a breaking bump, and routine updates rest at TierT3.
func updateTier(resting common.Tier, breaking bool) common.Tier {
	if resting == common.TierT1 {
		return common.TierT1
	}
	if breaking {
		return common.TierT2
	}
	return common.TierT3
}

// fullSHARe matches a full 40-character hex git commit SHA, the supply-chain
// pinning practice isFullSHA recognizes.
var fullSHARe = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)

// isFullSHA reports whether ref is a full 40-character hex git commit SHA, the
// recommended supply-chain pinning practice.
func isFullSHA(ref string) bool {
	return fullSHARe.MatchString(ref)
}

// isFloatingBaseImage reports whether a base-image pin uses a floating tag
// that rolls upstream (amazonlinux:2023, latest, stable) and therefore merits
// a digest/date-pinning hygiene note. Digest-pinned images are exempt.
func isFloatingBaseImage(dep common.Dependency) bool {
	if dep.Category != common.CategoryBaseImage {
		return false
	}
	if dep.DigestPinned {
		return false
	}
	return isFloatingTag(dep.Version)
}

// isFloatingTag recognizes tag values that float: the literal latest/stable
// markers and bare four-digit year-majors like "2023".
func isFloatingTag(v string) bool {
	switch v {
	case "latest", "stable":
		return true
	}
	return utilities.IsAllDigits(v) && len(v) == 4
}
