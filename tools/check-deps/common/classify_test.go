package common

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"strimserver-check-deps/utilities"
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
		if got := utilities.StripTagPrefix(in); got != want {
			t.Errorf("StripTagPrefix(%q) = %q, want %q", in, got, want)
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
		got, ok := utilities.LeadingInt(c.in)
		if got != c.want || ok != c.wantOK {
			t.Errorf("LeadingInt(%q) = (%d, %v), want (%d, %v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

// --- tier classification ---------------------------------------------------

func TestClassifyUnknownOnNetworkFailure(t *testing.T) {
	c := NewClassifier(nil, nil)
	dep := Dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	r := c.Classify(dep, VersionInfo{Err: errTestNetwork})
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
