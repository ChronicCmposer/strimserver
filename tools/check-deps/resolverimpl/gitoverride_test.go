package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestGitHubRemoteOwnerRepo pins the remote grammar: every GitHub remote form
// parses to owner/repo, and a non-GitHub or malformed remote refuses (ok
// false) so the registry falls through to BCR instead of guessing.
func TestGitHubRemoteOwnerRepo(t *testing.T) {
	cases := []struct {
		remote string
		owner  string
		repo   string
		ok     bool
	}{
		{"https://github.com/ChronicCmposer/stackctl.git", "ChronicCmposer", "stackctl", true},
		{"https://github.com/ChronicCmposer/stackctl", "ChronicCmposer", "stackctl", true},
		{"ssh://git@github.com/ChronicCmposer/stackctl.git", "ChronicCmposer", "stackctl", true},
		{"git@github.com:ChronicCmposer/stackctl", "ChronicCmposer", "stackctl", true},
		{"ssh://git@git.cmposer.cc/stackctl.git", "", "", false},
		{"https://gitlab.com/foo/bar.git", "", "", false},
		{"", "", "", false},
	}
	for _, tc := range cases {
		owner, repo, ok := GitHubRemoteOwnerRepo(tc.remote)
		if ok != tc.ok || owner != tc.owner || repo != tc.repo {
			t.Errorf("GitHubRemoteOwnerRepo(%q) = %q, %q, %v; want %q, %q, %v",
				tc.remote, owner, repo, ok, tc.owner, tc.repo, tc.ok)
		}
	}
}

// TestParseGitOverrideTags pins the pure parser: only semver tags survive
// (leading v stripped), and the page size drives the pagination walk.
func TestParseGitOverrideTags(t *testing.T) {
	const page = `[
		{"name": "v0.1.25"},
		{"name": "v0.1.9"},
		{"name": "release-2026-11-01"},
		{"name": "main-nightly"}
	]`
	versions, size, err := parseGitOverrideTags([]byte(page))
	if err != nil {
		t.Fatalf("parseGitOverrideTags: %v", err)
	}
	if size != 4 {
		t.Errorf("parseGitOverrideTags page size = %d, want 4", size)
	}
	if len(versions) != 2 || versions[0] != "0.1.25" || versions[1] != "0.1.9" {
		t.Errorf("parseGitOverrideTags versions = %v, want [0.1.25 0.1.9]", versions)
	}
}

