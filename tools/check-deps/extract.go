package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// extractor reads the source file (or directory) it owns under the repo root
// and returns the dependencies found plus any entries that could not be
// extracted. Extractors are the only place that touches the filesystem for
// their own source; parsing itself is delegated to pure functions.
type extractor func(root string) ([]dependency, []unknown)

// extractors is the ordered set of every Phase 1 extraction pass.
var extractors = []struct {
	label string
	run   extractor
}{
	{"MODULE.bazel", extractModuleBazel},
	{"core/controller/go.mod", extractGoMod},
	{"toolchains (.bazelversion, .nvmrc, package.json)", extractToolchains},
	{"ci workflows (.github/workflows/*.yml)", extractWorkflows},
	{"build scripts", extractScripts},
}

// runAll runs every extractor against the repository and aggregates the
// results. Extraction failures never abort the run: they surface as unknown
// records alongside the successful dependencies.
func runAll(root string) ([]dependency, []unknown) {
	var deps []dependency
	var unknowns []unknown
	for _, ex := range extractors {
		gotDeps, gotUnknowns := ex.run(root)
		deps = append(deps, gotDeps...)
		unknowns = append(unknowns, gotUnknowns...)
	}
	return deps, unknowns
}

// readAndParse reads one repo-relative file and hands its bytes to the pure
// parser. A missing or unreadable file becomes a single unknown record, never
// a crash: the tool must stay robust when a source file is absent.
func readAndParse(root, relPath string, parse func(data []byte, file string) ([]dependency, []unknown)) ([]dependency, []unknown) {
	data, err := os.ReadFile(filepath.Join(root, relPath))
	if err != nil {
		return nil, []unknown{{File: relPath, Reason: "cannot read file: " + err.Error()}}
	}
	return parse(data, relPath)
}

// repoRoot resolves the repository root. Under `bazel run` Bazel sets
// BUILD_WORKSPACE_DIRECTORY to the workspace root; otherwise walk up from the
// working directory until a MODULE.bazel file is found. An unresolvable root is
// an operational failure (exit 1), never a silent empty report.
func repoRoot() (string, error) {
	if workspace := os.Getenv("BUILD_WORKSPACE_DIRECTORY"); workspace != "" {
		if !isFile(filepath.Join(workspace, "MODULE.bazel")) {
			return "", fmt.Errorf("BUILD_WORKSPACE_DIRECTORY %s contains no MODULE.bazel", workspace)
		}
		return workspace, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("cannot determine working directory: %w", err)
	}
	for {
		if isFile(filepath.Join(dir, "MODULE.bazel")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no MODULE.bazel found in %s or any parent directory", dir)
		}
		dir = parent
	}
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// dedupe drops duplicate dependencies keyed by (category, name, version),
// keeping the first occurrence. Script groups (e.g. build.sh + publish.sh)
// declare the same pins, so each pin is reported exactly once.
func dedupe(deps []dependency) []dependency {
	seen := make(map[[3]string]bool)
	unique := make([]dependency, 0, len(deps))
	for _, dep := range deps {
		key := [3]string{dep.Category, dep.Name, dep.Version}
		if seen[key] {
			continue
		}
		seen[key] = true
		unique = append(unique, dep)
	}
	return unique
}
