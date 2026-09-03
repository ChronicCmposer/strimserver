package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"strimserver-check-deps/common"
	"strimserver-check-deps/resolverimpl"
)

// Phase 3 unit tests: JSON schema shape, cache round-trip and key derivation,
// ignore matching and until-expiry, and tier-collapse counts. All are pure and
// touch no network.

// --- JSON schema ------------------------------------------------------------

func TestJSONSchemaRoundTrip(t *testing.T) {
	all := []common.Resolved{
		{
			Dep:     common.Dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0", Source: "https://bcr.bazel.build/modules/rules_go", File: "MODULE.bazel"},
			Tier:    common.TierT2,
			Status:  common.StatusUpdate,
			Latest:  "0.64.0",
			Date:    "2026-08-01",
			Reasons: []string{"review"},
		},
		{
			Dep:    common.Dependency{Category: "base-image", Name: "alpine", Version: "", Source: "docker.io/library/alpine @ sha256:abc", File: "MODULE.bazel", DigestPinned: true},
			Tier:   common.TierT1,
			Status: common.StatusOK,
		},
		{
			Dep:     common.Dependency{Category: "toolchain", Name: "Bazel", Version: "9.2.0", Source: ".bazelversion", File: ".bazelversion"},
			Tier:    common.TierT2,
			Status:  common.StatusUnknown,
			Reasons: []string{"no resolver configured for this dependency"},
		},
	}
	unknowns := []common.ExtractionUnknown{{File: "MODULE.bazel", Reason: "malformed bazel_dep"}}
	ignores := ignoreSet{{ID: "bazel-module/rules_go", Reason: "pinned", Until: ""}}.parsed()

	rep := buildReport(all, unknowns, ignores, time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC))

	data, err := marshalReport(rep)
	if err != nil {
		t.Fatalf("marshalReport: %v", err)
	}

	// Round-trip through the wire form and assert every required field.
	var back report
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(back.Findings) != 3 {
		t.Fatalf("findings = %d, want 3", len(back.Findings))
	}

	byName := map[string]finding{}
	for _, f := range back.Findings {
		byName[f.Name] = f
	}
	f0 := byName["rules_go"]
	if f0.Category != "bazel-module" || f0.Name != "rules_go" || f0.Current != "0.63.0" {
		t.Errorf("finding category/name/current = %q/%q/%q", f0.Category, f0.Name, f0.Current)
	}
	if f0.Wanted != "0.64.0" || f0.Latest != "0.64.0" {
		t.Errorf("wanted/latest = %q/%q, want 0.64.0/0.64.0", f0.Wanted, f0.Latest)
	}
	if f0.Tier != "T2" || f0.Status != "update" {
		t.Errorf("tier/status = %q/%q, want T2/update", f0.Tier, f0.Status)
	}
	if f0.URL != "https://bcr.bazel.build/modules/rules_go" {
		t.Errorf("url = %q", f0.URL)
	}
	if f0.ReleaseDate != "2026-08-01" {
		t.Errorf("releaseDate = %q, want 2026-08-01", f0.ReleaseDate)
	}
	if !f0.Ignored {
		t.Error("rules_go should be ignored by the rules_go rule")
	}
	if len(f0.Reasons) != 1 || f0.Reasons[0] != "review" {
		t.Errorf("reasons = %v", f0.Reasons)
	}

	// Non-URL source -> empty url, and wanted empty when unknown.
	if byName["alpine"].URL != "" {
		t.Errorf("digest finding url = %q, want empty", byName["alpine"].URL)
	}
	if byName["Bazel"].Wanted != "" {
		t.Errorf("unknown finding wanted = %q, want empty", byName["Bazel"].Wanted)
	}

	// Unknowns: one phase-1 file/reason plus the resolved unknown dependency,
	// sorted by file so the order is deterministic.
	if len(back.Unknowns) != 2 {
		t.Fatalf("unknowns = %d, want 2", len(back.Unknowns))
	}
	foundPhase1, foundResolved := false, false
	for _, u := range back.Unknowns {
		if u.File == "MODULE.bazel" && u.Reason == "malformed bazel_dep" {
			foundPhase1 = true
		}
		if u.Name == "Bazel" && strings.Contains(u.Reason, "no resolver") {
			foundResolved = true
		}
	}
	if !foundPhase1 || !foundResolved {
		t.Errorf("unknowns missing expected entries: %+v", back.Unknowns)
	}

	// Counts.
	c := back.Counts
	if c.Total != 3 || c.T1 != 1 || c.T2 != 2 || c.T3 != 0 {
		t.Errorf("tier counts = total:%d t1:%d t2:%d t3:%d", c.Total, c.T1, c.T2, c.T3)
	}
	if c.Update != 1 || c.StatusUnknown != 1 || c.OK != 1 || c.Hygiene != 0 {
		t.Errorf("status counts = update:%d unknown:%d ok:%d hygiene:%d", c.Update, c.StatusUnknown, c.OK, c.Hygiene)
	}
	if c.Ignored != 1 || c.UnknownsTotal != 2 {
		t.Errorf("ignored/unknowns = %d/%d", c.Ignored, c.UnknownsTotal)
	}
}

