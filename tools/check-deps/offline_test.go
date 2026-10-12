package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"strimserver-check-deps/common"
)

// This file covers the Wave-2 contract additions owned by the core agent:
// the integrity role/status surface (Steps 1-2) and the schemaVersion:"2"
// report envelope with placeholder inventory/integrity arrays (Steps 3-4).

// TestDependencyRoleIntegrity proves the Role field's integrity predicate: an
// empty role and the explicit "version" role are version pins, and only the
// "integrity" role is an integrity pin.
func TestDependencyRoleIntegrity(t *testing.T) {
	cases := []struct {
		name string
		role string
		want bool
	}{
		{"empty role defaults to version", "", false},
		{"explicit version role", "version", false},
		{"integrity role", "integrity", true},
		{"unknown role is not integrity", "checksum", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dep := common.Dependency{Role: tc.role}
			if got := dep.IsIntegrity(); got != tc.want {
				t.Errorf("Dependency{Role:%q}.IsIntegrity() = %v, want %v", tc.role, got, tc.want)
			}
		})
	}
}

// TestStatusConstants proves the two new Status constants carry their exact
// wire values (the frozen shared contract siblings depend on).
func TestStatusConstants(t *testing.T) {
	if common.StatusIntegrity != "integrity" {
		t.Errorf("common.StatusIntegrity = %q, want %q", common.StatusIntegrity, "integrity")
	}
	if common.StatusSkipped != "skipped" {
		t.Errorf("common.StatusSkipped = %q, want %q", common.StatusSkipped, "skipped")
	}
}

// TestClassifyIntegrityRoute proves an integrity-role dependency classifies as
// StatusIntegrity before the semver tier policies run, preserving its tier and
// its informational notes.
func TestClassifyIntegrityRoute(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryRuntime, Name: "iperf3", Version: "3.17.1", Role: "integrity"}
	vi := common.VersionInfo{Version: "9.9.9", Infos: []string{"sha256 pinned"}}

	got := c.Classify(dep, vi)

	if got.Status != common.StatusIntegrity {
		t.Errorf("status = %q, want %q", got.Status, common.StatusIntegrity)
	}
	if got.Tier != common.TierT1 {
		t.Errorf("tier = %s, want T1 (runtime resting tier preserved)", got.Tier)
	}
	if len(got.Infos) != 1 || got.Infos[0] != "sha256 pinned" {
		t.Errorf("infos = %v, want [sha256 pinned]", got.Infos)
	}
}

// TestClassifyIntegrityWinsOverResolutionGuards proves the integrity route is
// taken even when the resolver returned an error or no version: an integrity
// pin has no upstream version to compare, so it must never surface as unknown.
func TestClassifyIntegrityWinsOverResolutionGuards(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryRuntime, Name: "iperf3", Role: "integrity"}

	for name, vi := range map[string]common.VersionInfo{
		"resolver error": {Err: errors.New("boom")},
		"empty version":  {},
	} {
		t.Run(name, func(t *testing.T) {
			if got := c.Classify(dep, vi); got.Status != common.StatusIntegrity {
				t.Errorf("status = %q, want %q", got.Status, common.StatusIntegrity)
			}
		})
	}
}

// TestReportSchemaVersionAndPlaceholders proves the marshalled report carries
// schemaVersion "2" and the empty inventory/integrity placeholder arrays while
// keeping findings, unknowns, and counts.
func TestReportSchemaVersionAndPlaceholders(t *testing.T) {
	rep := buildReport(nil, nil, parsedIgnoreSet{}, frozenNow(), false)
	data, err := marshalReport(rep)
	if err != nil {
		t.Fatalf("marshalReport: %v", err)
	}

	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("unmarshal report: %v", err)
	}

	if got := string(m["schemaVersion"]); got != `"2"` {
		t.Errorf("schemaVersion = %s, want %q", got, "2")
	}
	if got := string(m["inventory"]); got != `[]` {
		t.Errorf("inventory = %s, want [] (empty placeholder)", got)
	}
	if got := string(m["integrity"]); got != `[]` {
		t.Errorf("integrity = %s, want [] (empty placeholder)", got)
	}
	for _, key := range []string{"findings", "unknowns", "counts"} {
		if _, ok := m[key]; !ok {
			t.Errorf("report missing required key %q", key)
		}
	}
}