// TestGitOverrideResolveLatestOnMain exercises the full resolver: the repo's
// newest semver tag is on main (compare status "identical"), so it is
// reported as the latest.
func TestGitOverrideResolveLatestOnMain(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/ChronicCmposer/stackctl/tags":
			w.Write([]byte(`[{"name":"v0.1.25"},{"name":"v0.1.9"}]`))
		case "/repos/ChronicCmposer/stackctl/compare/v0.1.25...main":
			w.Write([]byte(`{"status":"identical"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := GitOverrideResolve(f)(common.Dependency{
		Category: common.CategoryBazelModule,
		Name:     "stackctl",
		Version:  "0.1.25",
		Source:   "https://github.com/ChronicCmposer/stackctl.git",
	})
	if vi.Err != nil {
		t.Fatalf("GitOverrideResolve: %v", vi.Err)
	}
	if vi.Version != "0.1.25" {
		t.Errorf("GitOverrideResolve version = %q, want 0.1.25", vi.Version)
	}
}

// TestGitOverrideResolveSkipsOffMainTags pins the on-main requirement under
// the real compare/{tag}...main semantics: the newest tag lives on a release
// branch, so GitHub reports main as "behind" that tag (the tag is off-main);
// the resolver walks down to the next tag, which main is "ahead" of (the tag
// is an ancestor, hence on main) and reports it.
func TestGitOverrideResolveSkipsOffMainTags(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/ChronicCmposer/stackctl/tags":
			w.Write([]byte(`[{"name":"v0.2.0"},{"name":"v0.1.25"}]`))
		case "/repos/ChronicCmposer/stackctl/compare/v0.2.0...main":
			w.Write([]byte(`{"status":"behind"}`))
		case "/repos/ChronicCmposer/stackctl/compare/v0.1.25...main":
			w.Write([]byte(`{"status":"ahead"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := GitOverrideResolve(f)(common.Dependency{
		Category: common.CategoryBazelModule,
		Name:     "stackctl",
		Version:  "0.1.25",
		Source:   "git@github.com:ChronicCmposer/stackctl",
	})
	if vi.Err != nil {
		t.Fatalf("GitOverrideResolve: %v", vi.Err)
	}
	if vi.Version != "0.1.25" {
		t.Errorf("GitOverrideResolve version = %q, want 0.1.25 (v0.2.0 is off-main)", vi.Version)
	}
}

// TestGitOverrideResolveAcceptsAncestorTag is the regression for the inverted
// compare semantics that made every on-main tag look off-main. It mirrors the
// live stackctl case: compare/v0.2.0...main returns "ahead" because main is
// one commit ahead of the tag, and merge_base_commit equals base_commit, so
// v0.2.0 is unambiguously an ancestor of main and must be reported as latest.
func TestGitOverrideResolveAcceptsAncestorTag(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/ChronicCmposer/stackctl/tags":
			w.Write([]byte(`[{"name":"v0.2.0"},{"name":"v0.1.25"}]`))
		case "/repos/ChronicCmposer/stackctl/compare/v0.2.0...main":
			w.Write([]byte(`{"status":"ahead","ahead_by":1,"behind_by":0,` +
				`"base_commit":{"sha":"34badacf99bf69e7fc772126561df5d4003e339f"},` +
				`"merge_base_commit":{"sha":"34badacf99bf69e7fc772126561df5d4003e339f"}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := GitOverrideResolve(f)(common.Dependency{
		Category: common.CategoryBazelModule,
		Name:     "stackctl",
		Version:  "0.2.0",
		Source:   "https://github.com/ChronicCmposer/stackctl.git",
	})
	if vi.Err != nil {
		t.Fatalf("GitOverrideResolve: %v", vi.Err)
	}
	if vi.Version != "0.2.0" {
		t.Errorf("GitOverrideResolve version = %q, want 0.2.0 (v0.2.0 is on main)", vi.Version)
	}
}

// TestGitOverrideResolveNoTagOnMain fails loud: when every candidate tag is
// off-main (or the compare endpoint is unreachable), the resolver reports an
// unknown rather than silently recommending an off-main tag.
func TestGitOverrideResolveNoTagOnMain(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/repos/ChronicCmposer/stackctl/tags" {
			w.Write([]byte(`[{"name":"v0.2.0"},{"name":"v0.1.25"}]`))
			return
		}
		http.NotFound(w, r)
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := GitOverrideResolve(f)(common.Dependency{
		Category: common.CategoryBazelModule,
		Name:     "stackctl",
		Version:  "0.1.25",
		Source:   "https://github.com/ChronicCmposer/stackctl.git",
	})
	if vi.Err == nil {
		t.Fatalf("GitOverrideResolve = %q, want an error when no tag is on main", vi.Version)
	}
}

// TestGitOverrideResolveNonGitHubRemoteFailsLoud pins the guard clause: a
// bazel-module dep whose Source is not a GitHub remote errors immediately
// instead of scraping some other host.
func TestGitOverrideResolveNonGitHubRemoteFailsLoud(t *testing.T) {
	vi := GitOverrideResolve(nil)(common.Dependency{
		Category: common.CategoryBazelModule,
		Name:     "stackctl",
		Source:   "ssh://git@git.cmposer.cc/stackctl.git",
	})
	if vi.Err == nil {
		t.Fatalf("GitOverrideResolve = %q, want an error for a non-GitHub remote", vi.Version)
	}
}
