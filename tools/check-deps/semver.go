package main

import (
	"strings"
)

// This file holds the hand-rolled version comparison used across the whole
// tool. The module is stdlib-only and must not import golang.org/x/mod, so
// semver semantics are implemented here with a chunked, numeric-aware compare
// that degrades gracefully on non-semver strings.

// compareSemver compares two version strings and returns -1, 0, or 1 when a
// sorts before, equal to, or after b. It strips a leading alphabetic tag
// prefix (v, n, ...), ignores build metadata after '+', compares the numeric
// core chunk-wise, and then applies semver prerelease precedence. Non-semver
// strings are compared by their numeric/alpha chunks rather than rejected.
func compareSemver(a, b string) int {
	a = stripTagPrefix(a)
	b = stripTagPrefix(b)
	// Build metadata never participates in ordering.
	a, _, _ = strings.Cut(a, "+")
	b, _, _ = strings.Cut(b, "+")
	aCore, aPre, hasPreA := strings.Cut(a, "-")
	bCore, bPre, hasPreB := strings.Cut(b, "-")
	if c := compareChunks(aCore, bCore); c != 0 {
		return c
	}
	switch {
	case !hasPreA && hasPreB:
		return 1 // a release sorts after a prerelease of the same core
	case hasPreA && !hasPreB:
		return -1
	case hasPreA && hasPreB:
		return comparePrerelease(aPre, bPre)
	}
	return 0
}

// compareChunks compares two strings by walking numeric and alphabetic runs.
// Numeric runs compare as integers (so 1.4.19 > 1.4.9) and alphabetic runs
// compare lexically; a separator like '.' advances both sides equally. This
// gives sort -V style ordering for the date tags, alpine revisions, and the
// nv-codec-header / CUDA tags the registry clients rely on.
func compareChunks(a, b string) int {
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
			if c := compareStrings(aAlpha, bAlpha); c != 0 {
				return c
			}
			a, b = a[len(aAlpha):], b[len(bAlpha):]
			continue
		}
		// Both sides sit on a separator (e.g. '.'). Versions in this tool use
		// '.' uniformly, so advance one character from each.
		a, b = a[1:], b[1:]
	}
}

// comparePrerelease orders prerelease identifiers per semver: numeric
// identifiers compare as integers and sort before alphanumeric identifiers.
func comparePrerelease(a, b string) int {
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
		return compareStrings(a, b)
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
	return compareStrings(a, b)
}

func compareStrings(a, b string) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
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
