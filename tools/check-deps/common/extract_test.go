package common

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Unit tests for extract.go: ReadAndParse, MergeExtract, and RunSourceSpecs.
// All three are pure file/aggregation plumbing, so every case runs against
// real temp files or inline fixtures; no network is touched.

// --- ReadAndParse -----------------------------------------------------------

func TestReadAndParse(t *testing.T) {
	dir := t.TempDir()
	relPath := "pins/example.txt"
	wantBytes := []byte("rules_go = \"0.63.0\"\n")
	fixture := filepath.Join(dir, relPath)
	if err := os.MkdirAll(filepath.Dir(fixture), 0o755); err != nil {
		t.Fatalf("creating fixture directory: %v", err)
	}
	if err := os.WriteFile(fixture, wantBytes, 0o644); err != nil {
		t.Fatalf("writing fixture file: %v", err)
	}

	wantDeps := []Dependency{{Category: CategoryBazelModule, Name: "rules_go", Version: "0.63.0", File: relPath}}
	wantUnknowns := []ExtractionUnknown{{File: relPath, Reason: "unused"}}

	var gotBytes []byte
	var gotFile string
	parse := func(data []byte, file string) ([]Dependency, []ExtractionUnknown) {
		gotBytes = append([]byte(nil), data...)
		gotFile = file
		return wantDeps, wantUnknowns
	}

	deps, unknowns := ReadAndParse(dir, relPath, parse)
	if string(gotBytes) != string(wantBytes) {
		t.Errorf("ReadAndParse: parse received data=%q, want %q", gotBytes, wantBytes)
	}
	if gotFile != relPath {
		t.Errorf("ReadAndParse: parse received file=%q, want %q", gotFile, relPath)
	}
	if len(deps) != 1 || deps[0] != wantDeps[0] {
		t.Errorf("ReadAndParse: deps=%v, want %v", deps, wantDeps)
	}
	if len(unknowns) != 1 || unknowns[0] != wantUnknowns[0] {
		t.Errorf("ReadAndParse: unknowns=%v, want %v", unknowns, wantUnknowns)
	}
}

func TestReadAndParseMissingFile(t *testing.T) {
	dir := t.TempDir()
	relPath := "pins/absent.txt"

	deps, unknowns := ReadAndParse(dir, relPath, func([]byte, string) ([]Dependency, []ExtractionUnknown) {
		t.Fatal("parse must not run when the file cannot be read")
		return nil, nil
	})

	if deps != nil {
		t.Errorf("ReadAndParse missing file: deps=%v, want nil", deps)
	}
	if len(unknowns) != 1 {
		t.Fatalf("ReadAndParse missing file: %d unknowns, want exactly 1", len(unknowns))
	}
	if unknowns[0].File != relPath {
		t.Errorf("ReadAndParse missing file: unknown.File=%q, want %q", unknowns[0].File, relPath)
	}
	if !strings.Contains(unknowns[0].Reason, "cannot read file") {
		t.Errorf("ReadAndParse missing file: unknown.Reason=%q, want one containing %q", unknowns[0].Reason, "cannot read file")
	}
}

// --- MergeExtract -----------------------------------------------------------

func TestMergeExtract(t *testing.T) {
	deps := []Dependency{{Category: CategoryGo, Name: "first"}}
	unknowns := []ExtractionUnknown{{File: "a.txt", Reason: "first"}}
	addDeps := []Dependency{{Category: CategoryNPM, Name: "second"}}
	addUnknowns := []ExtractionUnknown{{File: "b.txt", Reason: "second"}}

	gotDeps, gotUnknowns := MergeExtract(deps, unknowns, addDeps, addUnknowns)
	wantDeps := append(append([]Dependency(nil), deps...), addDeps...)
	wantUnknowns := append(append([]ExtractionUnknown(nil), unknowns...), addUnknowns...)

	if len(gotDeps) != len(wantDeps) {
		t.Fatalf("MergeExtract: got %d deps, want %d", len(gotDeps), len(wantDeps))
	}
	for i := range wantDeps {
		if gotDeps[i] != wantDeps[i] {
			t.Errorf("MergeExtract: deps[%d]=%v, want %v", i, gotDeps[i], wantDeps[i])
		}
	}
	if len(gotUnknowns) != len(wantUnknowns) {
		t.Fatalf("MergeExtract: got %d unknowns, want %d", len(gotUnknowns), len(wantUnknowns))
	}
	for i := range wantUnknowns {
		if gotUnknowns[i] != wantUnknowns[i] {
			t.Errorf("MergeExtract: unknowns[%d]=%v, want %v", i, gotUnknowns[i], wantUnknowns[i])
		}
	}
}

// --- RunSourceSpecs ---------------------------------------------------------

func TestRunSourceSpecs(t *testing.T) {
	dir := t.TempDir()
	depFile := "dep.txt"
	unknownFile := "broken.txt"
	if err := os.WriteFile(filepath.Join(dir, depFile), []byte("pin data"), 0o644); err != nil {
		t.Fatalf("writing dep fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, unknownFile), []byte("unparsable data"), 0o644); err != nil {
		t.Fatalf("writing broken fixture: %v", err)
	}

	wantDep := Dependency{Category: CategoryToolBinary, Name: "golangci-lint", Version: "1.64.0", File: depFile}
	specs := []SourceSpec{
		{RelPath: depFile, Parse: func(data []byte, file string) ([]Dependency, []ExtractionUnknown) {
			return []Dependency{wantDep}, nil
		}},
		{RelPath: unknownFile, Parse: func(data []byte, file string) ([]Dependency, []ExtractionUnknown) {
			return nil, []ExtractionUnknown{{File: file, Reason: "parse failed"}}
		}},
	}

	deps, unknowns := RunSourceSpecs(dir, specs)

	if len(deps) != 1 || deps[0] != wantDep {
		t.Errorf("RunSourceSpecs: deps=%v, want [%v] in spec order", deps, wantDep)
	}
	if len(unknowns) != 1 || unknowns[0].File != unknownFile || unknowns[0].Reason != "parse failed" {
		t.Errorf("RunSourceSpecs: unknowns=%v, want one unknown for %q with reason %q", unknowns, unknownFile, "parse failed")
	}
}

func TestRunSourceSpecsEmpty(t *testing.T) {
	deps, unknowns := RunSourceSpecs(t.TempDir(), nil)
	if len(deps) != 0 {
		t.Errorf("RunSourceSpecs empty: got %d deps, want 0", len(deps))
	}
	if len(unknowns) != 0 {
		t.Errorf("RunSourceSpecs empty: got %d unknowns, want 0", len(unknowns))
	}
}
