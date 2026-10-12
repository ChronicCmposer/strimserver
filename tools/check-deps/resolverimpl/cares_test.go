package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestNormalizeCaresTag pins c-ares's "v1.34.8" tag convention: only the
// leading v is stripped.
func TestNormalizeCaresTag(t *testing.T) {
	cases := []struct {
		tag     string
		want    string
		wantErr bool
	}{
		{"v1.34.8", "1.34.8", false},
		{"1.34.8", "1.34.8", false},
		{"v", "", true},
		{"", "", true},
	}
	for _, tc := range cases {
		got, err := normalizeCaresTag(tc.tag)
		if tc.wantErr {
			if err == nil {
				t.Errorf("normalizeCaresTag(%q): want error, got %q", tc.tag, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("normalizeCaresTag(%q): unexpected error %v", tc.tag, err)
			continue
		}
		if got != tc.want {
			t.Errorf("normalizeCaresTag(%q) = %q, want %q", tc.tag, got, tc.want)
		}
	}
}

func TestParseCaresRelease(t *testing.T) {
	const release = `{"tag_name": "v1.34.8", "published_at": "2026-07-01T00:00:00Z"}`
	vi, err := parseCaresRelease([]byte(release))
	if err != nil {
		t.Fatalf("parseCaresRelease: %v", err)
	}
	if vi.Version != "1.34.8" {
		t.Errorf("parseCaresRelease version = %q, want 1.34.8", vi.Version)
	}
}

func TestCaresResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/c-ares/c-ares/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"v1.34.8","published_at":"2026-07-01T00:00:00Z"}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := CaresResolve(f)(common.Dependency{Category: common.CategoryToolBinary, Name: "cares", Version: "1.34.8"})
	if vi.Err != nil {
		t.Fatalf("CaresResolve: %v", vi.Err)
	}
	if vi.Version != "1.34.8" {
		t.Errorf("CaresResolve version = %q, want 1.34.8", vi.Version)
	}
}
