package extractorimpl

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"strimserver-check-deps/common"
)

var usesRe = regexp.MustCompile(`(?m)^\s*-\s*uses:\s*([^\s#]+)`)

// ExtractWorkflows lists every workflow under .github/workflows and parses the
// pinned `uses:` action references in each.
func ExtractWorkflows(root string) ([]common.Dependency, []common.ExtractionUnknown) {
	workflowDir := filepath.Join(root, ".github", "workflows")
	entries, err := os.ReadDir(workflowDir)
	if err != nil {
		return nil, []common.ExtractionUnknown{{File: ".github/workflows", Reason: "cannot list workflow files: " + err.Error()}}
	}
	var specs []common.SourceSpec
	for _, entry := range entries {
		if entry.IsDir() || !isYAML(entry.Name()) {
			continue
		}
		specs = append(specs, common.SourceSpec{
			RelPath: filepath.Join(".github", "workflows", entry.Name()),
			Parse:   parseWorkflow,
		})
	}
	// The same action pin (e.g. actions/checkout@v4) is reused across jobs and
	// workflow files; resolveAll dedupes the aggregate, so each pin is reported
	// exactly once.
	return common.RunSourceSpecs(root, specs)
}

func isYAML(name string) bool {
	return strings.HasSuffix(name, ".yml") || strings.HasSuffix(name, ".yaml")
}

// parseWorkflow extracts every `uses: owner/repo@ref` action pin from one
// workflow file.
func parseWorkflow(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	var deps []common.Dependency
	var unknowns []common.ExtractionUnknown
	for _, m := range usesRe.FindAllStringSubmatch(content, -1) {
		ref := m[1]
		name, version, found := strings.Cut(ref, "@")
		if !found || name == "" || version == "" {
			unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "malformed uses: ref: " + ref})
			continue
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryCIAction,
			Name:     name,
			Version:  version,
			Source:   "https://github.com/" + name,
			File:     file,
		})
	}
	if len(deps) == 0 && len(unknowns) == 0 {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "no `uses:` action references found"})
	}
	return deps, unknowns
}
