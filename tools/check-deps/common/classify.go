package common

import (
	"regexp"
	"slices"
	"strings"
)

// This file contains the pure tier/status classifier. It has no network or
// filesystem access: every branch is a pure function of the dependency record
// and the VersionInfo a resolver returned, so the whole matrix is
// unit-testable.

// Classify assigns a tier and status to a pinned dependency given the latest
// upstream version. It is the single decision point that turns raw resolver
// output into an actionable record. After the two resolution guards, it
// dispatches through the tierPolicies table below, each entry of which reports
// whether it owns the dependency; the generic semver policy is the fallback.
func Classify(dep Dependency, vi VersionInfo) Resolved {
	r := Resolved{
		Dep:    dep,
		Tier:   baseTier(dep),
		Latest: vi.Version,
		Date:   vi.Date,
		Infos:  slices.Clone(vi.Infos),
	}

	// Guard: resolution failed. Never fatal; surface the reason.
	if vi.Err != nil {
		r.Status = StatusUnknown
		r.Reasons = []string{vi.Err.Error()}
		return r
	}

	// Guard: resolver returned no version to compare.
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

	// Dispatch to the policy that owns this dependency; the first match wins
	// (via the shared firstMatch primitive). classifySemver is the final
	// policy and always claims, so the dispatch always resolves to a final
	// record. The winning policy's result rides out through the predicate
	// closure, so each policy runs exactly once.
	var res Resolved
	firstMatch(tierPolicies, func(policy tierPolicy) bool {
		var claimed bool
		res, claimed = policy(r, dep)
		return claimed
	})
	return res
}

// tierPolicy is one classifier entry in the ordered tierPolicies dispatch: it
// claims a dependency (ok = true) or declines, and when it claims, produces
// the final record.
type tierPolicy func(r Resolved, dep Dependency) (Resolved, bool)

// tierPolicies is the ordered first-match-wins classifier dispatch: each
// policy claims a dependency (ok = true) or declines, and the first claim
// wins. classifySemver is the unconditional fallback and is last, so a
// dependency no earlier policy claims always resolves through it.
var tierPolicies = []tierPolicy{
	classifyFloatingBaseImage,
	classifyCIAction,
	classifyDateTag,
	classifySemver,
}

// classifyFloatingBaseImage flags floating base-image tags (amazonlinux:2023,
// latest, stable) that roll upstream as hygiene rather than a plain update. It
// reports whether the dependency is a floating base image and, when so, the
// final record.
func classifyFloatingBaseImage(r Resolved, dep Dependency) (Resolved, bool) {
	if !isFloatingBaseImage(dep) {
		return r, false
	}
	r.Status = StatusHygiene
	r.Tier = TierT2
	r.Reasons = append(r.Reasons, "floating tag "+dep.Version+": rolls upstream; consider a digest or date pin")
	return r, true
}

// classifyCIAction handles GitHub Actions pins, which are major-shorthand refs
// (@v4); it compares majors and exempts @vN pins from date-pinning hygiene. It
// reports whether the dependency is a ci-action and, when so, the final record.
func classifyCIAction(r Resolved, dep Dependency) (Resolved, bool) {
	if dep.Category != CategoryCIAction {
		return r, false
	}
	// A full-SHA ref is the recommended supply-chain pin; there is no tag
	// major to compare, so it is always current.
	if isFullSHA(dep.Version) {
		r.Status = StatusOK
		r.Infos = append(r.Infos, "full-SHA pin @"+dep.Version+"; not compared by major")
		return r, true
	}
	cur, curOK := actionMajor(dep.Version)
	latest, latestOK := actionMajor(r.Latest)
	if !curOK || !latestOK {
		r.Status = StatusUnknown
		r.Reasons = append(r.Reasons, "cannot parse action majors "+dep.Version+"/"+r.Latest)
		return r, true
	}
	if latest > cur {
		r.Status = StatusUpdate
		r.Tier = TierT2
		return r, true
	}
	r.Status = StatusOK
	r.Infos = append(r.Infos, "@"+dep.Version+" major pin; exempt from date-pinning hygiene")
	return r, true
}

// classifyDateTag handles date-stamped tags (debian trixie-YYYYMMDD-slim),
// which compare lexicographically — for fixed-width YYYYMMDD that is exactly
// numeric ordering. It reports whether the dependency is date-tagged and, when
// so, the final record.
func classifyDateTag(r Resolved, dep Dependency) (Resolved, bool) {
	if !isDateTagged(dep) {
		return r, false
	}
	cur, latest := ExtractDate(dep.Version), ExtractDate(r.Latest)
	if cur == "" || latest == "" {
		r.Status = StatusUnknown
		r.Reasons = append(r.Reasons, "cannot compare date tags "+dep.Version+"/"+r.Latest)
		return r, true
	}
	if CompareChunks(latest, cur) > 0 {
		// A newer date tag is an update, never a breaking bump; the tier rule
		// still derives the final tier from the resting one (T1 stays T1).
		r.MarkUpdate(updateTier(r.Tier, false))
		return r, true
	}
	r.Status = StatusOK
	return r, true
}

// classifySemver applies the generic semver compare to every dependency no
// policy claimed. It is the unconditional fallback policy: it always claims
// the dependency, so its ok flag is always true.
func classifySemver(r Resolved, dep Dependency) (Resolved, bool) {
	// resting is the dependency's review priority before promotion: earlier
	// dispatchers return early when they claim the dependency, so r.Tier is
	// still the untouched resting tier here.
	resting := r.Tier
	switch c := CompareSemver(dep.Version, r.Latest); {
	case c == 0:
		r.Status = StatusOK
	case c < 0:
		r.MarkUpdate(updateTier(resting, isBreakingBump(dep.Version, r.Latest)))
	default:
		// Pinned at or ahead of the latest known version: nothing to do.
		r.Status = StatusOK
	}
	return r, true
}

