// Package utilities holds small, dependency-free helpers shared across the
// check-deps packages. Nothing in here may import other check-deps packages.
package utilities

import (
	"regexp"
	"strconv"
	"strings"
)

// IsAllDigits reports whether s is non-empty and consists only of ASCII
// decimal digits ('0'–'9').
func IsAllDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return len(s) > 0
}

// StripTagPrefix removes a leading run of non-digit characters so tag prefixes
// like "v" (v2.13.2) or "n" (n13.0.19.0) do not skew the numeric compare.
func StripTagPrefix(s string) string {
	i := 0
	for i < len(s) && !IsDigit(s[i]) {
		i++
	}
	return s[i:]
}

// LeadingInt returns the integer parsed from the leading digit run of s and
// whether it parsed successfully. A run that is absent or overflows int is not
// a representable integer, so it returns (0, false); any in-range digit run
// returns (value, true). Callers use the bool to distinguish a genuine 0 (e.g.
// "0" or "000") from "no digit present", so missing and broken inputs stay
// distinguishable rather than collapsing onto the same sentinel.
func LeadingInt(s string) (int, bool) {
	digits := LeadingDigits(s)
	if digits == "" {
		return 0, false // no digit run: not an integer
	}
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		return 0, true // the run was all zeros; that is a valid 0
	}
	n, err := strconv.Atoi(digits)
	if err != nil {
		return 0, false // overflow: not representable
	}
	return n, true
}

// LeadingDigits returns the leading run of ASCII decimal digits in s.
func LeadingDigits(s string) string {
	i := 0
	for i < len(s) && IsDigit(s[i]) {
		i++
	}
	return s[:i]
}

// IsDigit reports whether c is an ASCII decimal digit.
func IsDigit(c byte) bool {
	return c >= '0' && c <= '9'
}

// SplitCoreAndPre normalizes a version and splits it into its numeric core and
// its prerelease suffix ("" and false when none). Build metadata after '+' is
// dropped and a leading alphabetic tag prefix is stripped before the split.
func SplitCoreAndPre(s string) (core, pre string, hasPre bool) {
	s = StripTagPrefix(s)
	s, _, _ = strings.Cut(s, "+")
	return strings.Cut(s, "-")
}

// CoreVersion reduces a version string to its numeric core: it strips a
// leading alphabetic tag prefix, drops build metadata after '+', and cuts the
// prerelease suffix after '-'.
func CoreVersion(s string) string {
	core, _, _ := SplitCoreAndPre(s)
	return core
}

// date8Re is the single 8-digit YYYYMMDD pattern. It deliberately stays a
// standalone pattern rather than deriving from snapshotTsRe's full timestamp
// ([0-9]{8}T[0-9]{6}Z): ExtractDate must also handle plain 8-digit date tags
// (e.g. "20260901") that carry no timestamp suffix.
var date8Re = regexp.MustCompile(`[0-9]{8}`)

// ExtractDate returns the first 8-digit YYYYMMDD run inside s, or "" when
// there is none. Fixed-width dates compare correctly as strings. It is shared
// by the Debian/date-tag resolvers and the classification date-tag predicate.
func ExtractDate(s string) string {
	return date8Re.FindString(s)
}

// snapshotTsRe matches a Debian snapshot.debian.org timestamp
// (YYYYMMDDTHHMMSSZ).
var snapshotTsRe = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)

// ExtractSnapshotTs returns the first Debian snapshot.debian.org timestamp
// (YYYYMMDDTHHMMSSZ) inside s, or "" when there is none. It is used by the
// extractor side (extractorimpl's parseAPTSourcesList) to pull a single
// timestamp out of an apt.sources_list uri.
func ExtractSnapshotTs(s string) string {
	return snapshotTsRe.FindString(s)
}

// ExtractSnapshotTsAll returns every Debian snapshot.debian.org timestamp
// (YYYYMMDDTHHMMSSZ) inside s. It is used by the resolver side (resolverimpl's
// newestDebianSnapshot) to enumerate all timestamps in an archive listing and
// pick the newest.
func ExtractSnapshotTsAll(s string) []string {
	return snapshotTsRe.FindAllString(s, -1)
}
