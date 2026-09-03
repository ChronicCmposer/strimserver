package main

import (
	"reflect"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// resolve_test.go exercises resolveAll's batch-resolver loop, which the e2e
// suite never reaches: it runs resolveAll with NativeTools:false and therefore
// an empty batch list. This test injects one non-empty common.BatchResolver and
// proves its records append after the per-dependency worker-pool results, in
// deterministic order, with no network or native-tool access.
func TestResolveAllAppendsBatchRecords(t *testing.T) {
	opts := &Options{Fresh: false, MaxConcurrentFetches: 2, NativeToolTimeout: time.Second}
	guard := newCacheGuard(nil)

	// One no-op resolver entry owns both toolchain deps and answers a fixed
	// latest version, so every per-dependency record is deterministic and
	// cache-free (no-op resolvers never touch the guard's entry map).
	const fakeLatest = "2.0.0"
	resolvers := []ResolverEntry{
		noopDep(isToolchain, func(dep common.Dependency) common.VersionInfo {
			return common.VersionInfo{Version: fakeLatest}
		}),
	}

	deps := []common.Dependency{
		{Category: common.CategoryToolchain, Name: "Bazel", Version: "1.0.0", File: ".bazelversion"},
		{Category: common.CategoryToolchain, Name: "Go", Version: "1.0.0", File: "core/controller/go.mod"},
	}

	// One injected batch resolver (the shape main registers for go/pnpm) that
	// returns a single already-classified record.
	batchRecord := common.Resolved{
		Dep:    common.Dependency{Category: common.CategoryNPM, Name: "batch", Version: "1.0.0"},
		Status: common.StatusOK,
	}
	batchResolvers := []common.BatchResolver{
		func(root string, timeout time.Duration, classifier *common.Classifier) []common.Resolved {
			return []common.Resolved{batchRecord}
		},
	}

	got := resolveAll(opts, guard, resolvers, batchResolvers, deps, testClassifier())

	if len(got) != 3 {
		t.Fatalf("resolveAll returned %d records, want 3 (2 per-dep + 1 batch)", len(got))
	}

	// The first two records are the per-dependency classified results in input
	// order: pinned 1.0.0 vs latest 2.0.0 is a breaking bump that rests at T2.
	for i, dep := range deps {
		r := got[i]
		if r.Dep != dep {
			t.Errorf("record %d dep = %+v, want %+v", i, r.Dep, dep)
		}
		if r.Status != common.StatusUpdate {
			t.Errorf("record %d status = %s, want update", i, r.Status)
		}
		if r.Latest != fakeLatest {
			t.Errorf("record %d latest = %q, want %q", i, r.Latest, fakeLatest)
		}
		if r.Tier != common.TierT2 {
			t.Errorf("record %d tier = %s, want T2 (breaking bump)", i, r.Tier)
		}
	}

	// The batch record appends last, untouched by the worker pool.
	if !reflect.DeepEqual(got[2], batchRecord) {
		t.Errorf("batch record = %+v, want %+v", got[2], batchRecord)
	}
}
