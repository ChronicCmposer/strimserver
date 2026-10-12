package extractorimpl

import (
	"path/filepath"
	"testing"

	"strimserver-check-deps/common"
)

const goSumFixtureMod = "module example.com/app\n" +
	"\n" +
	"go 1.26.4\n" +
	"\n" +
	"require (\n" +
	"\texample.com/kept v1.2.3\n" +
	")\n"

const goSumFixtureSum = "example.com/kept v1.2.3 h1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\n" +
	"example.com/kept v1.2.3/go.mod h1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\n" +
	"example.com/only-in-sum v0.1.0 h1:ccccccccccccccccccccccccccccccccccccccccccc=\n" +
	"example.com/only-in-sum v0.1.0/go.mod h1:ddddddddddddddddddddddddddddddddddddddddddd=\n"

// A module pinned by a require directive is not transitive, while a module that
// appears only in go.sum is emitted once (the h1 and /go.mod lines collapse).
func TestParseGoSumEmitsOnlyModulesAbsentFromRequire(t *testing.T) {
	deps, unknowns := parseGoSum([]byte(goSumFixtureSum), "core/controller/go.sum", parseGoModRequirePairs([]byte(goSumFixtureMod)))

	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("deps = %d (%+v), want 1", len(deps), deps)
	}
	got := deps[0]
	if got.Category != common.CategoryGo {
		t.Errorf("Category = %q, want %q", got.Category, common.CategoryGo)
	}
	if got.Name != "example.com/only-in-sum" || got.Version != "v0.1.0" {
		t.Errorf("Name/Version = %q/%q, want example.com/only-in-sum/v0.1.0", got.Name, got.Version)
	}
	if got.Note != inventoryNote {
		t.Errorf("Note = %q, want %q", got.Note, inventoryNote)
	}
	if got.File != "core/controller/go.sum" {
		t.Errorf("File = %q, want core/controller/go.sum", got.File)
	}
}

// A go.sum entry whose module is required at a different version is still
// transitive: transitivity is judged per (module, version) pair, not per module.
func TestParseGoSumTreatsOtherVersionOfRequiredModuleAsTransitive(t *testing.T) {
	mod := []byte("module example.com/app\n\nrequire example.com/kept v1.2.4\n")
	sum := []byte("example.com/kept v1.2.3 h1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\n")

	deps, _ := parseGoSum(sum, "core/controller/go.sum", parseGoModRequirePairs(mod))

	if len(deps) != 1 || deps[0].Name != "example.com/kept" || deps[0].Version != "v1.2.3" {
		t.Fatalf("deps = %+v, want the v1.2.3 entry as transitive", deps)
	}
}

// A malformed go.sum line is reported as an unknown, never a panic.
func TestParseGoSumSkipsMalformedLine(t *testing.T) {
	deps, unknowns := parseGoSum([]byte("malformed-without-version\n"), "core/controller/go.sum", nil)

	if len(deps) != 0 {
		t.Fatalf("deps = %+v, want none", deps)
	}
	if len(unknowns) != 1 || unknowns[0].File != "core/controller/go.sum" {
		t.Fatalf("unknowns = %+v, want one for core/controller/go.sum", unknowns)
	}
}

// A missing go.sum yields nothing, not a spurious unknown.
func TestExtractGoSumMissingFileYieldsNothing(t *testing.T) {
	deps, unknowns := ExtractGoSum(t.TempDir())

	if len(deps) != 0 || len(unknowns) != 0 {
		t.Fatalf("deps=%d unknowns=%d, want 0/0", len(deps), len(unknowns))
	}
}

// ExtractGoSum pairs a discovered go.sum with the go.mod in the same directory.
func TestExtractGoSumPairsSiblingGoMod(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, "core/controller/go.mod"), goSumFixtureMod)
	writeFixture(t, filepath.Join(root, "core/controller/go.sum"), goSumFixtureSum)

	deps, unknowns := ExtractGoSum(root)

	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 || deps[0].Name != "example.com/only-in-sum" {
		t.Fatalf("deps = %+v, want the single transitive module", deps)
	}
}
