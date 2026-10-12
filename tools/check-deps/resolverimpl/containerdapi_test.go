package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestParseContainerdAPITags pins the pure parser: from a GitHub tags page it
// returns only the api/v* subtree versions (prefix stripped) plus the page
// size. The generic githubDep would take tags[0] (a whole-repo v2.x tag), which
// is why containerd_api needs its own prefix filter.
func TestParseContainerdAPITags(t *testing.T) {
	const page = `[
		{"name": "v2.4.1"},
		{"name": "api/v1.12.0"},
		{"name": "api/v1.11.1"},
		{"name": "v2.3.5"}
	]`
	versions, size, err := parseContainerdAPITags([]byte(page))
	if err != nil {
		t.Fatalf("parseContainerdAPITags: %v", err)
	}
	if size != 4 {
		t.Errorf("parseContainerdAPITags page size = %d, want 4", size)
	}
	if len(versions) != 2 || versions[0] != "1.12.0" || versions[1] != "1.11.1" {
		t.Errorf("parseContainerdAPITags versions = %v, want [1.12.0 1.11.1]", versions)
	}
	// A page with no api/v* tags is not an error, just empty.
	versions, size, err = parseContainerdAPITags([]byte(`[{"name":"v2.4.1"}]`))
	if err != nil {
		t.Fatalf("parseContainerdAPITags(non-api): %v", err)
	}
	if len(versions) != 0 || size != 1 {
		t.Errorf("non-api page: versions=%v size=%d, want [] 1", versions, size)
	}
}

// TestLatestContainerdAPIVersion pins the newest-selection and the fail-loud
// empty case.
func TestLatestContainerdAPIVersion(t *testing.T) {
	got, err := latestContainerdAPIVersion([]string{"1.11.1", "1.12.0", "1.9.0"})
	if err != nil {
		t.Fatalf("latestContainerdAPIVersion: %v", err)
	}
	if got != "1.12.0" {
		t.Errorf("latestContainerdAPIVersion = %q, want 1.12.0", got)
	}
	if _, err := latestContainerdAPIVersion(nil); err == nil {
		t.Error("latestContainerdAPIVersion(empty) should error")
	}
}

// TestContainerdAPIResolveHostRewrite exercises the network wrapper: it lists
// the repo tags and filters api/v* to 1.12.0. The first page is short, so the
// pagination loop stops after one request.
func TestContainerdAPIResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/containerd/containerd/tags" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`[{"name":"v2.4.1"},{"name":"api/v1.12.0"},{"name":"api/v1.11.1"}]`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := ContainerdAPIResolve(f)(common.Dependency{Category: common.CategoryToolBinary, Name: "containerd_api", Version: "1.12.0"})
	if vi.Err != nil {
		t.Fatalf("ContainerdAPIResolve: %v", vi.Err)
	}
	if vi.Version != "1.12.0" {
		t.Errorf("ContainerdAPIResolve version = %q, want 1.12.0", vi.Version)
	}
}

// TestContainerdAPIResolvePaginates pins the multi-page walk: the first page is
// full (per_page entries) and carries no api/v* tags, so the second page must
// be fetched to find the api/v1.12.0 tag.
func TestContainerdAPIResolvePaginates(t *testing.T) {
	fullPage := `[`
	for i := 0; i < containerdAPIPerPage; i++ {
		if i > 0 {
			fullPage += ","
		}
		fullPage += `{"name":"v2.4.1"}`
	}
	fullPage += `]`

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Query().Get("page") {
		case "1":
			w.Write([]byte(fullPage))
		case "2":
			w.Write([]byte(`[{"name":"api/v1.12.0"}]`))
		default:
			w.Write([]byte(`[]`))
		}
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := ContainerdAPIResolve(f)(common.Dependency{Name: "containerd_api"})
	if vi.Err != nil {
		t.Fatalf("ContainerdAPIResolve paginated: %v", vi.Err)
	}
	if vi.Version != "1.12.0" {
		t.Errorf("ContainerdAPIResolve paginated version = %q, want 1.12.0", vi.Version)
	}
}
