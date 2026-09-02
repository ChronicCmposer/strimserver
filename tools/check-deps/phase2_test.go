package main

import (
	"strings"
	"testing"
)

// Phase 2 unit tests: pure logic only (semver compare, tier classification,
// registry/scraper parsers). No network is touched; every parser is exercised
// against inline fixture strings.

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
		{"1.0.0-rc.1", "1.0.0-alpha.2", 1},  // rc > alpha lexically
		{"1.0.0-1", "1.0.0-alpha", -1},      // numeric prerelease < alphanumeric
		{"1.0.0+build1", "1.0.0+build2", 0}, // build metadata ignored
	}
	for _, c := range cases {
		if got := compareSemver(c.a, c.b); got != c.want {
			t.Errorf("compareSemver(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
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
		if got := compareChunks(c.a, c.b); got != c.want {
			t.Errorf("compareChunks(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
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
		if got := stripTagPrefix(in); got != want {
			t.Errorf("stripTagPrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

// --- tier classification ---------------------------------------------------

func TestClassifyBazelModuleZeroXMinorAsMajor(t *testing.T) {
	dep := dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	// 0.x minor bump is breaking -> T2 review.
	r := classify(dep, versionInfo{version: "0.64.0"})
	if r.Status != statusUpdate || r.Tier != tierT2 {
		t.Errorf("0.x minor bump: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// 0.x patch bump is non-breaking -> T3.
	r = classify(dep, versionInfo{version: "0.63.1"})
	if r.Status != statusUpdate || r.Tier != tierT3 {
		t.Errorf("0.x patch bump: got %s/%s, want update/T3", r.Status, r.Tier)
	}
	// current at latest -> ok.
	r = classify(dep, versionInfo{version: "0.63.0"})
	if r.Status != statusOK {
		t.Errorf("current == latest: got %s, want ok", r.Status)
	}
}

func TestClassifyBazelModuleOneXMajor(t *testing.T) {
	dep := dependency{Category: "bazel-module", Name: "gazelle", Version: "1.2.0"}
	// 1.x major bump -> T2 review.
	r := classify(dep, versionInfo{version: "2.0.0"})
	if r.Status != statusUpdate || r.Tier != tierT2 {
		t.Errorf("1.x major bump: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// 1.x minor/patch bump -> T3.
	r = classify(dep, versionInfo{version: "1.3.0"})
	if r.Status != statusUpdate || r.Tier != tierT3 {
		t.Errorf("1.x minor bump: got %s/%s, want update/T3", r.Status, r.Tier)
	}
	// 0 -> 1 transition is a major bump -> T2.
	dep = dependency{Category: "bazel-module", Name: "rules_oci", Version: "0.9.0"}
	r = classify(dep, versionInfo{version: "1.0.0"})
	if r.Status != statusUpdate || r.Tier != tierT2 {
		t.Errorf("0 -> 1 transition: got %s/%s, want update/T2", r.Status, r.Tier)
	}
}

func TestClassifyFloatingBaseImageHygiene(t *testing.T) {
	// amazonlinux:2023 is a floating year-major -> hygiene, T2.
	dep := dependency{Category: "base-image", Name: "amazonlinux", Version: "2023", File: "tools/openssh/publish.sh"}
	r := classify(dep, versionInfo{version: "2023"})
	if r.Status != statusHygiene || r.Tier != tierT2 {
		t.Errorf("floating base image: got %s/%s, want hygiene/T2", r.Status, r.Tier)
	}
	if len(r.Reasons) == 0 {
		t.Error("floating base image should carry a digest/date pinning reason")
	}
}

func TestClassifyFloatingLiteralBaseImageHygiene(t *testing.T) {
	// The literal latest/stable markers float upstream just like a year-major.
	for _, v := range []string{"latest", "stable"} {
		dep := dependency{Category: "base-image", Name: "example", Version: v}
		r := classify(dep, versionInfo{version: "2026"})
		if r.Status != statusHygiene || r.Tier != tierT2 {
			t.Errorf("floating tag %q: got %s/%s, want hygiene/T2", v, r.Status, r.Tier)
		}
	}
}

func TestClassifyDigestPinnedOK(t *testing.T) {
	// alpine digest pin passes hygiene -> ok.
	dep := dependency{Category: "base-image", Name: "alpine", Note: "digest-pinned"}
	r := classify(dep, versionInfo{})
	if r.Status != statusOK || r.Tier != tierT1 {
		t.Errorf("digest-pinned alpine: got %s/%s, want ok/T1", r.Status, r.Tier)
	}
}

func TestClassifyDebianDateTag(t *testing.T) {
	dep := dependency{Category: "base-image", Name: "debian", Version: "20260824T082821Z"}
	// Newer date-tag -> update, T1 (security base image).
	r := classify(dep, versionInfo{version: "20260901"})
	if r.Status != statusUpdate || r.Tier != tierT1 {
		t.Errorf("newer debian date tag: got %s/%s, want update/T1", r.Status, r.Tier)
	}
	// Current date-tag -> ok.
	r = classify(dep, versionInfo{version: "20260824"})
	if r.Status != statusOK {
		t.Errorf("current debian date tag: got %s, want ok", r.Status)
	}
}

func TestClassifyGitHubActionExemption(t *testing.T) {
	dep := dependency{Category: "ci-action", Name: "actions/checkout", Version: "v4"}
	// Newer major exists -> update, T2.
	r := classify(dep, versionInfo{version: "v5.0.1"})
	if r.Status != statusUpdate || r.Tier != tierT2 {
		t.Errorf("newer action major: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// Same major (newer patch within v4) -> ok, exempt from hygiene.
	r = classify(dep, versionInfo{version: "v4.2.0"})
	if r.Status != statusOK {
		t.Errorf("same action major: got %s, want ok", r.Status)
	}
	foundExemption := false
	for _, info := range r.Infos {
		if strings.Contains(info, "exempt from date-pinning hygiene") {
			foundExemption = true
		}
	}
	if !foundExemption {
		t.Errorf("same-major action should record the hygiene exemption, got infos=%v", r.Infos)
	}
}

func TestClassifyUpdateEscalatesSecurityToT1(t *testing.T) {
	dep := dependency{Category: "script-pin", Name: "openssh-portable", Version: "10.3p1"}
	r := classify(dep, versionInfo{version: "10.4p1"})
	if r.Status != statusUpdate || r.Tier != tierT1 {
		t.Errorf("security dep update: got %s/%s, want update/T1", r.Status, r.Tier)
	}
}

func TestClassifyUnknownOnNetworkFailure(t *testing.T) {
	dep := dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	r := classify(dep, versionInfo{err: errTestNetwork})
	if r.Status != statusUnknown {
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

// --- pure parser fixtures ----------------------------------------------------

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
	newest := ""
	for _, t := range tags {
		if m := trixieDateTagRe.FindStringSubmatch(t.Name); m != nil {
			if newest == "" || m[1] > newest {
				newest = m[1]
			}
		}
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
	if vi.version != "v2.14.0" {
		t.Errorf("parseGitHubRelease version = %q, want v2.14.0", vi.version)
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

func TestParsePyPI(t *testing.T) {
	const body = `{"info": {"version": "0.4.4"}}`
	version, err := parsePyPI([]byte(body))
	if err != nil {
		t.Fatalf("parsePyPI: %v", err)
	}
	if version != "0.4.4" {
		t.Errorf("parsePyPI version = %q, want 0.4.4", version)
	}
}

func TestParsePyPIYanked(t *testing.T) {
	const body = `{
		"info": {"version": "0.4.4"},
		"releases": {
			"0.4.3": [{"yanked": true, "yanked_reason": "broken"}],
			"0.4.4": [{"yanked": false}]
		}
	}`
	yanked, err := parsePyPIYanked([]byte(body), "0.4.3")
	if err != nil {
		t.Fatalf("parsePyPIYanked: %v", err)
	}
	if !yanked {
		t.Error("0.4.3 should be yanked")
	}
	yanked, err = parsePyPIYanked([]byte(body), "0.4.4")
	if err != nil {
		t.Fatalf("parsePyPIYanked: %v", err)
	}
	if yanked {
		t.Error("0.4.4 should not be yanked")
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
	latest, err := latestNVVersion(versions)
	if err != nil {
		t.Fatalf("latestNVVersion: %v", err)
	}
	if latest != "13.0.3" {
		t.Errorf("latestNVVersion = %q, want 13.0.3", latest)
	}
}

func TestParseDebianSnapshotListing(t *testing.T) {
	const listing = `20260710T000000Z 20260824T082821Z 20260901T000000Z`
	timestamps := parseDebianSnapshotListing([]byte(listing))
	if len(timestamps) != 3 {
		t.Fatalf("parseDebianSnapshotListing got %d, want 3", len(timestamps))
	}
	newest := timestamps[0]
	for _, ts := range timestamps[1:] {
		if ts > newest {
			newest = ts
		}
	}
	if newest != "20260901T000000Z" {
		t.Errorf("newest snapshot = %q, want 20260901T000000Z", newest)
	}
}

func TestParseQemuListing(t *testing.T) {
	const listing = `<a href="qemu-8.2.2.tar.xz">qemu-8.2.2.tar.xz</a>
		<a href="qemu-9.1.0.tar.xz">qemu-9.1.0.tar.xz</a>
		<a href="qemu-9.2.4.tar.xz">qemu-9.2.4.tar.xz</a>`
	versions := parseQemuListing([]byte(listing))
	latest, err := latestOf(versions)
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
	versions := parseOpenSSHListing([]byte(listing))
	latest, err := latestOf(versions)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "10.4p1" {
		t.Errorf("openssh newest = %q, want 10.4p1", latest)
	}
}

func TestParseGnuM4Listing(t *testing.T) {
	const listing = `<a href="m4-1.4.19.tar.gz">m4-1.4.19.tar.gz</a>
		<a href="m4-1.4.20.tar.gz">m4-1.4.20.tar.gz</a>`
	versions := parseGnuM4Listing([]byte(listing))
	latest, err := latestOf(versions)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "1.4.20" {
		t.Errorf("m4 newest = %q, want 1.4.20", latest)
	}
}

func TestParseFFmpegListing(t *testing.T) {
	const listing = `<a href="ffmpeg-7.1.tar.xz">ffmpeg-7.1.tar.xz</a>
		<a href="ffmpeg-8.0.tar.xz">ffmpeg-8.0.tar.xz</a>
		<a href="ffmpeg-8.0.1.tar.xz">ffmpeg-8.0.1.tar.xz</a>`
	versions := parseFFmpegListing([]byte(listing))
	latest, err := latestOf(versions)
	if err != nil {
		t.Fatalf("latestOf: %v", err)
	}
	if latest != "8.0.1" {
		t.Errorf("ffmpeg newest = %q, want 8.0.1", latest)
	}
}

// --- resolver dispatch ------------------------------------------------------

func TestResolveDepDispatch(t *testing.T) {
	// Digests short-circuit without network: alpine is digest-pinned and must
	// resolve to ok regardless of network availability.
	alpine := dependency{Category: "base-image", Name: "alpine", Note: "digest-pinned"}
	r := resolveDep(alpine)
	if r.Status != statusOK || r.Tier != tierT1 {
		t.Errorf("alpine digest dispatch: got %s/%s, want ok/T1", r.Status, r.Tier)
	}

	// A dependency with no matching resolver becomes unknown, never a panic.
	orphan := dependency{Category: "script-pin", Name: "no-such-pin", Version: "1.0.0"}
	r = resolveDep(orphan)
	if r.Status != statusUnknown {
		t.Errorf("orphan dep: got %s, want unknown", r.Status)
	}
}
