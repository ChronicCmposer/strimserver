package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestNormalizeFishTag pins fish's "4.3.1" tag convention (an optional leading
// v is tolerated).
func TestNormalizeFishTag(t *testing.T) {
	cases := []struct {
		tag     string
		want    string
		wantErr bool
	}{
		{"4.3.1", "4.3.1", false},
		{"v4.3.1", "4.3.1", false},
		{"v", "", true},
		{"", "", true},
	}
	for _, tc := range cases {
		got, err := normalizeFishTag(tc.tag)
		if tc.wantErr {
			if err == nil {
				t.Errorf("normalizeFishTag(%q): want error, got %q", tc.tag, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("normalizeFishTag(%q): unexpected error %v", tc.tag, err)
			continue
		}
		if got != tc.want {
			t.Errorf("normalizeFishTag(%q) = %q, want %q", tc.tag, got, tc.want)
		}
	}
}

func TestParseFishRelease(t *testing.T) {
	const release = `{"tag_name": "4.3.1", "published_at": "2026-06-01T00:00:00Z"}`
	vi, err := parseFishRelease([]byte(release))
	if err != nil {
		t.Fatalf("parseFishRelease: %v", err)
	}
	if vi.Version != "4.3.1" {
		t.Errorf("parseFishRelease version = %q, want 4.3.1", vi.Version)
	}
}

func TestFishResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/fish-shell/fish-shell/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"4.3.1","published_at":"2026-06-01T00:00:00Z"}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := FishResolve(f)(common.Dependency{Category: common.CategoryScriptPin, Name: "fish", Version: "4.3.1"})
	if vi.Err != nil {
		t.Fatalf("FishResolve: %v", vi.Err)
	}
	if vi.Version != "4.3.1" {
		t.Errorf("FishResolve version = %q, want 4.3.1", vi.Version)
	}
}
