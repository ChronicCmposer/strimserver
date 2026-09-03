package resolverimpl

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// Phase 2 unit tests: pure logic only (registry/scraper parsers), exercised
// against inline fixture strings. No network is touched.

func TestParseBCRMetadataAndLatestNonYanked(t *testing.T) {
	const metadata = `{
		"versions": ["0.62.0", "0.63.0", "0.64.0", "0.65.0"],
		"yanked_versions": {"0.64.0": "build broke"}
	}`
	versions, yanked, err := parseBCRMetadata([]byte(metadata))
	if err != nil {
		t.Fatalf("parseBCRMetadata: %v", err)
	}
	latest, err := latestNonYanked(versions, yanked)
	if err != nil {
		t.Fatalf("latestNonYanked: %v", err)
	}
	if latest != "0.65.0" {
		t.Errorf("latestNonYanked = %q, want 0.65.0 (yanked 0.64.0 skipped)", latest)
	}
}

func TestParseDockerHubTags(t *testing.T) {
	const page = `{"results": [
		{"name": "trixie-20260824-slim", "last_updated": "2026-08-24"},
		{"name": "trixie-20260901-slim", "last_updated": "2026-09-01"},
		{"name": "latest", "last_updated": "2026-09-01"}
	]}`
	tags, err := parseDockerHubTags([]byte(page))
	if err != nil {
		t.Fatalf("parseDockerHubTags: %v", err)
	}
	if len(tags) != 3 {
		t.Fatalf("parseDockerHubTags got %d tags, want 3", len(tags))
	}
	var dates []string
	for _, tag := range tags {
		if m := trixieDateTagRe.FindStringSubmatch(tag.Name); m != nil {
			dates = append(dates, m[1])
		}
	}
	newest, err := latestOf(dates, utilities.CompareChunks)
	if err != nil {
		t.Fatalf("latestOf(trixie dates): %v", err)
	}
	if newest != "20260901" {
		t.Errorf("newest trixie date = %q, want 20260901", newest)
	}
}

func TestParseGitHubReleaseAndTags(t *testing.T) {
	const release = `{"tag_name": "v2.14.0", "published_at": "2026-08-01T00:00:00Z"}`
	vi, err := parseGitHubRelease([]byte(release))
	if err != nil {
		t.Fatalf("parseGitHubRelease: %v", err)
	}
	if vi.Version != "v2.14.0" {
		t.Errorf("parseGitHubRelease version = %q, want v2.14.0", vi.Version)
	}
	const tags = `[{"name": "v2.14.0"}, {"name": "v2.13.2"}]`
	names, err := parseGitHubTags([]byte(tags))
	if err != nil {
		t.Fatalf("parseGitHubTags: %v", err)
	}
	if len(names) != 2 || names[0] != "v2.14.0" {
		t.Errorf("parseGitHubTags = %v, want [v2.14.0 v2.13.2]", names)
	}
}

func TestParsePyPIVersionAndYanked(t *testing.T) {
	const body = `{
		"info": {"version": "0.4.4"},
		"releases": {
			"0.4.3": [{"yanked": true, "yanked_reason": "broken"}],
			"0.4.4": [{"yanked": false}]
		}
	}`
	// One decode answers both the latest version and the yanked flag.
	latest, yanked, err := parsePyPIVersionAndYanked([]byte(body), "0.4.3")
	if err != nil {
		t.Fatalf("parsePyPIVersionAndYanked: %v", err)
	}
	if latest != "0.4.4" {
		t.Errorf("latest = %q, want 0.4.4", latest)
	}
	if !yanked {
		t.Error("0.4.3 should be yanked")
	}
	_, yanked, err = parsePyPIVersionAndYanked([]byte(body), "0.4.4")
	if err != nil {
		t.Fatalf("parsePyPIVersionAndYanked: %v", err)
	}
	if yanked {
		t.Error("0.4.4 should not be yanked")
	}
	// A body without info.version is a resolution error, never a silent empty.
	_, _, err = parsePyPIVersionAndYanked([]byte(`{"info": {}}`), "0.4.3")
	if err == nil || !strings.Contains(err.Error(), "info.version") {
		t.Errorf("missing info.version should error, got %v", err)
	}
}

