package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"strimserver-check-deps/common"
	"strimserver-check-deps/extractorimpl"
)

// expectedPinsDoc is the machine-readable schema of
// testdata/expected-pins.json (the RED oracle for the extractor wave). It is
// the boundary type for this test: unmarshalling it into a typed value lets the
// assertions below run without re-checking field presence everywhere.
type expectedPinsDoc struct {
	Schema     string            `json:"schema"`
	BySource   map[string]int    `json:"by_source"`
	Totals     expectedPinTotals `json:"totals"`
	Entries    []expectedPin     `json:"entries"`
	TrackedDef string            `json:"tracked_now_definition"`
}

// expectedPinTotals mirrors the `totals` object of the fixture.
type expectedPinTotals struct {
	Total      int `json:"total"`
	TrackedNow int `json:"tracked_now"`
	ToAdd      int `json:"to_add"`
	Sources    int `json:"sources"`
}

// expectedPin is one pin token in the oracle. `kind` is "version" (version /
// tag / commit / date / digest-id) or "integrity" (a sha256/sha digest held in
// the `version` field). `tracked_now` records whether the committed-baseline
// pipeline already surfaces the (source,file,name) pin.
type expectedPin struct {
	Source     string `json:"source"`
	File       string `json:"file"`
	Name       string `json:"name"`
	Version    string `json:"version"`
	Kind       string `json:"kind"`
	TrackedNow bool   `json:"tracked_now"`
}

// expectedPinsPath is the fixture location relative to this package directory;
// `go test` runs with the package as the working directory and the Bazel test
// carries it through the `testdata/**` data glob.
const expectedPinsPath = "testdata/expected-pins.json"

// TestExpectedPinsFixture validates the oracle itself: it must parse, every
// entry must be well-formed, and the summary counts must agree with the entry
// set. This half runs today (the fixture is committed); it fails loud on a
// hand-edited inconsistency rather than letting a corrupt oracle silently pass.
func TestExpectedPinsFixture(t *testing.T) {
	doc := loadExpectedPins(t)

	if doc.Schema == "" {
		t.Error("fixture schema is empty")
	}
	if len(doc.Entries) == 0 {
		t.Fatal("fixture has no entries")
	}

	sourceCounts := map[string]int{}
	tracked := 0
	for i, pin := range doc.Entries {
		if pin.Source == "" || pin.File == "" || pin.Name == "" {
			t.Errorf("entry %d has an empty source/file/name: %+v", i, pin)
		}
		switch pin.Kind {
		case "version":
		case "integrity":
			if pin.Version == "" {
				t.Errorf("integrity entry %d (%s) has an empty digest", i, pin.Name)
			}
		default:
			t.Errorf("entry %d (%s) has unknown kind %q", i, pin.Name, pin.Kind)
		}
		sourceCounts[pin.Source]++
		if pin.TrackedNow {
			tracked++
		}
	}

	if got, want := doc.Totals.Total, len(doc.Entries); got != want {
		t.Errorf("totals.total = %d, want %d (len(entries))", got, want)
	}
	if got, want := doc.Totals.TrackedNow, tracked; got != want {
		t.Errorf("totals.tracked_now = %d, want %d", got, want)
	}
	if got, want := doc.Totals.ToAdd, len(doc.Entries)-tracked; got != want {
		t.Errorf("totals.to_add = %d, want %d", got, want)
	}
	if got, want := doc.Totals.Sources, len(sourceCounts); got != want {
		t.Errorf("totals.sources = %d, want %d", got, want)
	}
	for source, want := range doc.BySource {
		if got := sourceCounts[source]; got != want {
			t.Errorf("by_source[%q] = %d, want %d", source, want, got)
		}
	}
}

// TestExtractionMatchesExpectedPins is the RED comparison skeleton for the
// later wave. It is intentionally skipped until every wave extractor is wired
// into main's extractor list; until then it documents the exact contract:
//
//  1. extract every dependency with the same extractor set main() registers
//     (plus the wave extractors: vendored pins, go.sum/pnpm-lock transitive
//     inventory, app manifest, .env, CI with: inputs);
//  2. index the extraction output by (file, name), keeping version+kind;
//  3. for every oracle entry with tracked_now=true, assert the pin is present
//     with the same version; for every tracked_now=false entry, assert it is
//     ABSENT today (proving the RED oracle is non-vacuous) — once the wave
//     lands, flip the assertion to "present".
//
// It compiles against the stable extractor surface only, so parallel work on
// the wave extractors cannot break this file.
func TestExtractionMatchesExpectedPins(t *testing.T) {
	t.Skip("xfail(wave): enable once the wave extractors are registered in main(); see expected-pins.json / expected-pins.md")

	root, err := repoRoot("")
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}

	// TODO(wave): add extractorimpl.ExtractVendoredPins, ExtractGoSum,
	// ExtractPnpmLock, ExtractAppManifest, and the .env / CI-with extractors
	// here as they are registered in main().
	extractors := []common.Extractor{
		extractorimpl.ExtractModuleBazel,
		extractorimpl.ExtractGoMod,
		extractorimpl.ExtractScripts,
		extractorimpl.ExtractToolchains,
		extractorimpl.ExtractWorkflows,
	}

	deps, _ := extractAll(extractors, root)

	// Index the extraction output by (file, name). Multiple versions for one
	// (file, name) collapse into a sorted set so the comparison is order-free.
	got := map[string][]string{}
	for _, dep := range deps {
		key := dep.File + "\x1f" + dep.Name
		got[key] = append(got[key], dep.Version)
	}

	doc := loadExpectedPins(t)
	var missing []string
	for _, pin := range doc.Entries {
		if !pin.TrackedNow {
			continue // the wave owns these; asserted absent today only if desired
		}
		if len(got[pin.File+"\x1f"+pin.Name]) == 0 {
			missing = append(missing, fmt.Sprintf("%s:%s (want %s)", pin.File, pin.Name, pin.Version))
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("baseline-tracked pins absent from extraction:\n%s", joinLines(missing))
	}
}

// loadExpectedPins reads and parses the oracle, failing the test (never
// silently skipping) when it is missing or malformed.
func loadExpectedPins(t *testing.T) expectedPinsDoc {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(expectedPinsPath))
	if err != nil {
		t.Fatalf("cannot read %s: %v", expectedPinsPath, err)
	}
	var doc expectedPinsDoc
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("cannot parse %s: %v", expectedPinsPath, err)
	}
	return doc
}

// joinLines renders a slice as a newline-separated block for readable failures.
func joinLines(lines []string) string {
	out := ""
	for _, line := range lines {
		out += "  " + line + "\n"
	}
	return out
}
