package extractorimpl

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"strimserver-check-deps/common"
)

// usesRe matches a workflow `uses:` reference in either shape: a list item
// (`- uses: owner/repo@ref`) or a mapping key that is a sibling of `- name:`
// (`        uses: owner/repo@ref`). The optional leading `- ` is what makes the
// mapping-key form match too.
var usesRe = regexp.MustCompile(`(?m)^[ \t]*(?:-[ \t]+)?uses:[ \t]*([^\s#]+)`)

// withVersionRe matches a `with:` version input line: an indented mapping key
// such as `go-version`, `go-version-file`, or `node-version-file`, followed by
// its value (optionally quoted). It is keyed on the known setup-action input
// names so unrelated `*-version` keys (e.g. a `build-version`) are not scraped.
var withVersionRe = regexp.MustCompile(`(?m)^[ \t]+((?:go|node|python|java|ruby|dotnet)-version(?:-file)?):[ \t]*["']?([^"'\s#]+)["']?`)

// withVersionToolNames maps a `with:` input key prefix to the toolchain it pins.
var withVersionToolNames = map[string]string{
	"go":     "Go",
	"node":   "Node",
	"python": "Python",
	"java":   "Java",
	"ruby":   "Ruby",
	"dotnet": ".NET",
}

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
	return common.RunSourceSpecs(root, specs)
}

// ExtractWorkflows must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractWorkflows

func isYAML(name string) bool {
	return strings.HasSuffix(name, ".yml") || strings.HasSuffix(name, ".yaml")
}

// parseWorkflow extracts every `uses: owner/repo@ref` action pin and every
// `with:` toolchain version input from one workflow file.
func parseWorkflow(data []byte, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	content := string(data)
	deps, unknowns := parseWorkflowUses(content, file)
	withDeps, withUnknowns := parseWorkflowVersionInputs(content, file)
	deps, unknowns = common.MergeExtract(deps, unknowns, withDeps, withUnknowns)
	if len(deps) == 0 && len(unknowns) == 0 {
		unknowns = append(unknowns, common.ExtractionUnknown{File: file, Reason: "no `uses:` action references found"})
	}
	return deps, unknowns
}

// parseWorkflowUses extracts the `uses: owner/repo@ref` action pins.
func parseWorkflowUses(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
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
	return deps, unknowns
}

// parseWorkflowVersionInputs extracts the toolchain versions a workflow pins
// through a `with:` input (e.g. actions/setup-go's go-version), tagging each
// with the workflow file. A `-file` input pins a path rather than a literal
// version; the finding notes that.
func parseWorkflowVersionInputs(content, file string) ([]common.Dependency, []common.ExtractionUnknown) {
	var deps []common.Dependency
	for _, m := range withVersionRe.FindAllStringSubmatch(content, -1) {
		key, value := m[1], m[2]
		tool, _, _ := strings.Cut(key, "-")
		name, ok := withVersionToolNames[tool]
		if !ok || value == "" {
			continue
		}
		note := ""
		if strings.HasSuffix(key, "-file") {
			note = "version read from file: " + value
		}
		deps = append(deps, common.Dependency{
			Category: common.CategoryToolchain,
			Name:     name,
			Version:  value,
			Source:   file + " `with:` " + key,
			File:     file,
			Note:     note,
		})
	}
	return deps, nil
}