// updateTier derives the final review tier for an update from the dependency's
// resting tier and whether the bump is breaking, in one place: a resting TierT1
// (security-critical) always wins and never demotes, any other dependency
// promotes to TierT2 on a breaking bump, and routine updates rest at TierT3.
func updateTier(resting Tier, breaking bool) Tier {
	if resting == TierT1 {
		return TierT1
	}
	if breaking {
		return TierT2
	}
	return TierT3
}

// baseTierRule is one entry in the baseTierRules table: a category/name match
// key and the resting tier it assigns.
type baseTierRule struct {
	category, name string
	tier           Tier
}

// baseTierRules is the first-match-wins table (via the shared firstMatch
// primitive) that derives a dependency's resting review priority from its
// category and name. A rule with an empty name is the category default (it
// matches any name in the category); named rules are the security-critical
// overrides and must sit before their category's default so they win.
// script-pin and every unlisted category rest at TierT3, the fallback below
// the table.
var baseTierRules = []baseTierRule{
	{CategoryBaseImage, "", TierT1},
	{CategoryRuntime, "", TierT1},
	{CategoryBazelModule, "", TierT2},
	{CategoryToolchain, "", TierT2},
	{CategoryCIAction, "", TierT2},
	// tool-binary is T2 by default; the media server binary is the one
	// security-critical exception.
	{CategoryToolBinary, "mediamtx_dist", TierT1},
	{CategoryToolBinary, "", TierT2},
	// script-pin: the network-facing parsers and crypto/security tooling are
	// T1, the emulator is T2, everything else rests at T3.
	{CategoryScriptPin, "openssh-portable", TierT1},
	{CategoryScriptPin, "ffmpeg", TierT1},
	{CategoryScriptPin, "CUDA", TierT1},
	{CategoryScriptPin, "nv-codec-headers", TierT1},
	{CategoryScriptPin, "qemu", TierT2},
}

// baseTier returns the dependency's resting review priority. Security-critical
// surface (network services, base images, media/emulation parsers) is T1;
// build graph, toolchain, and supply chain are T2; the rest default to T3. The
// mapping is the first-match-wins baseTierRules table above, dispatched
// through the shared firstMatch primitive.
func baseTier(dep Dependency) Tier {
	rule, ok := firstMatch(baseTierRules, func(rule baseTierRule) bool {
		return dep.Category == rule.category && (rule.name == "" || dep.Name == rule.name)
	})
	if !ok {
		return TierT3
	}
	return rule.tier
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
// ok reports whether the major parsed (false when the major is missing or
// unparseable, so "missing" and "broken" inputs are distinguishable from a
// genuine zero). The minor has three distinct states, each explicit: minorSet
// reports whether the version carries a second dot component at all, and
// minorValid reports whether a present minor parsed (false when it is
// unparseable or overflows int). A single-component version like "v4" has no
// minor set, so its minor is treated as the genuine zero; callers use the pair
// to tell a genuine 0.x minor from a broken one.
func firstTwoNumeric(s string) (major, minor int, ok, minorSet, minorValid bool) {
	s = coreVersion(s)
	parts := strings.Split(s, ".")
	major, ok = leadingInt(parts[0])
	if !ok {
		return 0, 0, false, false, false
	}
	if len(parts) > 1 {
		minor, minorValid = leadingInt(parts[1])
		return major, minor, true, true, minorValid
	}
	return major, 0, true, false, true
}

// isFloatingBaseImage reports whether a base-image pin uses a floating tag
// that rolls upstream (amazonlinux:2023, latest, stable) and therefore merits
// a digest/date-pinning hygiene note. Digest-pinned images are exempt.
func isFloatingBaseImage(dep Dependency) bool {
	if dep.Category != CategoryBaseImage {
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
	return isAllDigits(v) && len(v) == 4
}

// actionMajor extracts the leading major integer from a GitHub Actions ref,
// e.g. actionMajor("v4") == (4, true) and actionMajor("v5.0.1") == (5, true).
// The ok flag is false when no major can be parsed, so a genuine v0 major (0,
// true) stays distinguishable from an unparseable ref (0, false) — mirroring
// leadingInt's (val, ok) pattern.
func actionMajor(ref string) (int, bool) {
	return leadingInt(stripTagPrefix(ref))
}

// isFullSHA reports whether ref is a full 40-character hex git commit SHA, the
// recommended supply-chain pinning practice.
func isFullSHA(ref string) bool {
	return fullSHARe.MatchString(ref)
}

// isDateTagged reports whether a dependency is versioned by an upstream
// date-stamped tag (the Debian trixie-YYYYMMDD base image).
func isDateTagged(dep Dependency) bool {
	return dep.Category == CategoryBaseImage && dep.Name == "debian"
}

// fullSHARe matches a full 40-character hex git commit SHA, the supply-chain
// pinning practice isFullSHA recognizes.
var fullSHARe = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)

// date8Re is the single 8-digit YYYYMMDD pattern. It deliberately stays a
// standalone pattern rather than deriving from SnapshotTsRe's full timestamp
// ([0-9]{8}T[0-9]{6}Z): ExtractDate must also handle plain 8-digit date tags
// (e.g. "20260901") that carry no timestamp suffix.
var date8Re = regexp.MustCompile(`[0-9]{8}`)

// ExtractDate returns the first 8-digit YYYYMMDD run inside s, or "" when
// there is none. Fixed-width dates compare correctly as strings. It is shared
// with the resolver package's DebianResolve, which reads the date out of a
// trixie-YYYYMMDD-slim tag.
func ExtractDate(s string) string {
	return date8Re.FindString(s)
}