func TestParseAPKIndex(t *testing.T) {
	const index = "C:Q1abcd\nP:iperf3\nV:3.19.1-r1\nA:x86_64\n\nC:Q2efgh\nP:musl\nV:1.2.5-r0\nA:x86_64\n\n"
	pkgs, err := parseAPKIndex([]byte(index))
	if err != nil {
		t.Fatalf("parseAPKIndex: %v", err)
	}
	if pkgs["iperf3"] != "3.19.1-r1" {
		t.Errorf("parseAPKIndex iperf3 = %q, want 3.19.1-r1", pkgs["iperf3"])
	}
	if pkgs["musl"] != "1.2.5-r0" {
		t.Errorf("parseAPKIndex musl = %q, want 1.2.5-r0", pkgs["musl"])
	}
}

func TestParseNvidiaRedistListing(t *testing.T) {
	const listing = `<a href="redistrib_12.4.1.json">redistrib_12.4.1.json</a>
		<a href="redistrib_13.0.2.json">redistrib_13.0.2.json</a>
		<a href="redistrib_13.0.3.json">redistrib_13.0.3.json</a>`
	versions, err := parseNvidiaRedistListing([]byte(listing))
	if err != nil {
		t.Fatalf("parseNvidiaRedistListing: %v", err)
	}
	latest, err := latestOf(versions, utilities.CompareChunks)
	if err != nil {
		t.Fatalf("latestOf(nvidia): %v", err)
	}
	if latest != "13.0.3" {
		t.Errorf("nvidia newest = %q, want 13.0.3", latest)
	}
}

func TestParseDebianSnapshotListing(t *testing.T) {
	const listing = `20260710T000000Z 20260824T082821Z 20260901T000000Z`
	timestamps := parseDebianSnapshotListing([]byte(listing))
	if len(timestamps) != 3 {
		t.Fatalf("parseDebianSnapshotListing got %d, want 3", len(timestamps))
	}
	newest, err := latestOf(timestamps, strings.Compare)
	if err != nil {
		t.Fatalf("latestOf(snapshot timestamps): %v", err)
	}
	if newest != "20260901T000000Z" {
		t.Errorf("newest snapshot = %q, want 20260901T000000Z", newest)
	}
}

func TestParseQemuListing(t *testing.T) {
	const listing = `<a href="qemu-8.2.2.tar.xz">qemu-8.2.2.tar.xz</a>
		<a href="qemu-9.1.0.tar.xz">qemu-9.1.0.tar.xz</a>
		<a href="qemu-9.2.4.tar.xz">qemu-9.2.4.tar.xz</a>`
	versions := parseListing([]byte(listing), qemuTarRe)
	latest, err := latestOf(versions, utilities.CompareSemver)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "9.2.4" {
		t.Errorf("qemu newest = %q, want 9.2.4", latest)
	}
}

func TestParseOpenSSHListing(t *testing.T) {
	const listing = `<a href="openssh-10.3p1.tar.gz">openssh-10.3p1.tar.gz</a>
		<a href="openssh-10.4p1.tar.gz">openssh-10.4p1.tar.gz</a>`
	versions := parseListing([]byte(listing), opensshTarRe)
	latest, err := latestOf(versions, utilities.CompareSemver)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "10.4p1" {
		t.Errorf("openssh newest = %q, want 10.4p1", latest)
	}
}

func TestParseGnuM4Listing(t *testing.T) {
	const listing = `<a href="m4-1.4.20.tar.gz">m4-1.4.20.tar.gz</a>
		<a href="m4-1.4.21.tar.gz">m4-1.4.21.tar.gz</a>`
	versions := parseListing([]byte(listing), m4TarRe)
	latest, err := latestOf(versions, utilities.CompareSemver)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "1.4.21" {
		t.Errorf("m4 newest = %q, want 1.4.21", latest)
	}
}

func TestParseFFmpegListing(t *testing.T) {
	const listing = `<a href="ffmpeg-7.1.tar.xz">ffmpeg-7.1.tar.xz</a>
		<a href="ffmpeg-8.0.tar.xz">ffmpeg-8.0.tar.xz</a>
		<a href="ffmpeg-8.0.1.tar.xz">ffmpeg-8.0.1.tar.xz</a>`
	versions := parseListing([]byte(listing), ffmpegTarRe)
	latest, err := latestOf(versions, utilities.CompareSemver)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "8.0.1" {
		t.Errorf("ffmpeg newest = %q, want 8.0.1", latest)
	}
}

