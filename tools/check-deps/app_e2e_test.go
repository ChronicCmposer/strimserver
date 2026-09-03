package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"strimserver-check-deps/common"
	"strimserver-check-deps/resolverimpl"
)

// This file is the deterministic, no-network pipeline e2e. It wires the full
// pipeline with a fixed SYNTHETIC scenario — fake extractor + fake resolvers +
// NativeTools:false — so the pipeline runs end-to-end with no network, no
// shell-outs, and no filesystem reads outside a temp dir. The scenario is
// portable: it produces byte-identical JSON and console output under both
// `go test` and the bazel sandbox (where real repo files are absent), guarded
// by the golden-nonet.* fixtures.

type e2eMode int

const (
	e2eJSON e2eMode = iota
	e2eConsole
)

// frozenNow is the fixed clock for the synthetic scenario. Both the cache TTL
// check and the report date derive from it, so output is deterministic.
var frozenNow = func() time.Time { return time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC) }

// testCacheTTL is the fixed freshness TTL shared by every cache test, matching
// the production default (Options.CacheTTL) so TTL/expiry behavior in tests
// mirrors a real run.
const testCacheTTL = 24 * time.Hour

// testClassifier builds the default classifier shared by the e2e harness and
// the phase-3 unit tests.
func testClassifier() *common.Classifier {
	return common.NewClassifier(
		[]common.TierPolicy{classifyFloatingBaseImage, classifyCIAction, classifyDateTag, classifySemver},
		[]common.BaseTierRule{
			{Category: common.CategoryBaseImage, Tier: common.TierT1},
			{Category: common.CategoryRuntime, Tier: common.TierT1},
			{Category: common.CategoryBazelModule, Tier: common.TierT2},
			{Category: common.CategoryToolchain, Tier: common.TierT2},
			{Category: common.CategoryCIAction, Tier: common.TierT2},
			{Category: common.CategoryToolBinary, Name: "mediamtx_dist", Tier: common.TierT1},
			{Category: common.CategoryToolBinary, Tier: common.TierT2},
			{Category: common.CategoryScriptPin, Name: "openssh-portable", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "ffmpeg", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "CUDA", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "nv-codec-headers", Tier: common.TierT1},
			{Category: common.CategoryScriptPin, Name: "qemu", Tier: common.TierT2},
		},
	)
}

func captureWarn(warns *[]string) func(string, ...any) {
	return func(format string, args ...any) {
		*warns = append(*warns, fmt.Sprintf(format, args...))
	}
}

// fixtureVersionInfo returns the fixed common.VersionInfo a fake network
// resolver produces for the synthetic scenario, keyed by dependency
// category+name.
func fixtureVersionInfo(category, name string) common.VersionInfo {
	switch category + "/" + name {
	case "bazel-module/rules_go":
		return common.VersionInfo{Version: "0.64.0"}
	case "tool-binary/golangci_lint_linux_amd64":
		return common.VersionInfo{Version: "2.13.2"}
	case "base-image/debian":
		return common.VersionInfo{Version: "20260824"}
	case "script-pin/qemu":
		return common.VersionInfo{Version: "11.1.1"}
	case "ci-action/actions/checkout":
		return common.VersionInfo{Version: "v7.0.1", Date: "2026-07-20T15:10:05Z"}
	default:
		return common.VersionInfo{Err: errors.New("no fixture for " + category + "/" + name)}
	}
}

// networkVersion returns a closure resolver that records a network invocation
// (so cache tests can count upstream calls) and reports the fixed fixture
// common.VersionInfo for the dependency's category+name. The counter is
// incremented atomically because network resolvers now run concurrently in
// resolveAll.
func networkVersion(netCalls *int64) common.Resolver {
	return func(dep common.Dependency) common.VersionInfo {
		atomic.AddInt64(netCalls, 1)
		return fixtureVersionInfo(dep.Category, dep.Name)
	}
}

// newSyntheticResolvers builds the fake resolver slice for the synthetic
// scenario. Network resolvers are closures over the call counter; the digest
// (alpine) and toolchain (Bazel) no-ops use the real free functions and never
// count. It reuses the networkedDep/noopDep builders from resolve.go rather
// than re-declaring their match/network wiring. Slice order is dispatch order:
// first match wins.
func newSyntheticResolvers(netCalls *int64) []ResolverEntry {
	return []ResolverEntry{
		networkedDep(matchesCategory(common.CategoryBazelModule), networkVersion(netCalls)),
		networkedDep(Matches(common.CategoryToolBinary, "golangci_lint_linux_amd64"), networkVersion(netCalls)),
		noopDep(Matches(common.CategoryBaseImage, "alpine"), resolverimpl.DigestResolve),
		networkedDep(Matches(common.CategoryBaseImage, "debian"), networkVersion(netCalls)),
		networkedDep(Matches(common.CategoryScriptPin, "qemu"), networkVersion(netCalls)),
		networkedDep(matchesCategory(common.CategoryCIAction), networkVersion(netCalls)),
		noopDep(matchesCategory(common.CategoryToolchain), resolverimpl.ToolchainResolve),
	}
}

