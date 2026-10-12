package extractorimpl

import (
	"path/filepath"
	"testing"

	"strimserver-check-deps/common"
)

const pnpmLockFixture = `lockfileVersion: '9.0'

importers:

  .:
    dependencies:
      'declared-pkg':
        specifier: ^1
        version: 1.0.0
    devDependencies:
      'dev-only-pkg':
        specifier: ^3
        version: 3.0.0

packages:

  'declared-pkg@1.0.0':
    resolution: {integrity: sha512-aaa}

  'dev-only-pkg@3.0.0':
    resolution: {integrity: sha512-bbb}

  'only-transitive@2.0.0':
    resolution: {integrity: sha512-ccc}

  '@rollup/rollup-linux-x64-gnu@4.64.5':
    resolution: {integrity: sha512-ddd}
    cpu: [x64]
    os: [linux]

snapshots:

  'declared-pkg@1.0.0': {}
  'dev-only-pkg@3.0.0': {}
  'only-transitive@2.0.0':
    dependencies:
      'declared-pkg': 1.0.0
  '@rollup/rollup-linux-x64-gnu@4.64.5':
    optional: true
`

// Only packages absent from the importers' declared dependency maps are
// inventory; the resolved entries for directly declared packages are dropped.
func TestParsePnpmLockEmitsOnlyUndeclaredPackages(t *testing.T) {
	deps, unknowns := parsePnpmLock([]byte(pnpmLockFixture), "tools/streamdeck-plugin/pnpm-lock.yaml")

	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 2 {
		t.Fatalf("deps = %d (%+v), want 2", len(deps), deps)
	}
	byName := map[string]common.Dependency{}
	for _, dep := range deps {
		byName[dep.Name] = dep
		if dep.Category != common.CategoryNPM {
			t.Errorf("%s Category = %q, want %q", dep.Name, dep.Category, common.CategoryNPM)
		}
		if dep.Note != inventoryNote {
			t.Errorf("%s Note = %q, want %q", dep.Name, dep.Note, inventoryNote)
		}
		if dep.File != "tools/streamdeck-plugin/pnpm-lock.yaml" {
			t.Errorf("%s File = %q", dep.Name, dep.File)
		}
	}
	if _, ok := byName["only-transitive"]; !ok {
		t.Errorf("missing only-transitive in %+v", deps)
	}
	if _, ok := byName["@rollup/rollup-linux-x64-gnu"]; !ok {
		t.Errorf("missing optional rollup platform binary in %+v", deps)
	}
	if _, ok := byName["declared-pkg"]; ok {
		t.Errorf("declared-pkg must be excluded, got %+v", deps)
	}
	if _, ok := byName["dev-only-pkg"]; ok {
		t.Errorf("dev-only-pkg must be excluded, got %+v", deps)
	}
}

// A snapshot key carrying a peer suffix resolves to the same (name, version) as
// its packages key and must be emitted once.
func TestParsePnpmLockDedupesPeerSuffixedSnapshotKeys(t *testing.T) {
	lock := "packages:\n\n" +
		"  '@scope/pkg@1.2.3':\n" +
		"    resolution: {integrity: sha512-aaa}\n\n" +
		"snapshots:\n\n" +
		"  '@scope/pkg@1.2.3(peer@4.0.0)': {}\n"

	deps, unknowns := parsePnpmLock([]byte(lock), "pnpm-lock.yaml")

	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 || deps[0].Name != "@scope/pkg" || deps[0].Version != "1.2.3" {
		t.Fatalf("deps = %+v, want a single @scope/pkg@1.2.3", deps)
	}
}

// A package key without a version is malformed and reported as an unknown.
func TestParsePnpmLockReportsMalformedKey(t *testing.T) {
	lock := "packages:\n\n  'no-version-here':\n    resolution: {integrity: sha512-aaa}\n"

	deps, unknowns := parsePnpmLock([]byte(lock), "pnpm-lock.yaml")

	if len(deps) != 0 {
		t.Fatalf("deps = %+v, want none", deps)
	}
	if len(unknowns) != 1 {
		t.Fatalf("unknowns = %+v, want one", unknowns)
	}
}

// A missing pnpm-lock.yaml yields nothing, not a spurious unknown.
func TestExtractPnpmLockMissingFileYieldsNothing(t *testing.T) {
	deps, unknowns := ExtractPnpmLock(t.TempDir())

	if len(deps) != 0 || len(unknowns) != 0 {
		t.Fatalf("deps=%d unknowns=%d, want 0/0", len(deps), len(unknowns))
	}
}

// ExtractPnpmLock discovers the lockfile beneath the repository root.
func TestExtractPnpmLockDiscoversLockfile(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, "tools/streamdeck-plugin/pnpm-lock.yaml"), pnpmLockFixture)

	deps, unknowns := ExtractPnpmLock(root)

	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 2 {
		t.Fatalf("deps = %d, want 2", len(deps))
	}
}
