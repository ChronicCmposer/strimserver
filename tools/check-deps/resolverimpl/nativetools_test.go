package resolverimpl

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"strimserver-check-deps/common"
	"strimserver-check-deps/utilities"
)

// Phase 2 native-tools unit tests. resolvePNPM shells out to corepack, so every
// case injects a fake corepack shim via PATH (a temp dir prepended to PATH that
// wins over any host corepack) and builds a synthetic repo tree in a temp dir.
// No real node toolchain and no real repo files are touched.

// npmClassifier mirrors the production semver fallback so resolvePNPM records
// classify deterministically (update when the latest is newer, ok otherwise).
func npmClassifier() *common.Classifier {
	return common.NewClassifier(
		[]common.TierPolicy{func(r common.Resolved, dep common.Dependency) (common.Resolved, bool) {
			if utilities.CompareSemver(dep.Version, r.Latest) < 0 {
				r.Status = common.StatusUpdate
			} else {
				r.Status = common.StatusOK
			}
			return r, true
		}},
		[]common.BaseTierRule{{Category: common.CategoryNPM, Tier: common.TierT3}},
	)
}

func writeNpmFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("creating fixture directory: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writing fixture file: %v", err)
	}
}

// fakeCorepack writes an executable corepack shim into dir that prints a
// node-style deprecation warning to stderr (mimicking the real node 24 runtime,
// whose warning would otherwise pollute the merged output), prints the fixture
// JSON to stdout, and exits with the given code, so the test controls pnpm
// outdated's exact behavior (exit 1 = outdated success signal, exit 0 = up to
// date, other codes = failure).
func fakeCorepack(t *testing.T, dir, fixture, output string, exitCode int) {
	t.Helper()
	writeNpmFixture(t, filepath.Join(dir, fixture), output)
	script := "#!/bin/sh\necho 'DeprecationWarning: url.parse() is not standardized' >&2\ncat \"$(dirname \"$0\")/" + fixture + "\"\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(filepath.Join(dir, "corepack"), []byte(script), 0o755); err != nil {
		t.Fatalf("writing corepack shim: %v", err)
	}
}

// TestResolvePNPMRunsCorepackPerSubRepo proves resolvePNPM shells out to
// `corepack pnpm outdated --json` in every discovered sub-repo with a
// package.json and emits per-sub-repo findings: two sub-repos sharing a package
// name yield both records (no dedup), each tagged with its own package.json.
// The fixture uses the pnpm 9 schema (wanted/latest, no current) and the shim
// pollutes stderr, so the test also pins the tolerance for both.
func TestResolvePNPMRunsCorepackPerSubRepo(t *testing.T) {
	binDir := t.TempDir()
	const outdatedJSON = `{"@elgato/streamdeck":{"wanted":"2.0.0","latest":"2.1.0"},"rollup":{"wanted":"4.0.0","latest":"4.1.0"}}`
	fakeCorepack(t, binDir, "outdated.json", outdatedJSON, 1) // exit 1 = outdated
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	root := t.TempDir()
	writeNpmFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)
	writeNpmFixture(t, filepath.Join(root, "web", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)

	got := resolvePNPM(root, 5*time.Second, npmClassifier())
	if len(got) != 4 {
		t.Fatalf("resolvePNPM returned %d records, want 4 (2 packages x 2 sub-repos)", len(got))
	}

	seen := map[string]common.Resolved{}
	for _, r := range got {
		seen[r.Dep.Name+"|"+r.Dep.File] = r
	}
	for _, name := range []string{"@elgato/streamdeck", "rollup"} {
		for _, file := range []string{"tools/streamdeck-plugin/package.json", "web/package.json"} {
			r, ok := seen[name+"|"+file]
			if !ok {
				t.Errorf("missing record for %s in %s: got %v", name, file, seen)
				continue
			}
			if r.Status != common.StatusUpdate {
				t.Errorf("record %s/%s = %s, want update", name, file, r.Status)
			}
			if r.Dep.Version == "" {
				t.Errorf("record %s/%s has an empty current version (wanted)", name, file)
			}
			if r.Latest != "2.1.0" && r.Latest != "4.1.0" {
				t.Errorf("record %s/%s latest = %q, want the fixture latest", name, file, r.Latest)
			}
		}
	}
}

