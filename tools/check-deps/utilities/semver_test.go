package utilities

import "testing"

// These tests exercise only the version-comparison closure in semver.go. The
// string/date/snapshot helpers in utilities.go moved to utilities_test.go.

// --- semver compare ---------------------------------------------------------

func TestCompareSemver(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.1.0", "1.1.0", 0},
		{"1.1.0", "0.63.0", 1},
		{"0.63.0", "0.9.0", 1}, // numeric compare: 63 > 9
		{"2.13.2", "2.13.2", 0},
		{"8.2.2", "9.2.4", -1},
		{"v4", "v5", -1}, // leading v stripped
		{"n13.0.19.0", "n13.0.19.0", 0},
		{"n13.0.19.0", "n14.0.0.0", -1},
		{"10.3p1", "10.4p1", -1},
		{"10.3p1", "10.3p2", -1},
		{"1.4.19", "1.4.9", 1},
		{"1.0.0", "1.0.0-rc.1", 1}, // release > prerelease
		{"1.0.0-rc.1", "1.0.0-rc.2", -1},
		{"1.0.0-rc.1", "1.0.0-alpha.2", 1},    // rc > alpha lexically
		{"1.0.0-1", "1.0.0-alpha", -1},        // numeric prerelease < alphanumeric
		{"1.0.0+build1", "1.0.0+build2", 0},   // build metadata ignored
		{"3.19.1-r2", "3.19.1-r10", -1},       // alpine -rN: trailing digits numeric
		{"1.0.0-alpha2", "1.0.0-alpha10", -1}, // alphanumeric prerelease: trailing digits numeric
		{"1.0.0-rc.1", "1.0.0", -1},           // prerelease < release of same core
		{"1.0.0-rc", "1.0.0-rc.1", -1},        // fewer prerelease identifiers sorts first
		{"1.0.0-rc.1", "1.0.0-rc", 1},
		{"1.0.0-rc.1", "1.0.0-rc.1", 0}, // identical prereleases
		{"1.0.0-alpha", "1.0.0-1", 1},   // alphanumeric prerelease > numeric
		{"1.0.0-a1", "1.0.0-aa", -1},    // ASCII order: '1' < 'a' after equal "a" prefix
		{"1.0.0-z1", "1.0.0-zz", -1},    // ASCII order: '1' < 'z' after equal "z" prefix
		{"1.0.0-A1", "1.0.0-AA", -1},    // ASCII order: '1' < 'A' after equal "A" prefix
		{"1.0.0-Z1", "1.0.0-ZZ", -1},    // ASCII order: '1' < 'Z' after equal "Z" prefix
	}
	for _, c := range cases {
		if got := CompareSemver(c.a, c.b); got != c.want {
			t.Errorf("CompareSemver(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestCompareDateTags(t *testing.T) {
	// Fixed-width YYYYMMDD sorts correctly by the chunked compare.
	cases := []struct {
		a, b string
		want int
	}{
		{"20260824", "20260824", 0},
		{"20260824", "20260901", -1},
		{"20260901", "20260824", 1},
		{"trixie-20260824-slim", "trixie-20260901-slim", -1},
	}
	for _, c := range cases {
		if got := CompareChunks(c.a, c.b); got != c.want {
			t.Errorf("CompareChunks(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestCompareChunksEdgeCases(t *testing.T) {
	// Chunk-compare boundary behavior: empty strings sort first, zero-prefixed
	// numerics compare as 0, and divergent separators order by separator byte.
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0},
		{"", "1", -1},
		{"1", "", 1},
		{"0", "1", -1},
		{"1", "0", 1},
		{"1-2", "1.2", -1},
		{"1.2", "1-2", 1},
	}
	for _, c := range cases {
		if got := CompareChunks(c.a, c.b); got != c.want {
			t.Errorf("CompareChunks(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}
