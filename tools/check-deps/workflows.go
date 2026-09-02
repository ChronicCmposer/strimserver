package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var usesRe = regexp.MustCompile(`(?m)^\s*-\s*uses:\s*([^\s#]+)`)

// extractWorkflows lists every workflow under .github/workflows and parses the
// pinned `uses:` action references in each.
func extractWorkflows(root string) ([]dependency, []unknown) {
	workflowDir := filepath.Join(root, ".github", "workflows")
	entries, err := os.ReadDir(workflowDir)
	if err != nil {
		return nil, []unknown{{File: ".github/workflows", Reason: "cannot list workflow files: " + err.Error()}}
	}
	var deps []dependency
	var unknowns []unknown
	for _, entry := range entries {
		if entry.IsDir() || !isYAML(entry.Name()) {
			continue
		}
		rel := filepath.Join(".github", "workflows", entry.Name())
		gotDeps, gotUnknowns := readAndParse(root, rel, parseWorkflow)
		deps = append(deps, gotDeps...)
		unknowns = append(unknowns, gotUnknowns...)
	}
	// The same action pin (e.g. actions/checkout@v4) is reused across jobs and
	// workflow files; report each distinct pin once.
	return dedupe(deps), unknowns
}

func isYAML(name string) bool {
	return strings.HasSuffix(name, ".yml") || strings.HasSuffix(name, ".yaml")
}

// parseWorkflow extracts every `uses: owner/repo@ref` action pin from one
// workflow file.
func parseWorkflow(data []byte, file string) ([]dependency, []unknown) {
	content := string(data)
	var deps []dependency
	var unknowns []unknown
	for _, m := range usesRe.FindAllStringSubmatch(content, -1) {
		ref := m[1]
		name, version, found := strings.Cut(ref, "@")
		if !found || name == "" || version == "" {
			unknowns = append(unknowns, unknown{File: file, Reason: "malformed uses: ref: " + ref})
			continue
		}
		deps = append(deps, dependency{
			Category: "ci-action",
			Name:     name,
			Version:  version,
			Source:   "https://github.com/" + name,
			File:     file,
		})
	}
	if len(deps) == 0 && len(unknowns) == 0 {
		unknowns = append(unknowns, unknown{File: file, Reason: "no `uses:` action references found"})
	}
	return deps, unknowns
}
