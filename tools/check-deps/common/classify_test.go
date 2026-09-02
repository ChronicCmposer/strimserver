package common

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Phase 2 unit tests moved into the common package: pure logic only (semver
// compare, tier classification). No network is touched; every parser is
// exercised against inline fixture strings.

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

func TestStripTagPrefix(t *testing.T) {
	cases := map[string]string{
		"v2.13.2":          "2.13.2",
		"n13.0.19.0":       "13.0.19.0",
		"10.3p1":           "10.3p1",
		"20260824T082821Z": "20260824T082821Z",
	}
	for in, want := range cases {
		if got := stripTagPrefix(in); got != want {
			t.Errorf("stripTagPrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLeadingInt(t *testing.T) {
	cases := []struct {
		in     string
		want   int
		wantOK bool
	}{
		{"", 0, false},
		{"000", 0, true},
		{"63", 63, true},
		{"007", 7, true},
		{"abc", 0, false},
	}
	for _, c := range cases {
		got, ok := leadingInt(c.in)
		if got != c.want || ok != c.wantOK {
			t.Errorf("leadingInt(%q) = (%d, %v), want (%d, %v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

// --- tier classification ---------------------------------------------------

func TestClassifyBazelModuleZeroXMinorAsMajor(t *testing.T) {
	dep := Dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	// 0.x minor bump is breaking -> T2 review.
	r := Classify(dep, VersionInfo{Version: "0.64.0"})
	if r.Status != StatusUpdate || r.Tier != TierT2 {
		t.Errorf("0.x minor bump: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// 0.x patch bump is non-breaking -> T3.
	r = Classify(dep, VersionInfo{Version: "0.63.1"})
	if r.Status != StatusUpdate || r.Tier != TierT3 {
		t.Errorf("0.x patch bump: got %s/%s, want update/T3", r.Status, r.Tier)
	}
	// current at latest -> ok.
	r = Classify(dep, VersionInfo{Version: "0.63.0"})
	if r.Status != StatusOK {
		t.Errorf("current == latest: got %s, want ok", r.Status)
	}
}

func TestClassifyBazelModuleOneXMajor(t *testing.T) {
	dep := Dependency{Category: "bazel-module", Name: "gazelle", Version: "1.2.0"}
	// 1.x major bump -> T2 review.
	r := Classify(dep, VersionInfo{Version: "2.0.0"})
	if r.Status != StatusUpdate || r.Tier != TierT2 {
		t.Errorf("1.x major bump: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// 1.x minor/patch bump -> T3.
	r = Classify(dep, VersionInfo{Version: "1.3.0"})
	if r.Status != StatusUpdate || r.Tier != TierT3 {
		t.Errorf("1.x minor bump: got %s/%s, want update/T3", r.Status, r.Tier)
	}
	// 0 -> 1 transition is a major bump -> T2.
	dep = Dependency{Category: "bazel-module", Name: "rules_oci", Version: "0.9.0"}
	r = Classify(dep, VersionInfo{Version: "1.0.0"})
	if r.Status != StatusUpdate || r.Tier != TierT2 {
		t.Errorf("0 -> 1 transition: got %s/%s, want update/T2", r.Status, r.Tier)
	}
}

func TestClassifyFloatingBaseImageHygiene(t *testing.T) {
	// amazonlinux:2023 is a floating year-major -> hygiene, T2.
	dep := Dependency{Category: "base-image", Name: "amazonlinux", Version: "2023", File: "tools/openssh/publish.sh"}
	r := Classify(dep, VersionInfo{Version: "2023"})
	if r.Status != StatusHygiene || r.Tier != TierT2 {
		t.Errorf("floating base image: got %s/%s, want hygiene/T2", r.Status, r.Tier)
	}
	if len(r.Reasons) == 0 {
		t.Error("floating base image should carry a digest/date pinning reason")
	}
}

func TestClassifyFloatingLiteralBaseImageHygiene(t *testing.T) {
	// The literal latest/stable markers float upstream just like a year-major.
	for _, v := range []string{"latest", "stable"} {
		dep := Dependency{Category: "base-image", Name: "example", Version: v}
		r := Classify(dep, VersionInfo{Version: "2026"})
		if r.Status != StatusHygiene || r.Tier != TierT2 {
			t.Errorf("floating tag %q: got %s/%s, want hygiene/T2", v, r.Status, r.Tier)
		}
	}
}

func TestClassifyDigestPinnedOK(t *testing.T) {
	// alpine digest pin passes hygiene -> ok.
	dep := Dependency{Category: "base-image", Name: "alpine", DigestPinned: true}
	r := Classify(dep, VersionInfo{})
	if r.Status != StatusOK || r.Tier != TierT1 {
		t.Errorf("digest-pinned alpine: got %s/%s, want ok/T1", r.Status, r.Tier)
	}
}

func TestClassifyDebianDateTag(t *testing.T) {
	dep := Dependency{Category: "base-image", Name: "debian", Version: "20260824T082821Z"}
	// Newer date-tag -> update, T1 (security base image).
	r := Classify(dep, VersionInfo{Version: "20260901"})
	if r.Status != StatusUpdate || r.Tier != TierT1 {
		t.Errorf("newer debian date tag: got %s/%s, want update/T1", r.Status, r.Tier)
	}
	// Current date-tag -> ok.
	r = Classify(dep, VersionInfo{Version: "20260824"})
	if r.Status != StatusOK {
		t.Errorf("current debian date tag: got %s, want ok", r.Status)
	}
}

func TestClassifyFullSHAPinnedAction(t *testing.T) {
	sha := "0123456789abcdef0123456789abcdef01234567"
	dep := Dependency{Category: "ci-action", Name: "actions/checkout", Version: sha}
	r := Classify(dep, VersionInfo{Version: "v4.2.0"})
	if r.Status != StatusOK {
		t.Errorf("full-SHA action pin: got %s, want ok", r.Status)
	}
}

func TestClassifyActionV0Major(t *testing.T) {
	// A genuine v0 current with a v0 latest is a real major 0, not an unknown:
	// the old actionMajor collapsed "0" and "unparseable" onto the same 0
	// sentinel, so a v0 pin was misreported as unknown. With the (major, ok)
	// form, v0/v0 parses cleanly and resolves to ok.
	dep := Dependency{Category: "ci-action", Name: "example/action", Version: "v0"}
	r := Classify(dep, VersionInfo{Version: "v0"})
	if r.Status != StatusOK {
		t.Errorf("v0 current + v0 latest: got %s, want ok (genuine major 0, not unknown)", r.Status)
	}

	// An unparseable ref still resolves to unknown with the parse reason.
	dep = Dependency{Category: "ci-action", Name: "example/action", Version: "not-a-ref"}
	r = Classify(dep, VersionInfo{Version: "v4"})
	if r.Status != StatusUnknown {
		t.Errorf("unparseable current: got %s, want unknown", r.Status)
	}
	if len(r.Reasons) == 0 || !strings.Contains(r.Reasons[0], "cannot parse action majors") {
		t.Errorf("unparseable current should carry the parse reason, got reasons=%v", r.Reasons)
	}
}

func TestClassifyGitHubActionExemption(t *testing.T) {
	dep := Dependency{Category: "ci-action", Name: "actions/checkout", Version: "v4"}
	// Newer major exists -> update, T2.
	r := Classify(dep, VersionInfo{Version: "v5.0.1"})
	if r.Status != StatusUpdate || r.Tier != TierT2 {
		t.Errorf("newer action major: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// Same major (newer patch within v4) -> ok, exempt from hygiene.
	r = Classify(dep, VersionInfo{Version: "v4.2.0"})
	if r.Status != StatusOK {
		t.Errorf("same action major: got %s, want ok", r.Status)
	}
	foundExemption := false
	for _, info := range r.Infos {
		if strings.Contains(info, "exempt from date-pinning hygiene") {
			foundExemption = true
		}
	}
	if !foundExemption {
		t.Errorf("same-major action should record the hygiene exemption, got infos=%v", r.Infos)
	}
}

func TestClassifyT1BreakingBumpStaysT1(t *testing.T) {
	// A security-critical (T1) base image with a breaking major bump must
	// resolve to T1, never demote to the breaking-bump T2 promotion. T1 is
	// the resting priority and always wins.
	dep := Dependency{Category: "base-image", Name: "ubuntu", Version: "1.0.0"}
	r := Classify(dep, VersionInfo{Version: "2.0.0"})
	if r.Status != StatusUpdate || r.Tier != TierT1 {
		t.Errorf("T1 breaking bump: got %s/%s, want update/T1", r.Status, r.Tier)
	}
}

func TestClassifyUpdateEscalatesSecurityToT1(t *testing.T) {
	dep := Dependency{Category: "script-pin", Name: "openssh-portable", Version: "10.3p1"}
	r := Classify(dep, VersionInfo{Version: "10.4p1"})
	if r.Status != StatusUpdate || r.Tier != TierT1 {
		t.Errorf("security dep update: got %s/%s, want update/T1", r.Status, r.Tier)
	}
}

func TestClassifyUnknownOnNetworkFailure(t *testing.T) {
	dep := Dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	r := Classify(dep, VersionInfo{Err: errTestNetwork})
	if r.Status != StatusUnknown {
		t.Errorf("resolver failure: got %s, want unknown", r.Status)
	}
	if len(r.Reasons) == 0 {
		t.Error("unknown resolution must carry a reason")
	}
}

// errTestNetwork is a sentinel used only in unit tests.
var errTestNetwork = errorString("test network failure")

type errorString string

func (e errorString) Error() string { return string(e) }

func TestFirstTwoNumericStates(t *testing.T) {
	cases := []struct {
		in           string
		major, minor int
		ok           bool
		minorSet     bool
		minorValid   bool
	}{
		{"0.63.0", 0, 63, true, true, true},
		{"1.2.0", 1, 2, true, true, true},
		{"v4", 4, 0, true, false, true}, // single-component version: no minor, treated as 0
		{"0", 0, 0, true, false, true},
		{"0.broken", 0, 0, true, true, false},               // present minor unparseable
		{"0.99999999999999999999", 0, 0, true, true, false}, // present minor overflows int
		{"abc", 0, 0, false, false, false},
		{"", 0, 0, false, false, false},
	}
	for _, c := range cases {
		major, minor, ok, minorSet, minorValid := firstTwoNumeric(c.in)
		if major != c.major || minor != c.minor || ok != c.ok || minorSet != c.minorSet || minorValid != c.minorValid {
			t.Errorf("firstTwoNumeric(%q) = (%d, %d, %v, %v, %v), want (%d, %d, %v, %v, %v)",
				c.in, major, minor, ok, minorSet, minorValid, c.major, c.minor, c.ok, c.minorSet, c.minorValid)
		}
	}
}

func TestIsBreakingBump(t *testing.T) {
	// On the 0.x axis the minor is the breaking axis.
	if !isBreakingBump("0.63.0", "0.64.0") {
		t.Error("0.x minor bump should be breaking")
	}
	if isBreakingBump("0.63.0", "0.63.1") {
		t.Error("0.x patch bump should not be breaking")
	}
	// A single-component 0.x version has no minor and compares with minor 0.
	if !isBreakingBump("0", "0.1.0") {
		t.Error("0 -> 0.1.0 should be a breaking minor bump")
	}
	// A minor that is present but unparseable/overflowing must be treated as
	// non-breaking, never silently escalating a review.
	if isBreakingBump("0.broken", "0.1.0") {
		t.Error("broken current minor must not be breaking")
	}
	if isBreakingBump("0.1.0", "0.broken") {
		t.Error("broken latest minor must not be breaking")
	}
	// On the 1.x axis only a major bump breaks; the 0 -> 1 transition too.
	if !isBreakingBump("1.2.0", "2.0.0") {
		t.Error("1.x major bump should be breaking")
	}
	if isBreakingBump("1.2.0", "1.3.0") {
		t.Error("1.x minor bump should not be breaking")
	}
	if !isBreakingBump("0.9.0", "1.0.0") {
		t.Error("0 -> 1 transition should be breaking")
	}
}

// --- fetcher size cap ------------------------------------------------------

func TestFetchBytesRejectsOversizedBody(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("0123456789ABCDEF")) // 16 bytes
	}))
	defer ts.Close()

	f := &Fetcher{Client: ts.Client(), MaxBytes: 8}
	_, err := f.FetchBytes(ts.URL)
	if err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("oversized body: got err=%v, want one mentioning 'exceeds'", err)
	}
}

func TestFetchBytesAcceptsWithinLimit(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("small"))
	}))
	defer ts.Close()

	f := &Fetcher{Client: ts.Client(), MaxBytes: 1024}
	data, err := f.FetchBytes(ts.URL)
	if err != nil || string(data) != "small" {
		t.Errorf("within-limit body: data=%q err=%v", data, err)
	}
}
