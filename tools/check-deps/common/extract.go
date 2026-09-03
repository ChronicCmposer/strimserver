package common

import (
	"os"
	"path/filepath"
)

// Extractor reads the source file (or directory) it owns under the repo root
// and returns the dependencies found plus any entries that could not be
// extracted. Extractors are the only place that touches the filesystem for
// their own source; parsing itself is delegated to pure functions.
type Extractor func(root string) ([]Dependency, []ExtractionUnknown)

// SourceSpec pairs one repo-relative source file with the pure parser that
// extracts its pins.
type SourceSpec struct {
	RelPath string
	Parse   func(data []byte, file string) ([]Dependency, []ExtractionUnknown)
}

// RunSourceSpecs runs every SourceSpec against the repo root and aggregates
// the results, so each extraction pass folds in deps and unknowns identically.
func RunSourceSpecs(root string, specs []SourceSpec) ([]Dependency, []ExtractionUnknown) {
	var deps []Dependency
	var unknowns []ExtractionUnknown
	for _, spec := range specs {
		gotDeps, gotUnknowns := ReadAndParse(root, spec.RelPath, spec.Parse)
		deps, unknowns = MergeExtract(deps, unknowns, gotDeps, gotUnknowns)
	}
	return deps, unknowns
}

// ReadAndParse reads one repo-relative file and hands its bytes to the pure
// parser. A missing or unreadable file becomes a single unknown record, never
// a crash: the tool must stay robust when a source file is absent.
func ReadAndParse(root, relPath string, parse func(data []byte, file string) ([]Dependency, []ExtractionUnknown)) ([]Dependency, []ExtractionUnknown) {
	data, err := os.ReadFile(filepath.Join(root, relPath))
	if err != nil {
		return nil, []ExtractionUnknown{{File: relPath, Reason: "cannot read file: " + err.Error()}}
	}
	return parse(data, relPath)
}

// MergeExtract folds one extraction pass's outputs into the running results,
// so every pass site aggregates deps and unknowns identically.
func MergeExtract(deps []Dependency, unknowns []ExtractionUnknown, d []Dependency, u []ExtractionUnknown) ([]Dependency, []ExtractionUnknown) {
	return append(deps, d...), append(unknowns, u...)
}
