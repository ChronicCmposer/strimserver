package common

import (
	"strconv"
	"strings"
)

// This file holds the hand-rolled version comparison used across the whole
// tool. The module is stdlib-only and must not import golang.org/x/mod, so
// semver semantics are implemented here with a chunked, numeric-aware compare
// that degrades gracefully on non-semver strings.

// CompareSemver compares two version strings and returns -1, 0, or 1 when a
// sorts before, equal to, or after b. It strips a leading alphabetic tag
// prefix (v, n, ...), ignores build metadata after '+', compares the numeric
// core chunk-wise, and then applies semver prerelease precedence. Non-semver
// strings are compared by their numeric/alpha chunks rather than rejected.
func CompareSemver(a, b string) int {
	aCore, aPre, hasPreA := splitCoreAndPre(a)
	bCore, bPre, hasPreB := splitCoreAndPre(b)
	if c := CompareChunks(aCore, bCore); c != 0 {
		return c
	}
	switch {
	case !hasPreA && hasPreB:
		return 1 // a release sorts after a prerelease of the same core
	case hasPreA && !hasPreB:
		return -1
	case hasPreA && hasPreB:
		return ComparePrerelease(aPre, bPre)
	}
	return 0
}

// coreVersion reduces a version string to its numeric core: it strips a
// leading alphabetic tag prefix, drops build metadata after '+', and cuts the
// prerelease suffix after '-'. Ordering and numeric-axis parsing both operate
// on the core, so every caller normalizes through here and the
// metadata/prerelease suffixes never skew an ordering or a parse.
func coreVersion(s string) string {
	core, _, _ := splitCoreAndPre(s)
	return core
}

// splitCoreAndPre normalizes a version and splits it into its numeric core and
// its prerelease suffix ("" and false when none). Build metadata after '+' is
// dropped and a leading alphabetic tag prefix is stripped before the split, so
// CompareSemver keeps the prerelease while coreVersion discards it.
func splitCoreAndPre(s string) (core, pre string, hasPre bool) {
	s = stripTagPrefix(s)
	s, _, _ = strings.Cut(s, "+")
	return strings.Cut(s, "-")
}

// CompareChunks compares two strings by walking numeric and alphabetic runs.
// Numeric runs compare as integers (so 1.4.19 > 1.4.9) and alphabetic runs
// compare lexically; a separator like '.' advances both sides equally. This
// gives sort -V style ordering for the date tags, alpine revisions, and the
// nv-codec-header / CUDA tags the registry clients rely on.
func CompareChunks(a, b string) int {
	for {
		switch {
		case a == "" && b == "":
			return 0
		case a == "":
			return -1
		case b == "":
			return 1
		}
		aNum := leadingDigits(a)
		bNum := leadingDigits(b)
		if aNum != "" || bNum != "" {
			if c := compareBigInt(aNum, bNum); c != 0 {
				return c
			}
			a, b = a[len(aNum):], b[len(bNum):]
			continue
		}
		aAlpha := leadingLetters(a)
		bAlpha := leadingLetters(b)
		if aAlpha != "" || bAlpha != "" {
			if c := strings.Compare(aAlpha, bAlpha); c != 0 {
				return c
			}
			a, b = a[len(aAlpha):], b[len(bAlpha):]
			continue
		}
		// Both sides sit on a separator (e.g. '.'); neither is a digit or
		// letter run. Versions in this tool use '.' uniformly, so advance one
		// character from each. When the separators diverge (e.g. '.' vs '-'),
		// order by the separator byte so ordering stays well-defined and no
		// slice can underflow (a and b are both non-empty here).
		if a[0] != b[0] {
			if a[0] < b[0] {
				return -1
			}
			return 1
		}
		a, b = a[1:], b[1:]
	}
}

// ComparePrerelease orders prerelease identifiers per semver: numeric
// identifiers compare as integers and sort before alphanumeric identifiers.
func ComparePrerelease(a, b string) int {
	as := strings.Split(a, ".")
	bs := strings.Split(b, ".")
	short := len(as)
	if len(bs) < short {
		short = len(bs)
	}
	for i := 0; i < short; i++ {
		if c := comparePrereleaseIdent(as[i], bs[i]); c != 0 {
			return c
		}
	}
	switch {
	case len(as) < len(bs):
		return -1
	case len(as) > len(bs):
		return 1
	}
	return 0
}

func comparePrereleaseIdent(a, b string) int {
	aNum, bNum := isAllDigits(a), isAllDigits(b)
	switch {
	case aNum && bNum:
		return compareBigInt(a, b)
	case aNum && !bNum:
		return -1 // numeric identifiers have lower precedence than alphanumeric
	case !aNum && bNum:
		return 1
	default:
		// Alphanumeric identifiers: compare the full strings chunk-wise, the
		// same way CompareChunks orders version cores. Numeric runs compare as
		// integers and alphabetic runs lexically, so interior content is never
		// dropped and multi-run identifiers like "r10foo2" sort after "r9foo10"
		// (both run "r", then 10 > 9) instead of being mis-ordered by their
		// trailing digits.
		return CompareChunks(a, b)
	}
}

// stripTagPrefix removes a leading run of non-digit characters so tag prefixes
// like "v" (v2.13.2) or "n" (n13.0.19.0) do not skew the numeric compare.
func stripTagPrefix(s string) string {
	i := 0
	for i < len(s) && !isDigit(s[i]) {
		i++
	}
	return s[i:]
}

func leadingDigits(s string) string {
	i := 0
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	return s[:i]
}

func leadingLetters(s string) string {
	i := 0
	for i < len(s) && isLetter(s[i]) {
		i++
	}
	return s[:i]
}

// leadingInt returns the integer parsed from the leading digit run of s and
// whether it parsed successfully. A run that is absent or overflows int is not
// a representable integer, so it returns (0, false); any in-range digit run
// returns (value, true). Callers use the bool to distinguish a genuine 0 (e.g.
// "0" or "000") from "no digit present", so missing and broken inputs stay
// distinguishable rather than collapsing onto the same sentinel.
func leadingInt(s string) (int, bool) {
	digits := leadingDigits(s)
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

// compareBigInt compares two decimal strings as integers (empty == 0),
// ignoring leading zeros.
func compareBigInt(a, b string) int {
	a = strings.TrimLeft(a, "0")
	b = strings.TrimLeft(b, "0")
	switch {
	case a == "" && b == "":
		return 0
	case a == "":
		return -1
	case b == "":
		return 1
	case len(a) != len(b):
		if len(a) < len(b) {
			return -1
		}
		return 1
	}
	return strings.Compare(a, b)
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isDigit(s[i]) {
			return false
		}
	}
	return true
}

func isDigit(c byte) bool {
	return c >= '0' && c <= '9'
}

func isLetter(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}
