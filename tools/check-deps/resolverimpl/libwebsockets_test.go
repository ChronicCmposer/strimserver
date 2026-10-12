package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestNormalizeLibwebsocketsTag pins libwebsockets's "v5.0.0" tag convention.
func TestNormalizeLibwebsocketsTag(t *testing.T) {
	cases := []struct {
		tag     string
		want    string
		wantErr bool
	}{
		{"v5.0.0", "5.0.0", false},
		{"5.0.0", "5.0.0", false},
		{"v", "", true},
		{"", "", true},
	}
	for _, tc := range cases {
		got, err := normalizeLibwebsocketsTag(tc.tag)
		if tc.wantErr {
			if err == nil {
				t.Errorf("normalizeLibwebsocketsTag(%q): want error, got %q", tc.tag, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("normalizeLibwebsocketsTag(%q): unexpected error %v", tc.tag, err)
			continue
		}
		if got != tc.want {
			t.Errorf("normalizeLibwebsocketsTag(%q) = %q, want %q", tc.tag, got, tc.want)
		}
	}
}

func TestParseLibwebsocketsRelease(t *testing.T) {
	const release = `{"tag_name": "v5.0.0", "published_at": "2025-11-01T00:00:00Z"}`
	vi, err := parseLibwebsocketsRelease([]byte(release))
	if err != nil {
		t.Fatalf("parseLibwebsocketsRelease: %v", err)
	}
	if vi.Version != "5.0.0" {
		t.Errorf("parseLibwebsocketsRelease version = %q, want 5.0.0", vi.Version)
	}
}

// TestLibwebsocketsResolveHostRewrite pins the canonical upstream repo: the
// request must reach warmcat/libwebsockets (the repo the MODULE.bazel
// tarball_strip_symlinks URL points at), never the warningfix fork.
func TestLibwebsocketsResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/warmcat/libwebsockets/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"v5.0.0","published_at":"2025-11-01T00:00:00Z"}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := LibwebsocketsResolve(f)(common.Dependency{Category: common.CategoryToolBinary, Name: "libwebsockets", Version: "5.0.0"})
	if vi.Err != nil {
		t.Fatalf("LibwebsocketsResolve: %v", vi.Err)
	}
	if vi.Version != "5.0.0" {
		t.Errorf("LibwebsocketsResolve version = %q, want 5.0.0", vi.Version)
	}
}