// TestResolvePNPMUpToDate proves pnpm's up-to-date signal (exit 0, empty
// output) yields no records at all.
func TestResolvePNPMUpToDate(t *testing.T) {
	binDir := t.TempDir()
	fakeCorepack(t, binDir, "empty.json", "", 0)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	root := t.TempDir()
	writeNpmFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)

	if got := resolvePNPM(root, 5*time.Second, npmClassifier()); len(got) != 0 {
		t.Errorf("resolvePNPM up-to-date = %v, want no records", got)
	}
}

// TestResolvePNPMUnknownPerSubRepo proves a failing sub-repo (here the shim
// exits 2, neither the up-to-date 0 nor the outdated 1) emits one unknown npm
// record attributed to that sub-repo's package.json, and a healthy sibling
// sub-repo still resolves.
func TestResolvePNPMUnknownPerSubRepo(t *testing.T) {
	binDir := t.TempDir()
	const outdatedJSON = `{"rollup":{"wanted":"4.0.0","latest":"4.1.0"}}`
	// Both shims exit 2 so both sub-repos fail; the per-sub-repo unknowns must
	// carry distinct files.
	fakeCorepack(t, binDir, "outdated.json", outdatedJSON, 2)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	root := t.TempDir()
	writeNpmFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)
	writeNpmFixture(t, filepath.Join(root, "web", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)

	got := resolvePNPM(root, 5*time.Second, npmClassifier())
	if len(got) != 2 {
		t.Fatalf("resolvePNPM returned %d records, want 2 per-sub-repo unknowns", len(got))
	}
	for _, r := range got {
		if r.Status != common.StatusUnknown {
			t.Errorf("record = %+v, want unknown", r)
		}
		if !strings.Contains(r.Reasons[0], "corepack pnpm outdated failed") {
			t.Errorf("unknown reason = %q, want corepack phrasing", r.Reasons[0])
		}
		if r.Dep.File != "tools/streamdeck-plugin/package.json" && r.Dep.File != "web/package.json" {
			t.Errorf("unknown file = %q, want a discovered sub-repo package.json", r.Dep.File)
		}
	}
}

// TestResolvePNPMCorepackNotFound proves a missing corepack binary yields the
// per-sub-repo unknown with the corepack/node phrasing.
func TestResolvePNPMCorepackNotFound(t *testing.T) {
	// A PATH with no corepack anywhere: exec resolves the binary as not-found
	// regardless of what the host has installed.
	t.Setenv("PATH", t.TempDir())

	root := t.TempDir()
	writeNpmFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"), `{"packageManager":"pnpm@9.15.9"}`)

	got := resolvePNPM(root, 5*time.Second, npmClassifier())
	if len(got) != 1 {
		t.Fatalf("resolvePNPM returned %d records, want 1 unknown", len(got))
	}
	if got[0].Status != common.StatusUnknown || !strings.Contains(got[0].Reasons[0], "corepack/node not found; node toolchain missing") {
		t.Errorf("record = %+v, want the corepack/node-not-found unknown", got[0])
	}
	if got[0].Dep.File != "tools/streamdeck-plugin/package.json" {
		t.Errorf("unknown file = %q, want tools/streamdeck-plugin/package.json", got[0].Dep.File)
	}
}

// TestResolvePNPMSkipsNvmrcOnlySubRepo proves a discovered sub-repo with only a
// .nvmrc (no package.json) is skipped: it pins Node but has no npm dependency
// tree, so no corepack invocation and no records.
func TestResolvePNPMSkipsNvmrcOnlySubRepo(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // a corepack lookup would fail the test loudly

	root := t.TempDir()
	writeNpmFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", ".nvmrc"), "24.13.0\n")

	if got := resolvePNPM(root, 5*time.Second, npmClassifier()); len(got) != 0 {
		t.Errorf("resolvePNPM on a .nvmrc-only sub-repo = %v, want no records", got)
	}
}
