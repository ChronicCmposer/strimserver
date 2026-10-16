package resolverimpl

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// resolversHostRewrite redirects every request to the httptest server so a
// resolver's hardcoded upstream URL (api.github.com, go.dev, nodejs.org,
// registry.npmjs.org) reaches the fixture. It preserves the request path and
// query; only scheme and host change. It is the shared test-only RoundTripper
// for the resolver wrappers added in this change.
type resolversHostRewrite struct {
	scheme, host string
	base         http.RoundTripper
}

func (rt *resolversHostRewrite) RoundTrip(req *http.Request) (*http.Response, error) {
	clone := req.Clone(req.Context())
	clone.URL.Scheme = rt.scheme
	clone.URL.Host = rt.host
	return rt.base.RoundTrip(clone)
}

// newResolversTestFetcher builds a Fetcher whose client rewrites every host to
// the httptest server, so the network wrappers run against inline fixtures with
// no real network.
func newResolversTestFetcher(ts *httptest.Server) *common.Fetcher {
	scheme, host, _ := strings.Cut(ts.URL, "://")
	client := ts.Client()
	client.Transport = &resolversHostRewrite{scheme: scheme, host: host, base: http.DefaultTransport}
	return &common.Fetcher{
		Client:     client,
		UserAgent:  "resolver-test",
		MaxBytes:   1 << 20,
		RetryDelay: time.Millisecond,
		Sleep:      func(time.Duration) {},
	}
}

// TestNormalizeCurlTag pins curl's tag convention: releases are named
// "curl-8_23_0", so the prefix is stripped and the underscores become dots to
// match the "8.23.0" the extractor records. A tag with no version is an error,
// never a silent empty.
func TestNormalizeCurlTag(t *testing.T) {
	cases := []struct {
		tag     string
		want    string
		wantErr bool
	}{
		{"curl-8_23_0", "8.23.0", false},
		{"8_23_0", "8.23.0", false},
		{"curl-", "", true},
		{"", "", true},
	}
	for _, tc := range cases {
		got, err := normalizeCurlTag(tc.tag)
		if tc.wantErr {
			if err == nil {
				t.Errorf("normalizeCurlTag(%q): want error, got %q", tc.tag, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("normalizeCurlTag(%q): unexpected error %v", tc.tag, err)
			continue
		}
		if got != tc.want {
			t.Errorf("normalizeCurlTag(%q) = %q, want %q", tc.tag, got, tc.want)
		}
	}
}

// TestParseCurlRelease pins the pure bytes->version parser against an inline
// release fixture.
func TestParseCurlRelease(t *testing.T) {
	const release = `{"tag_name": "curl-8_23_0", "published_at": "2026-09-01T00:00:00Z"}`
	vi, err := parseCurlRelease([]byte(release))
	if err != nil {
		t.Fatalf("parseCurlRelease: %v", err)
	}
	if vi.Version != "8.23.0" {
		t.Errorf("parseCurlRelease version = %q, want 8.23.0", vi.Version)
	}
	if vi.Date != "2026-09-01T00:00:00Z" {
		t.Errorf("parseCurlRelease date = %q, want 2026-09-01T00:00:00Z", vi.Date)
	}
	// A release body without a tag_name is a resolution error, never a silent
	// empty version.
	if _, err := parseCurlRelease([]byte(`{"published_at": "x"}`)); err == nil {
		t.Error("parseCurlRelease without tag_name should error")
	}
}

// TestCurlResolveHostRewrite exercises the network wrapper: the hardcoded
// api.github.com URL is redirected to the fixture and the curl- tag is
// normalized to 8.23.0.
func TestCurlResolveHostRewrite(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/curl/curl/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"tag_name":"curl-8_23_0","published_at":"2026-09-01T00:00:00Z"}`))
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := CurlResolve(f)(common.Dependency{Category: common.CategoryToolBinary, Name: "curl", Version: "8.23.0"})
	if vi.Err != nil {
		t.Fatalf("CurlResolve: %v", vi.Err)
	}
	if vi.Version != "8.23.0" {
		t.Errorf("CurlResolve version = %q, want 8.23.0", vi.Version)
	}
}

// TestResolveGitHubTaggedFallsBackToTags pins the release->tags fallback: when
// /releases/latest 404s the newest tag is normalized instead.
func TestResolveGitHubTaggedFallsBackToTags(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/curl/curl/releases/latest":
			http.NotFound(w, r)
		case "/repos/curl/curl/tags":
			w.Write([]byte(`[{"name":"curl-8_23_0"},{"name":"curl-8_21_0"}]`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	f := newResolversTestFetcher(ts)
	vi := CurlResolve(f)(common.Dependency{Name: "curl"})
	if vi.Err != nil {
		t.Fatalf("CurlResolve fallback: %v", vi.Err)
	}
	if vi.Version != "8.23.0" {
		t.Errorf("CurlResolve fallback version = %q, want 8.23.0", vi.Version)
	}
}