func TestJSONSchemaDeterministicFieldOrder(t *testing.T) {
	all := []common.Resolved{{
		Dep:    common.Dependency{Category: "ci-action", Name: "actions/checkout", Version: "v4", Source: "https://github.com/actions/checkout", File: ".github/workflows/ci.yml"},
		Tier:   common.TierT2,
		Status: common.StatusUpdate,
		Latest: "v7.0.1",
	}}
	rep := buildReport(all, nil, nil, time.Now())
	a, err := marshalReport(rep)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	b, err := marshalReport(rep)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(a) != string(b) {
		t.Error("same report marshaled differently; field order is not deterministic")
	}
	// Spot-check that "category" precedes "name" (struct order, not map order).
	if !strings.Contains(string(a), `"category"`) || !strings.Contains(string(a), `"name"`) {
		t.Error("schema missing category/name fields")
	}
	if strings.Index(string(a), `"category"`) > strings.Index(string(a), `"name"`) {
		t.Error("category should serialize before name (stable struct order)")
	}
}

// --- tier collapse counts ---------------------------------------------------

func TestTierCollapseCounts(t *testing.T) {
	all := []common.Resolved{
		mkResolved("script-pin", "qemu", "9.2.4", common.TierT2, common.StatusUpdate, "9.2.5"),
		mkResolved("script-pin", "m4", "1.4.19", common.TierT3, common.StatusUpdate, "1.4.20"),
		mkResolved("script-pin", "ffmpeg", "8.0", common.TierT1, common.StatusUpdate, "8.0.1"),
		mkResolved("bazel-module", "rules_nodejs", "6.7.3", common.TierT3, common.StatusUpdate, "6.7.5"),
	}
	rep := buildReport(all, nil, nil, time.Now())
	if rep.Counts.T1 != 1 || rep.Counts.T2 != 1 || rep.Counts.T3 != 2 {
		t.Errorf("tier counts = t1:%d t2:%d t3:%d, want 1/1/2", rep.Counts.T1, rep.Counts.T2, rep.Counts.T3)
	}
	// The console collapses T3 into a single count line with the names.
	console := renderConsole(rep, "/repo")
	if !strings.Contains(console, "T3 (minor) — 2") {
		t.Errorf("console T3 line missing count:\n%s", console)
	}
	if !strings.Contains(console, "qemu") || !strings.Contains(console, "ffmpeg") {
		t.Errorf("T1/T2 names should appear individually:\n%s", console)
	}
	if strings.Contains(console, "T1 (security) — 1") == false {
		t.Errorf("T1 section should be present:\n%s", console)
	}
}

// mkResolved is a tiny resolved builder for fixtures.
func mkResolved(category, name, version string, ti common.Tier, st common.Status, latest string) common.Resolved {
	return common.Resolved{
		Dep:    common.Dependency{Category: category, Name: name, Version: version},
		Tier:   ti,
		Status: st,
		Latest: latest,
	}
}

// --- cache ------------------------------------------------------------------

func TestCacheKeyStableAndVersionSensitive(t *testing.T) {
	a := common.Dependency{Category: "bazel-module", Name: "rules_go", Source: "https://bcr", Version: "0.63.0"}
	b := common.Dependency{Category: "bazel-module", Name: "rules_go", Source: "https://bcr", Version: "0.63.0"}
	if cacheKey(a) != cacheKey(b) {
		t.Error("identical deps must share a cache key")
	}
	bumped := common.Dependency{Category: "bazel-module", Name: "rules_go", Source: "https://bcr", Version: "0.64.0"}
	if cacheKey(a) == cacheKey(bumped) {
		t.Error("bumping the pinned version must change the cache key")
	}
	other := common.Dependency{Category: "tool-binary", Name: "golangci_lint_linux_amd64", Source: "https://github", Version: "2.13.2"}
	if cacheKey(a) == cacheKey(other) {
		t.Error("distinct deps must not collide on cache key")
	}
}

