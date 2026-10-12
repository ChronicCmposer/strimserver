package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestParseGoReleases pins the go.dev/dl JSON parser: only stable releases
// count, the "go" prefix is stripped, and the newest stable wins.
func TestParseGoReleases(t *testing.T) {
	const body = `[
		{"version": "go1.25.9", "stable": true},
		{"version": "go1.27rc1", "stable": false},
		{"version": "go1.26.4", "stable": true}
	]`
	got, err := parseGoReleases([]byte(body))
	if err != nil {
		t.Fatalf("parseGoReleases: %v", err)
	}
	if got != "1.26.4" {
		t.Errorf("parseGoReleases = %q, want 1.26.4", got)
	}
	// No stable release is a fail-loud error, never a silent empty.
	if _, err := parseGoReleases([]byte(`[{"version":"go1.27rc1","stable":false}]`)); err == nil {
		t.Error("parseGoReleases with no stable release should error")
	}
}

// TestParseNodeReleases pins the nodejs.org/dist/index.json parser: the newest
// LTS release wins, and the parser falls back to the newest current release
// only when the index carries no LTS entries.
func TestParseNodeReleases(t *testing.T) {
	const body = `[
		{"version": "v26.1.0", "lts": "Jod"},
		{"version": "v25.0.0", "lts": false},
		{"version": "v24.13.0", "lts": "Krypton"}
	]`
	got, err := parseNodeReleases([]byte(body))
	if err != nil {
		t.Fatalf("parseNodeReleases: %v", err)
	}
	if got != "26.1.0" {
		t.Errorf("parseNodeReleases = %q, want 26.1.0 (newest LTS)", got)
	}

	const noLTS = `[{"version":"v25.0.0","lts":false},{"version":"v23.0.0","lts":false}]`
	got, err = parseNodeReleases([]byte(noLTS))
	if err != nil {
		t.Fatalf("parseNodeReleases(no LTS): %v", err)
	}
	if got != "25.0.0" {
		t.Errorf("parseNodeReleases(no LTS) = %q, want 25.0.0 (newest current)", got)
	}
}

// TestParseNpmDistTags pins the npm packument parser: dist-tags.latest.
func TestParseNpmDistTags(t *testing.T) {
	const body = `{"name":"pnpm","dist-tags":{"latest":"10.15.0","next":"11.0.0-rc.1"}}`
	got, err := parseNpmDistTags([]byte(body))
	if err != nil {
		t.Fatalf("parseNpmDistTags: %v", err)
	}
	if got != "10.15.0" {
		t.Errorf("parseNpmDistTags = %q, want 10.15.0", got)
	}
	if _, err := parseNpmDistTags([]byte(`{"dist-tags":{}}`)); err == nil {
		t.Error("parseNpmDistTags without latest should error")
	}
}

func TestGoToolchainResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dl/" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`[{"version":"go1.26.4","stable":true}]`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := GoToolchainResolve(f)(common.Dependency{Category: common.CategoryToolchain, Name: "Go", Version: "1.26.4"})
	if vi.Err != nil {
		t.Fatalf("GoToolchainResolve: %v", vi.Err)
	}
	if vi.Version != "1.26.4" {
		t.Errorf("GoToolchainResolve version = %q, want 1.26.4", vi.Version)
	}
}

func TestNodeToolchainResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dist/index.json" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`[{"version":"v26.1.0","lts":"Jod"},{"version":"v24.13.0","lts":"Krypton"}]`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := NodeToolchainResolve(f)(common.Dependency{Category: common.CategoryToolchain, Name: "Node", Version: "24.13.0"})
	if vi.Err != nil {
		t.Fatalf("NodeToolchainResolve: %v", vi.Err)
	}
	if vi.Version != "26.1.0" {
		t.Errorf("NodeToolchainResolve version = %q, want 26.1.0", vi.Version)
	}
}

// TestNormalizeBazelTag pins Bazel's "9.2.0" tag convention.
func TestNormalizeBazelTag(t *testing.T) {
	if got, err := normalizeBazelTag("9.2.0"); err != nil || got != "9.2.0" {
		t.Errorf("normalizeBazelTag(9.2.0) = %q, %v; want 9.2.0, nil", got, err)
	}
	if got, err := normalizeBazelTag("v9.2.0"); err != nil || got != "9.2.0" {
		t.Errorf("normalizeBazelTag(v9.2.0) = %q, %v; want 9.2.0, nil", got, err)
	}
	if _, err := normalizeBazelTag(""); err == nil {
		t.Error("normalizeBazelTag(empty) should error")
	}
}

func TestBazelToolchainResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/bazelbuild/bazel/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"9.2.0","published_at":"2026-05-01T00:00:00Z"}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := BazelToolchainResolve(f)(common.Dependency{Category: common.CategoryToolchain, Name: "Bazel", Version: "9.2.0"})
	if vi.Err != nil {
		t.Fatalf("BazelToolchainResolve: %v", vi.Err)
	}
	if vi.Version != "9.2.0" {
		t.Errorf("BazelToolchainResolve version = %q, want 9.2.0", vi.Version)
	}
}

func TestPnpmToolchainResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/pnpm" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"dist-tags":{"latest":"10.15.0"}}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := PnpmToolchainResolve(f)(common.Dependency{Category: common.CategoryToolchain, Name: "pnpm", Version: "9.15.9"})
	if vi.Err != nil {
		t.Fatalf("PnpmToolchainResolve: %v", vi.Err)
	}
	if vi.Version != "10.15.0" {
		t.Errorf("PnpmToolchainResolve version = %q, want 10.15.0", vi.Version)
	}
}

// TestToolchainResolveNetworkError pins graceful degradation: a network failure
// yields VersionInfo{Err} and never panics.
func TestToolchainResolveNetworkError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	for name, resolve := range map[string]common.Resolver{
		"go":    GoToolchainResolve(f),
		"node":  NodeToolchainResolve(f),
		"bazel": BazelToolchainResolve(f),
		"pnpm":  PnpmToolchainResolve(f),
	} {
		vi := resolve(common.Dependency{Category: common.CategoryToolchain, Name: name})
		if vi.Err == nil {
			t.Errorf("%s resolver on 500: want error, got %+v", name, vi)
		}
	}
}
