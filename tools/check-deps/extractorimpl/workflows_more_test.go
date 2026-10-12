package extractorimpl

import (
	"testing"

	"strimserver-check-deps/common"
)

// TestParseWorkflowMappingKeyUses proves a `uses:` written as a mapping key
// (sibling of `- name:`, not preceded by `- `) is matched. The real
// deps-check.yml upload-artifact step is exactly this shape.
func TestParseWorkflowMappingKeyUses(t *testing.T) {
	const workflow = `jobs:
  deps-check:
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Upload the dependency report
        uses: actions/upload-artifact@v4
        with:
          name: deps-check
`
	deps, unknowns := parseWorkflow([]byte(workflow), ".github/workflows/deps-check.yml")
	if len(unknowns) != 0 {
		t.Fatalf("parseWorkflow unknowns = %v, want none", unknowns)
	}
	if got := findDep(t, deps, common.CategoryCIAction, "actions/checkout"); got == nil || got.Version != "v7.0.1" {
		t.Errorf("list-item uses not extracted: %v", got)
	}
	if got := findDep(t, deps, common.CategoryCIAction, "actions/upload-artifact"); got == nil || got.Version != "v4" {
		t.Errorf("mapping-key uses not extracted: %v", got)
	}
}

// TestParseWorkflowWithVersionInputs proves `with:` version inputs are scraped
// as toolchain deps tagged with the workflow file, alongside the action pins.
func TestParseWorkflowWithVersionInputs(t *testing.T) {
	const workflow = `jobs:
  build:
    steps:
      - uses: actions/setup-go@v7.0.0
        with:
          go-version: 1.26.4
      - uses: actions/setup-node@v7.0.0
        with:
          node-version-file: tools/streamdeck-plugin/.nvmrc
`
	deps, unknowns := parseWorkflow([]byte(workflow), ".github/workflows/deps-check.yml")
	if len(unknowns) != 0 {
		t.Fatalf("parseWorkflow unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, common.CategoryToolchain, "Go", "1.26.4"); got == nil {
		t.Errorf("go-version input not extracted: %v", deps)
	} else if got.File != ".github/workflows/deps-check.yml" {
		t.Errorf("Go File = %q, want the workflow file", got.File)
	}
	if got := findDepVersion(t, deps, common.CategoryToolchain, "Node", "tools/streamdeck-plugin/.nvmrc"); got == nil {
		t.Errorf("node-version-file input not extracted: %v", deps)
	}
	if findDep(t, deps, common.CategoryCIAction, "actions/setup-go") == nil {
		t.Errorf("action pin alongside with: not extracted: %v", deps)
	}
}

// TestParseWorkflowWithQuotedVersion proves a quoted with: value is unwrapped.
func TestParseWorkflowWithQuotedVersion(t *testing.T) {
	const workflow = "steps:\n  - uses: actions/setup-go@v7.0.0\n    with:\n      go-version: \"1.26.4\"\n"
	deps, _ := parseWorkflow([]byte(workflow), ".github/workflows/x.yml")
	if got := findDepVersion(t, deps, common.CategoryToolchain, "Go", "1.26.4"); got == nil {
		t.Errorf("quoted go-version not unwrapped: %v", deps)
	}
}