func TestCacheRoundTripAndEntryConversion(t *testing.T) {
	c := &Cache{
		Path: filepath.Join(t.TempDir(), cacheFileRel),
		TTL:  testCacheTTL,
		Now:  func() time.Time { return time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC) },
		Warn: t.Logf,
	}

	vi := common.VersionInfo{Version: "0.64.0", Date: "2026-08-01", Infos: []string{"note"}}
	entries := map[string]cacheEntry{
		cacheKey(common.Dependency{Category: "bazel-module", Name: "rules_go", Source: "s", Version: "0.63.0"}): versionInfoToEntry(vi),
	}
	c.Save(entries)
	if _, err := os.Stat(c.Path); err != nil {
		t.Fatalf("cache file not written: %v", err)
	}

	got := c.Load()
	if len(got) != 1 {
		t.Fatalf("loaded %d entries, want 1", len(got))
	}
	for _, e := range got {
		back := entryToVersionInfo(e)
		if back.Version != "0.64.0" || back.Date != "2026-08-01" {
			t.Errorf("round-trip version/date = %q/%q", back.Version, back.Date)
		}
		if len(back.Infos) != 1 || back.Infos[0] != "note" {
			t.Errorf("round-trip infos = %v", back.Infos)
		}
		if back.Err != nil {
			t.Errorf("round-trip err = %v, want nil", back.Err)
		}
	}
}

func TestCacheMissingIsNotFatal(t *testing.T) {
	c := &Cache{
		Path: filepath.Join(t.TempDir(), "does-not-exist.json"),
		TTL:  testCacheTTL,
		Now:  func() time.Time { return time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC) },
		Warn: t.Logf,
	}
	got := c.Load()
	if got == nil || len(got) != 0 {
		t.Errorf("missing cache should load as empty, got %v", got)
	}
}

func TestCacheTTLUsesInjectedClock(t *testing.T) {
	written := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	entries := map[string]cacheEntry{
		cacheKey(common.Dependency{Category: "bazel-module", Name: "rules_go", Source: "s", Version: "0.63.0"}): versionInfoToEntry(common.VersionInfo{Version: "0.64.0"}),
	}

	// A Save with the frozen clock stamps `written`; then a Load with the same
	// clock (within TTL) returns the entries.
	within := &Cache{
		Path: filepath.Join(t.TempDir(), cacheFileRel),
		TTL:  testCacheTTL,
		Now:  func() time.Time { return written },
		Warn: t.Logf,
	}
	within.Save(entries)
	if got := within.Load(); len(got) != 1 {
		t.Fatalf("within-TTL load returned %d entries, want 1", len(got))
	}

	// Advancing Now past TTL (still relative to the same written stamp) must
	// treat the cache as expired and return empty.
	expired := &Cache{
		Path: within.Path,
		TTL:  testCacheTTL,
		Now:  func() time.Time { return written.Add(testCacheTTL + time.Second) },
		Warn: t.Logf,
	}
	if got := expired.Load(); len(got) != 0 {
		t.Fatalf("expired cache should load empty, got %d entries", len(got))
	}
}

func TestCacheKeyDerivationKeyedOnCurrent(t *testing.T) {
	// Bumping a pin invalidates the entry: the resolver must refetch.
	// Simulated by asserting the key differs when current changes (covered in
	// TestCacheKeyStableAndVersionSensitive); here we additionally confirm the
	// no-op resolvers are never routed through the cache path by resolveOne.
	fresh := false
	entries := map[string]cacheEntry{}
	reg := []ResolverEntry{noopDep(Matches(common.CategoryToolchain, "Bazel"), resolverimpl.ToolchainResolve)}
	r, changed := resolveOne(reg, common.Dependency{Category: common.CategoryToolchain, Name: "Bazel", Version: "9.2.0"}, entries, fresh, testClassifier())
	if r.Status != common.StatusOK {
		t.Errorf("toolchain resolveOne status = %s, want ok", r.Status)
	}
	if changed {
		t.Error("no-op toolchain resolver must not be cached")
	}
	if len(entries) != 0 {
		t.Error("no-op toolchain resolver must not write to the cache")
	}
}

// errTestNetwork is a sentinel used only in unit tests; the common package
// keeps its own copy for the in-package classify tests.
var errTestNetwork = errors.New("test network failure")

