package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"strimserver-check-deps/common"
)

// TestNormalizeMbedtlsTag pins mbedTLS's "mbedtls-3.6.7" tag convention: the
// project prefix (and an optional leading v) is stripped.
func TestNormalizeMbedtlsTag(t *testing.T) {
	cases := []struct {
		tag     string
		want    string
		wantErr bool
	}{
		{"mbedtls-3.6.7", "3.6.7", false},
		{"v3.6.7", "3.6.7", false},
		{"mbedtls-", "", true},
		{"", "", true},
	}
	for _, tc := range cases {
		got, err := normalizeMbedtlsTag(tc.tag)
		if tc.wantErr {
			if err == nil {
				t.Errorf("normalizeMbedtlsTag(%q): want error, got %q", tc.tag, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("normalizeMbedtlsTag(%q): unexpected error %v", tc.tag, err)
			continue
		}
		if got != tc.want {
			t.Errorf("normalizeMbedtlsTag(%q) = %q, want %q", tc.tag, got, tc.want)
		}
	}
}

func TestParseMbedtlsRelease(t *testing.T) {
	const release = `{"tag_name": "mbedtls-3.6.7", "published_at": "2026-08-01T00:00:00Z"}`
	vi, err := parseMbedtlsRelease([]byte(release))
	if err != nil {
		t.Fatalf("parseMbedtlsRelease: %v", err)
	}
	if vi.Version != "3.6.7" {
		t.Errorf("parseMbedtlsRelease version = %q, want 3.6.7", vi.Version)
	}
}

func TestMbedtlsResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/Mbed-TLS/mbedtls/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"mbedtls-3.6.7","published_at":"2026-08-01T00:00:00Z"}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := MbedtlsResolve(f)(common.Dependency{Category: common.CategoryToolBinary, Name: "mbedtls", Version: "3.6.7"})
	if vi.Err != nil {
		t.Fatalf("MbedtlsResolve: %v", vi.Err)
	}
	if vi.Version != "3.6.7" {
		t.Errorf("MbedtlsResolve version = %q, want 3.6.7", vi.Version)
	}
}