// TestNewestDockerHubTag pins the newestDockerHubTag contract: the first tag
// matching the predicate wins (Docker Hub lists tags newest-first) and a
// missing match yields ok=false with a zero tag. The fetcher's hardcoded
// hub.docker.com URL is redirected to the httptest server by a test-only
// RoundTripper, so the walk runs against the fixture page with no network.
func TestNewestDockerHubTag(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"results":[{"name":"trixie-20260824-slim"},{"name":"latest"}]}`))
	}))
	defer ts.Close()

	scheme, host, _ := strings.Cut(ts.URL, "://")
	client := ts.Client()
	client.Transport = &dockerHubHostRewrite{scheme: scheme, host: host, base: http.DefaultTransport}
	f := &common.Fetcher{Client: client, MaxBytes: 1 << 20}

	trixie := func(tag dockerTag) bool { return trixieDateTagRe.MatchString(tag.Name) }
	tag, ok, err := newestDockerHubTag("debian", 5, trixie, f)
	if err != nil {
		t.Fatalf("newestDockerHubTag: %v", err)
	}
	if !ok || tag.Name != "trixie-20260824-slim" {
		t.Errorf("trixie predicate: got (%q, ok=%v), want trixie-20260824-slim, ok=true", tag.Name, ok)
	}

	tag, ok, err = newestDockerHubTag("debian", 5, func(tag dockerTag) bool { return false }, f)
	if err != nil {
		t.Fatalf("newestDockerHubTag(non-matching): %v", err)
	}
	if ok || tag != (dockerTag{}) {
		t.Errorf("non-matching predicate: got (%q, ok=%v), want zero tag, ok=false", tag.Name, ok)
	}
}

// dockerHubHostRewrite redirects every request to the httptest server, so
// fetchDockerHubTags' hardcoded hub.docker.com URL reaches the fixture. It
// preserves the request path and query; only scheme and host change.
type dockerHubHostRewrite struct {
	scheme, host string
	base         http.RoundTripper
}

func (rt *dockerHubHostRewrite) RoundTrip(req *http.Request) (*http.Response, error) {
	clone := req.Clone(req.Context())
	clone.URL.Scheme = rt.scheme
	clone.URL.Host = rt.host
	return rt.base.RoundTrip(clone)
}

// TestResolveDepDispatch pins the resolverimpl dispatch contract through the
// public API. It was rewritten from the root-phase test, which exercised
// main's matchResolver/resolveMatched wiring; those helpers live in the main
// package now, so the contract is tested directly here: a digest-pinned dep
// short-circuits through DigestResolve to ok/T1, and a dep no resolver claims
// falls back to "unknown" via the classifier with a resolution error.
func TestResolveDepDispatch(t *testing.T) {
	// Both cases hit Classify's resolution guards before any policy dispatch, so
	// no policies are needed; only the base-image resting tier is required.
	cl := common.NewClassifier(nil, []common.BaseTierRule{{Category: common.CategoryBaseImage, Tier: common.TierT1}})

	// Digests short-circuit without network: alpine is digest-pinned and must
	// resolve to ok regardless of network availability.
	alpine := common.Dependency{Category: common.CategoryBaseImage, Name: "alpine", DigestPinned: true}
	r := cl.Classify(alpine, DigestResolve(alpine))
	if r.Status != common.StatusOK || r.Tier != common.TierT1 {
		t.Errorf("alpine digest dispatch: got %s/%s, want ok/T1", r.Status, r.Tier)
	}

	// A dependency with no matching resolver becomes unknown, never a panic.
	orphan := common.Dependency{Category: common.CategoryScriptPin, Name: "no-such-pin", Version: "1.0.0"}
	r = cl.Classify(orphan, common.VersionInfo{Err: errors.New("no resolver configured for this dependency")})
	if r.Status != common.StatusUnknown {
		t.Errorf("orphan dep: got %s, want unknown", r.Status)
	}
}