// TestCommitFreshEvictsStaleEntryOnFailure pins the --fresh semantics: when a
// fresh refetch of a network dependency fails, the stale cached entry must be
// evicted (so the next non-fresh run refetches live), while a non-fresh
// failure leaves the stale entry intact and never writes the error.
func TestCommitFreshEvictsStaleEntryOnFailure(t *testing.T) {
	reg := []ResolverEntry{{
		Match:   func(dep common.Dependency) bool { return dep.Category == "bazel-module" },
		Resolve: func(dep common.Dependency) common.VersionInfo { return common.VersionInfo{Err: errTestNetwork} },
		Network: true,
	}}
	dep := common.Dependency{Category: "bazel-module", Name: "rules_go", Source: "s", Version: "0.63.0"}
	key := cacheKey(dep)
	good := versionInfoToEntry(common.VersionInfo{Version: "0.64.0"})

	// Fresh failure evicts the stale entry and reports the cache changed, so
	// resolveAll saves the eviction to disk.
	entries := map[string]cacheEntry{key: good}
	r, changed := resolveOne(reg, dep, entries, true, testClassifier())
	if r.Status != common.StatusUnknown {
		t.Errorf("fresh failure status = %s, want unknown", r.Status)
	}
	if !changed {
		t.Error("fresh failure must report the cache changed (stale entry evicted)")
	}
	if _, present := entries[key]; present {
		t.Error("fresh failure must evict the stale entry from the cache")
	}

	// Non-fresh failure never writes the error and never touches the stale
	// entry, so a transient blip is not replayed and is not discarded.
	entries = map[string]cacheEntry{key: good}
	guard := newCacheGuard(entries)
	guard.commit(dep, common.VersionInfo{Err: errTestNetwork}, false, testClassifier())
	if guard.changed {
		t.Error("non-fresh failure must not report the cache changed")
	}
	if _, present := entries[key]; !present {
		t.Error("non-fresh failure must leave the stale entry intact")
	}
}

// --- ignore ----------------------------------------------------------------

func TestIgnoreMatching(t *testing.T) {
	today := time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC)
	rules := ignoreSet{
		{ID: "npm/@rollup/rollup-linux-arm64-gnu", Reason: "platform pin"},
		{ID: "base-image/debian", Reason: "repro", Until: "2027-01-01"},
	}.parsed()
	if !rules.isIgnored("npm/@rollup/rollup-linux-arm64-gnu", today) {
		t.Error("rollup should be ignored (no until)")
	}
	if !rules.isIgnored("base-image/debian", today) {
		t.Error("debian should be ignored before its until date")
	}
	if rules.isIgnored("npm/other", today) {
		t.Error("non-matching id must not be ignored")
	}
	if rules.isIgnored("base-image/alpine", today) {
		t.Error("non-listed id must not be ignored")
	}
}

func TestIgnoreUntilExpiry(t *testing.T) {
	rules := ignoreSet{{ID: "base-image/debian", Reason: "repro", Until: "2026-09-01"}}.parsed()
	// On the day after until, the rule no longer applies.
	today := time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC)
	if rules.isIgnored("base-image/debian", today) {
		t.Error("expired rule must not match")
	}
	// On the until day itself it still applies.
	onUntil := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	if !rules.isIgnored("base-image/debian", onUntil) {
		t.Error("rule should still match on its until day")
	}
}

func TestIgnoreUntilExpiryNonMidnight(t *testing.T) {
	rules := ignoreSet{{ID: "base-image/debian", Reason: "repro", Until: "2026-09-01"}}.parsed()
	// A non-midnight today on the until date itself must still match: the rule
	// applies on its until date regardless of the time-of-day of today.
	noon := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	if !rules.isIgnored("base-image/debian", noon) {
		t.Error("rule should still match at noon on its until day")
	}
	// The day after until (even at midnight) must not match.
	nextDay := time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC)
	if rules.isIgnored("base-image/debian", nextDay) {
		t.Error("rule must not match on the day after its until date")
	}
}

func TestIgnoreMalformedUntilExpired(t *testing.T) {
	rules := ignoreSet{{ID: "base-image/debian", Reason: "repro", Until: "not-a-date"}}.parsed()
	today := time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC)
	if rules.isIgnored("base-image/debian", today) {
		t.Error("malformed until must not silently apply forever")
	}
}

func TestParseIgnoreMalformed(t *testing.T) {
	if _, err := parseIgnore([]byte(`not json`)); err == nil {
		t.Error("malformed ignore JSON must error")
	}
	rules, err := parseIgnore([]byte(`[{"id":"a","reason":"b"}]`))
	if err != nil || len(rules) != 1 || rules[0].ID != "a" {
		t.Errorf("valid ignore parse = %v, %v", rules, err)
	}
}