// syntheticExtract is the fixed fake extractor: it returns exactly the
// scenario's dependencies plus its one extraction unknown, ignoring the root
// argument (extraction is deterministic and filesystem-free).
func syntheticExtract(_ string) ([]common.Dependency, []common.ExtractionUnknown) {
	deps := []common.Dependency{
		{Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.63.0", Source: "https://bcr.bazel.build/modules/rules_go", File: "MODULE.bazel"},
		{Category: common.CategoryToolBinary, Name: "golangci_lint_linux_amd64", Version: "2.13.2", Source: "https://github.com/golangci/golangci-lint/releases/download/v2.13.2/golangci-lint-2.13.2-linux-amd64.tar.gz", File: "MODULE.bazel"},
		{Category: common.CategoryBaseImage, Name: "alpine", Version: "", Source: "docker.io/library/alpine", File: "MODULE.bazel", DigestPinned: true},
		{Category: common.CategoryBaseImage, Name: "debian", Version: "20260824T082821Z", Source: "https://snapshot.debian.org/archive/debian", File: "MODULE.bazel"},
		{Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4", Source: "https://download.qemu.org", File: "tools/qemu/build-qemu.sh"},
		{Category: common.CategoryCIAction, Name: "actions/checkout", Version: "v4", Source: "https://github.com/actions/checkout", File: ".github/workflows/controller-ci.yml"},
		{Category: common.CategoryToolchain, Name: "Bazel", Version: "9.2.0", Source: ".bazelversion", File: ".bazelversion"},
		{Category: common.CategoryScriptPin, Name: "no-such-pin", Version: "1.0.0", Source: "x", File: "tools/x/build.sh"},
	}
	unknowns := []common.ExtractionUnknown{{File: "tools/ffmpeg-dist/build.sh", Reason: "cannot read file: open tools/ffmpeg-dist/build.sh: no such file or directory"}}
	return deps, unknowns
}

// e2eRun is a fully wired synthetic scenario: the run() collaborators plus the
// injected in-memory writers, warn capture, cache directory, and network-call
// counter. Tests build one per run, call run(), and assert on captured output.
type e2eRun struct {
	opts       *Options
	cache      *Cache
	resolvers  []ResolverEntry
	extractors []common.Extractor
	classifier *common.Classifier
	stdout     *bytes.Buffer
	stderr     *bytes.Buffer
	warns      *[]string
	cacheDir   string
	netCalls   *int64
}

// newE2EApp wires the fixed synthetic scenario into a runnable run(). mode
// selects the JSON or console report; baseDir reuses a shared cache directory
// across calls (pass "" for a fresh temp dir); netCalls shares a network-call
// counter across runs (pass nil for a fresh counter per run). Root is the fixed
// sentinel "/repo" and the clock is frozen, so output is byte-identical across
// runs and environments.
func newE2EApp(t *testing.T, mode e2eMode, baseDir string, netCalls *int64) *e2eRun {
	t.Helper()
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	opts := &Options{
		Root:                 "/repo",
		Now:                  frozenNow,
		Stdout:               stdout,
		Stderr:               stderr,
		MaxConcurrentFetches: 4,
		NativeTools:          false,
	}
	if mode == e2eJSON {
		opts.JSON = true
	} else {
		opts.Console = true
	}

	warns := &[]string{}
	warn := captureWarn(warns)
	opts.Warn = warn
	if baseDir == "" {
		baseDir = t.TempDir()
	}
	cache := &Cache{
		Path: filepath.Join(baseDir, cacheFileRel),
		TTL:  testCacheTTL,
		Now:  opts.Now,
		Warn: warn,
	}

	if netCalls == nil {
		netCalls = new(int64)
	}
	resolvers := newSyntheticResolvers(netCalls)
	extractors := []common.Extractor{syntheticExtract}

	return &e2eRun{
		opts:       opts,
		cache:      cache,
		resolvers:  resolvers,
		extractors: extractors,
		classifier: testClassifier(),
		stdout:     stdout,
		stderr:     stderr,
		warns:      warns,
		cacheDir:   baseDir,
		netCalls:   netCalls,
	}
}

// TestE2ERegressionJSON asserts the synthetic JSON-mode run is byte-identical
// to the no-native golden, proving the full pipeline's schema and field order
// are stable.
func TestE2ERegressionJSON(t *testing.T) {
	e := newE2EApp(t, e2eJSON, "", nil)
	if err := run(e.opts, e.cache, e.resolvers, nil, e.extractors, e.classifier); err != nil {
		t.Fatalf("run: %v", err)
	}
	want, err := os.ReadFile(filepath.Join("testdata", "golden-nonet.json"))
	if err != nil {
		t.Fatalf("read golden-nonet.json: %v", err)
	}
	if got := e.stdout.Bytes(); !bytes.Equal(got, want) {
		t.Errorf("JSON output differs from golden-nonet.json\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestE2ERegressionConsole asserts the synthetic console-mode run is
// byte-identical to the no-native console golden. In console-only mode the
// console report goes to Stdout.
func TestE2ERegressionConsole(t *testing.T) {
	e := newE2EApp(t, e2eConsole, "", nil)
	if err := run(e.opts, e.cache, e.resolvers, nil, e.extractors, e.classifier); err != nil {
		t.Fatalf("run: %v", err)
	}
	want, err := os.ReadFile(filepath.Join("testdata", "golden-nonet-console.txt"))
	if err != nil {
		t.Fatalf("read golden-nonet-console.txt: %v", err)
	}
	if got := e.stdout.Bytes(); !bytes.Equal(got, want) {
		t.Errorf("console output differs from golden-nonet-console.txt\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestE2EAllRestoresFullFindings asserts that --all restores the complete
// findings list (ok deps included) and is byte-identical to the all-inclusive
// golden, while the default regression (TestE2ERegressionJSON) proves the ok
// findings are filtered out of the default output.
func TestE2EAllRestoresFullFindings(t *testing.T) {
	e := newE2EApp(t, e2eJSON, "", nil)
	e.opts.All = true
	if err := run(e.opts, e.cache, e.resolvers, nil, e.extractors, e.classifier); err != nil {
		t.Fatalf("run: %v", err)
	}
	want, err := os.ReadFile(filepath.Join("testdata", "golden-nonet-all.json"))
	if err != nil {
		t.Fatalf("read golden-nonet-all.json: %v", err)
	}
	if got := e.stdout.Bytes(); !bytes.Equal(got, want) {
		t.Errorf("JSON output differs from golden-nonet-all.json\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestE2ECacheHonoredAndFreshBypass proves the cache write/read path and the
// --fresh bypass: a second run with the same cache dir must not re-invoke the
// network resolvers, while --fresh must bypass the cache and refetch.
func TestE2ECacheHonoredAndFreshBypass(t *testing.T) {
	const networkDeps = 5 // rules_go, golangci, debian, qemu, checkout
	baseDir := t.TempDir()
	netCalls := new(int64)

	// First run: empty cache forces every network resolver to fetch.
	first := newE2EApp(t, e2eConsole, baseDir, netCalls)
	if err := run(first.opts, first.cache, first.resolvers, nil, first.extractors, first.classifier); err != nil {
		t.Fatalf("first run: %v", err)
	}
	if *netCalls != networkDeps {
		t.Errorf("first run invoked %d network resolvers, want %d", *netCalls, networkDeps)
	}
	if _, err := os.Stat(filepath.Join(baseDir, cacheFileRel)); err != nil {
		t.Errorf("cache file not written: %v", err)
	}
	firstOut := first.stdout.String()

	// Second run with the same cache: resolvers are NOT invoked again and the
	// output is identical.
	second := newE2EApp(t, e2eConsole, baseDir, netCalls)
	if err := run(second.opts, second.cache, second.resolvers, nil, second.extractors, second.classifier); err != nil {
		t.Fatalf("second run: %v", err)
	}
	if *netCalls != networkDeps {
		t.Errorf("cached run invoked %d network resolvers, want still %d", *netCalls, networkDeps)
	}
	if second.stdout.String() != firstOut {
		t.Error("cached run output differs from the first run")
	}

	// --fresh bypasses the cache and refetches every network dep.
	fresh := newE2EApp(t, e2eConsole, baseDir, netCalls)
	fresh.opts.Fresh = true
	if err := run(fresh.opts, fresh.cache, fresh.resolvers, nil, fresh.extractors, fresh.classifier); err != nil {
		t.Fatalf("fresh run: %v", err)
	}
	if *netCalls != 2*networkDeps {
		t.Errorf("fresh run invoked %d network resolvers, want %d", *netCalls, 2*networkDeps)
	}
}
