package main

import (
	"regexp"
	"strconv"
	"strings"
)

// This file contains the pure tier/status classifier. It has no network or
// filesystem access: every branch is a pure function of the dependency record
// and the versionInfo a resolver returned, so the whole matrix is unit-testable.

// classify assigns a tier and status to a pinned dependency given the latest
// upstream version. It is the single decision point that turns raw resolver
// output into an actionable record.
func classify(dep dependency, vi versionInfo) resolved {
	r := resolved{
		Dep:    dep,
		Tier:   baseTier(dep),
		Latest: vi.version,
		Date:   vi.date,
		Infos:  append([]string(nil), vi.infos...),
	}

	// Guard: resolution failed. Never fatal; surface the reason.
	if vi.err != nil {
		r.Status = statusUnknown
		r.Reasons = []string{vi.err.Error()}
		return r
	}

	// Guard: resolver returned no version to compare.
	if vi.version == "" {
		if dep.Note == "digest-pinned" {
			r.Status = statusOK
			r.Reasons = append(r.Reasons, "digest-pinned; no tag to compare")
			return r
		}
		r.Status = statusUnknown
		r.Reasons = []string{"no latest version returned by resolver"}
		return r
	}

	// Floating base-image tags (amazonlinux:2023, latest, stable) roll
	// upstream; flag as hygiene rather than a plain update.
	if isFloatingBaseImage(dep) {
		r.Status = statusHygiene
		r.Tier = tierT2
		r.Reasons = append(r.Reasons, "floating tag "+dep.Version+": rolls upstream; consider a digest or date pin")
		return r
	}

	// GitHub Actions pins are major-shorthand refs (@v4); compare majors and
	// exempt @vN pins from date-pinning hygiene.
	if dep.Category == "ci-action" {
		cur, latest := actionMajor(dep.Version), actionMajor(r.Latest)
		if latest == 0 {
			r.Status = statusUnknown
			r.Reasons = append(r.Reasons, "cannot parse action majors "+dep.Version+"/"+r.Latest)
			return r
		}
		if latest > cur {
			r.Status = statusUpdate
			r.Tier = tierT2
			return r
		}
		r.Status = statusOK
		r.Infos = append(r.Infos, "@"+dep.Version+" major pin; exempt from date-pinning hygiene")
		return r
	}

	// Date-stamped tags (debian trixie-YYYYMMDD-slim) compare lexicographically,
	// which for fixed-width YYYYMMDD is exactly numeric ordering.
	if isDateTagged(dep) {
		cur, latest := extractDate(dep.Version), extractDate(r.Latest)
		if cur == "" || latest == "" {
			r.Status = statusUnknown
			r.Reasons = append(r.Reasons, "cannot compare date tags "+dep.Version+"/"+r.Latest)
			return r
		}
		if compareChunks(latest, cur) > 0 {
			r.Status = statusUpdate
			r.Tier = tierT3
			if baseTier(dep) == tierT1 {
				r.Tier = tierT1
			}
			return r
		}
		r.Status = statusOK
		return r
	}

	// Generic semver compare.
	switch c := compareSemver(dep.Version, r.Latest); {
	case c == 0:
		r.Status = statusOK
	case c < 0:
		r.Status = statusUpdate
		r.Tier = tierT3
		if isBreakingBump(dep.Version, r.Latest) {
			r.Tier = tierT2
		}
		if baseTier(dep) == tierT1 {
			r.Tier = tierT1
		}
	default:
		// Pinned at or ahead of the latest known version: nothing to do.
		r.Status = statusOK
	}
	return r
}

// baseTier returns the dependency's resting review priority. Security-critical
// surface (network services, base images, media/emulation parsers) is T1;
// build graph, toolchain, and supply chain are T2; the rest default to T3.
func baseTier(dep dependency) tier {
	switch dep.Category {
	case "base-image", "runtime":
		return tierT1
	case "bazel-module", "toolchain", "ci-action":
		return tierT2
	case "tool-binary":
		if dep.Name == "mediamtx_dist" {
			return tierT1
		}
		return tierT2
	case "script-pin":
		switch dep.Name {
		case "openssh-portable", "ffmpeg", "CUDA", "nv-codec-headers":
			return tierT1
		case "qemu":
			return tierT2
		}
		return tierT3
	}
	return tierT3
}

// isBreakingBump reports whether moving from cur to latest is a breaking
// (review-worthy) change. For Bazel modules on the 0.x line, the minor is the
// breaking axis (0.x minor-as-major); for 1.x+ only a major bump breaks. A
// 0 -> 1 major transition also breaks.
func isBreakingBump(cur, latest string) bool {
	curMaj, curMin := firstTwoNumeric(cur)
	latestMaj, latestMin := firstTwoNumeric(latest)
	if curMaj < 0 || latestMaj < 0 {
		return false
	}
	if curMaj == 0 && latestMaj == 0 {
		return latestMin > curMin
	}
	return latestMaj > curMaj
}

// firstTwoNumeric parses the leading major and minor integers from a version,
// returning -1 for a component that could not be parsed.
func firstTwoNumeric(s string) (int, int) {
	s = stripTagPrefix(s)
	s, _, _ = strings.Cut(s, "+")
	s, _, _ = strings.Cut(s, "-")
	parts := strings.Split(s, ".")
	parse := func(p string) int {
		p = strings.TrimLeft(p, "0")
		i := 0
		for i < len(p) && isDigit(p[i]) {
			i++
		}
		p = p[:i]
		if p == "" {
			return 0
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return -1
		}
		return n
	}
	major := parse(parts[0])
	minor := 0
	if len(parts) > 1 {
		minor = parse(parts[1])
	}
	return major, minor
}

// isFloatingBaseImage reports whether a base-image pin uses a floating tag
// that rolls upstream (amazonlinux:2023, latest, stable) and therefore merits
// a digest/date-pinning hygiene note. Digest-pinned images are exempt.
func isFloatingBaseImage(dep dependency) bool {
	if dep.Category != "base-image" {
		return false
	}
	if dep.Note == "digest-pinned" {
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
// e.g. actionMajor("v4") == 4 and actionMajor("v5.0.1") == 5.
func actionMajor(ref string) int {
	s := strings.TrimLeft(stripTagPrefix(ref), "0")
	i := 0
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	if s[:i] == "" {
		return 0
	}
	n, _ := strconv.Atoi(s[:i])
	return n
}

// isDateTagged reports whether a dependency is versioned by an upstream
// date-stamped tag (the Debian trixie-YYYYMMDD base image).
func isDateTagged(dep dependency) bool {
	return dep.Category == "base-image" && dep.Name == "debian"
}

var date8Re = regexp.MustCompile(`[0-9]{8}`)

// extractDate returns the first 8-digit YYYYMMDD run inside s, or "" when
// there is none. Fixed-width dates compare correctly as strings.
func extractDate(s string) string {
	return date8Re.FindString(s)
}