// TestOfflineSkipsNetworkResolvers proves that in offline mode every
// network-backed resolver entry is answered as StatusSkipped with a reason and
// is never invoked, while no-op/digest entries resolve normally.
func TestOfflineSkipsNetworkResolvers(t *testing.T) {
	var calls int64
	networkResolver := func(common.Dependency) common.VersionInfo {
		atomic.AddInt64(&calls, 1)
		return common.VersionInfo{Version: "9.9.9"}
	}
	noopResolver := func(common.Dependency) common.VersionInfo {
		return common.VersionInfo{Version: "1.0.0"}
	}
	resolvers := []ResolverEntry{
		networkedDep(Matches(common.CategoryBazelModule, "rules_go"), networkResolver),
		noopDep(Matches(common.CategoryToolchain, "Bazel"), noopResolver),
	}
	deps := []common.Dependency{
		{Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.1.0", File: "MODULE.bazel"},
		{Category: common.CategoryToolchain, Name: "Bazel", Version: "1.0.0", File: ".bazelversion"},
	}
	opts := &Options{Offline: true, MaxConcurrentFetches: 2}
	guard := newCacheGuard(nil)

	got := resolveAll(opts, guard, resolvers, nil, deps, testClassifier())

	if calls != 0 {
		t.Errorf("offline run invoked a network resolver %d time(s), want 0", calls)
	}
	if guard.changed {
		t.Error("offline run mutated the cache, want no cache write")
	}
	if got[0].Status != common.StatusSkipped {
		t.Errorf("network dep status = %q, want %q", got[0].Status, common.StatusSkipped)
	}
	if len(got[0].Reasons) == 0 {
		t.Error("skipped network dep has no reason explaining the skip")
	}
	if got[1].Status == common.StatusSkipped {
		t.Errorf("no-op dep status = %q, want a normal resolved status", got[1].Status)
	}
	if got[1].Latest != "1.0.0" {
		t.Errorf("no-op dep latest = %q, want %q", got[1].Latest, "1.0.0")
	}
}

// TestStrictFlagFailsOnUnknowns proves the default path never fails on
// unknowns while --strict turns any extraction unknown or undeterminable pin
// into a non-zero run error.
func TestStrictFlagFailsOnUnknowns(t *testing.T) {
	def := newE2EApp(t, e2eConsole, "", nil)
	if err := run(def.opts, def.cache, def.resolvers, nil, def.extractors, def.classifier); err != nil {
		t.Fatalf("default run must not fail on unknowns: %v", err)
	}

	strict := newE2EApp(t, e2eConsole, "", nil)
	strict.opts.Strict = true
	err := run(strict.opts, strict.cache, strict.resolvers, nil, strict.extractors, strict.classifier)
	if err == nil {
		t.Fatal("strict run succeeded, want a non-zero-exit error")
	}
	if !strings.Contains(err.Error(), "strict") {
		t.Errorf("strict error %q does not mention strict", err)
	}
}

// TestStrictPassesCleanRun proves --strict stays silent when every pin resolves
// and there are no extraction unknowns.
func TestStrictPassesCleanRun(t *testing.T) {
	warn := func(string, ...any) {}
	opts := &Options{
		Root:                 "/repo",
		Now:                  frozenNow,
		Stdout:               &bytes.Buffer{},
		Stderr:               &bytes.Buffer{},
		MaxConcurrentFetches: 1,
		Strict:               true,
		Warn:                 warn,
	}
	cache := &Cache{
		Path: filepath.Join(t.TempDir(), cacheFileRel),
		TTL:  testCacheTTL,
		Now:  opts.Now,
		Warn: warn,
	}
	resolvers := []ResolverEntry{
		noopDep(Matches(common.CategoryToolchain, "Bazel"), func(common.Dependency) common.VersionInfo {
			return common.VersionInfo{Version: "9.2.0"}
		}),
	}
	extractors := []common.Extractor{
		func(string) ([]common.Dependency, []common.ExtractionUnknown) {
			return []common.Dependency{{Category: common.CategoryToolchain, Name: "Bazel", Version: "9.2.0", File: ".bazelversion"}}, nil
		},
	}

	if err := run(opts, cache, resolvers, nil, extractors, testClassifier()); err != nil {
		t.Fatalf("clean strict run failed: %v", err)
	}
}
