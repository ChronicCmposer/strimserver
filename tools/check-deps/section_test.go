package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// This file covers the sectioned report: routing resolved dependencies into the
// inventory (lockfile-transitive) and integrity (hash-pin) sections, keeping
// them out of findings and the tier counts, the new per-section count totals,
// and the arch-twin / multi-file finding collapse with its pins array.

// sectionNow is the fixed clock for the pure sectioning tests.
func sectionNow() time.Time { return time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC) }

// resolvedIn builds a resolved record with the given dependency and outcome.
func resolvedIn(dep common.Dependency, ti common.Tier, st common.Status, latest string) common.Resolved {
	return common.Resolved{Dep: dep, Tier: ti, Status: st, Latest: latest}
}

// TestBuildReportRoutesInventoryAndIntegritySections proves the three-way
// routing: an inventory-tagged dep lands in Inventory, an integrity-role dep
// lands in Integrity, and the rest stay in Findings. The routed entries carry
// their real fields, are excluded from the tier counts, and never leak into the
// unknowns array.
func TestBuildReportRoutesInventoryAndIntegritySections(t *testing.T) {
	all := []common.Resolved{
		resolvedIn(common.Dependency{
			Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.63.0",
			Source: "https://bcr.bazel.build/modules/rules_go", File: "MODULE.bazel",
		}, common.TierT2, common.StatusUpdate, "0.64.0"),
		resolvedIn(common.Dependency{
			Category: common.CategoryGo, Name: "golang.org/x/text", Version: "v0.3.0",
			Source: "go.sum transitive module", File: "core/controller/go.sum", Note: inventoryNote,
		}, common.TierT3, common.StatusUnknown, ""),
		resolvedIn(common.Dependency{
			Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "0123abcd",
			Source: "tools/ffmpeg-dist/build.sh", File: "tools/ffmpeg-dist/build.sh",
			Role: common.RoleIntegrity,
		}, common.TierT1, common.StatusIntegrity, ""),
	}

	rep := buildReport(all, nil, nil, sectionNow(), false)

	if len(rep.Findings) != 1 || rep.Findings[0].Name != "rules_go" {
		t.Fatalf("findings = %+v, want only rules_go", rep.Findings)
	}

	if len(rep.Inventory) != 1 {
		t.Fatalf("inventory = %+v, want 1 entry", rep.Inventory)
	}
	if got := rep.Inventory[0]; got.Category != common.CategoryGo || got.Name != "golang.org/x/text" ||
		got.Current != "v0.3.0" || got.File != "core/controller/go.sum" ||
		got.Source != "go.sum transitive module" || got.Note != inventoryNote {
		t.Errorf("inventory entry = %+v", got)
	}

	if len(rep.Integrity) != 1 {
		t.Fatalf("integrity = %+v, want 1 entry", rep.Integrity)
	}
	if got := rep.Integrity[0]; got.Category != common.CategoryScriptPin || got.Name != "ffmpeg" ||
		got.Current != "0123abcd" || got.File != "tools/ffmpeg-dist/build.sh" {
		t.Errorf("integrity entry = %+v", got)
	}

	// Sections are excluded from the tier counts; the per-section totals are
	// present; total still counts every dependency.
	if rep.Counts.Inventory != 1 || rep.Counts.Integrity != 1 {
		t.Errorf("section totals = inventory:%d integrity:%d, want 1/1", rep.Counts.Inventory, rep.Counts.Integrity)
	}
	if rep.Counts.T1 != 0 || rep.Counts.T2 != 1 || rep.Counts.T3 != 0 {
		t.Errorf("tier counts = t1:%d t2:%d t3:%d, want 0/1/0 (sections excluded)", rep.Counts.T1, rep.Counts.T2, rep.Counts.T3)
	}
	if rep.Counts.Total != 3 {
		t.Errorf("total = %d, want 3", rep.Counts.Total)
	}

	for _, u := range rep.Unknowns {
		if u.Name == "golang.org/x/text" {
			t.Errorf("inventory dep leaked into unknowns: %+v", u)
		}
	}
}

// TestBuildReportSectionsSortedDeterministically proves both section arrays are
// ordered deterministically (category, then name) so the JSON is reproducible.
func TestBuildReportSectionsSortedDeterministically(t *testing.T) {
	all := []common.Resolved{
		resolvedIn(common.Dependency{Category: common.CategoryGo, Name: "zeta", Version: "v1", File: "z/go.sum", Note: inventoryNote}, common.TierT3, common.StatusUnknown, ""),
		resolvedIn(common.Dependency{Category: common.CategoryGo, Name: "alpha", Version: "v1", File: "a/go.sum", Note: inventoryNote}, common.TierT3, common.StatusUnknown, ""),
		resolvedIn(common.Dependency{Category: common.CategoryScriptPin, Name: "gamma", Version: "h1", File: "x.sh", Role: common.RoleIntegrity}, common.TierT1, common.StatusIntegrity, ""),
		resolvedIn(common.Dependency{Category: common.CategoryScriptPin, Name: "beta", Version: "h2", File: "y.sh", Role: common.RoleIntegrity}, common.TierT1, common.StatusIntegrity, ""),
	}

	first, err := marshalReport(buildReport(all, nil, nil, sectionNow(), false))
	if err != nil {
		t.Fatalf("marshalReport: %v", err)
	}
	second, err := marshalReport(buildReport(all, nil, nil, sectionNow(), false))
	if err != nil {
		t.Fatalf("marshalReport: %v", err)
	}
	if string(first) != string(second) {
		t.Error("section reports are not deterministic across runs")
	}

	rep := buildReport(all, nil, nil, sectionNow(), false)
	if rep.Inventory[0].Name != "alpha" || rep.Inventory[1].Name != "zeta" {
		t.Errorf("inventory not sorted by name: %+v", rep.Inventory)
	}
	if rep.Integrity[0].Name != "beta" || rep.Integrity[1].Name != "gamma" {
		t.Errorf("integrity not sorted by name: %+v", rep.Integrity)
	}
}

// TestBuildReportCollapsesArchTwins proves two per-arch pins of one logical dep
// collapse into a single finding whose metadata marks the mixed-arch drift and
// whose counts are counted once (logical, not physical).
func TestBuildReportCollapsesArchTwins(t *testing.T) {
	all := []common.Resolved{
		resolvedIn(common.Dependency{
			Category: common.CategoryToolBinary, Name: "golangci_lint_linux_amd64",
			Version: "2.13.0", Source: "https://github.com/golangci/golangci-lint", File: "MODULE.bazel",
		}, common.TierT2, common.StatusUpdate, "2.14.0"),
		resolvedIn(common.Dependency{
			Category: common.CategoryToolBinary, Name: "golangci_lint_linux_arm64",
			Version: "2.13.0", Source: "https://github.com/golangci/golangci-lint", File: "MODULE.bazel",
		}, common.TierT2, common.StatusUpdate, "2.14.0"),
	}

	rep := buildReport(all, nil, nil, sectionNow(), false)

	if len(rep.Findings) != 1 {
		t.Fatalf("findings = %d, want 1 collapsed logical dep: %+v", len(rep.Findings), rep.Findings)
	}
	f := rep.Findings[0]
	if f.Name != "golangci_lint_linux" {
		t.Errorf("collapsed name = %q, want arch-normalized base", f.Name)
	}
	if len(f.Pins) == 0 {
		t.Errorf("collapsed finding carries no pins: %+v", f)
	}
	if !strings.Contains(f.Metadata["drift"], "mixed-arch") {
		t.Errorf("metadata drift = %q, want it to mention mixed-arch", f.Metadata["drift"])
	}
	if rep.Counts.T2 != 1 {
		t.Errorf("t2 = %d, want 1 (logical finding counted once)", rep.Counts.T2)
	}
	if rep.Counts.Total != 1 {
		t.Errorf("total = %d, want 1 (logical)", rep.Counts.Total)
	}

	// The collapsed pins must survive a JSON round-trip (the machine contract).
	data, err := marshalReport(rep)
	if err != nil {
		t.Fatalf("marshalReport: %v", err)
	}
	var back report
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal report: %v", err)
	}
	if len(back.Findings) != 1 || len(back.Findings[0].Pins) == 0 {
		t.Errorf("collapsed pins did not survive JSON round-trip: %+v", back.Findings)
	}
}

// TestBuildReportCollapsesMultiFilePins proves the same logical dep (same
// category and name) declared in two files collapses into one finding with a
// pins entry per file, sorted by file.
func TestBuildReportCollapsesMultiFilePins(t *testing.T) {
	all := []common.Resolved{
		resolvedIn(common.Dependency{
			Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4",
			Source: "https://download.qemu.org", File: "tools/ffmpeg-dist/build.sh",
		}, common.TierT2, common.StatusUpdate, "9.2.5"),
		resolvedIn(common.Dependency{
			Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4",
			Source: "https://download.qemu.org", File: "tools/openssh/build.sh",
		}, common.TierT2, common.StatusUpdate, "9.2.5"),
	}

	rep := buildReport(all, nil, nil, sectionNow(), false)

	if len(rep.Findings) != 1 {
		t.Fatalf("findings = %d, want 1 collapsed dep: %+v", len(rep.Findings), rep.Findings)
	}
	f := rep.Findings[0]
	if f.Name != "qemu" {
		t.Errorf("collapsed name = %q, want qemu", f.Name)
	}
	if len(f.Pins) != 2 {
		t.Fatalf("pins = %+v, want 2 entries (one per file)", f.Pins)
	}
	if f.Pins[0].File != "tools/ffmpeg-dist/build.sh" || f.Pins[1].File != "tools/openssh/build.sh" {
		t.Errorf("pins not sorted by file: %+v", f.Pins)
	}
	if f.Pins[0].Version != "9.2.4" || f.Pins[1].Version != "9.2.4" {
		t.Errorf("pins versions = %+v, want 9.2.4 each", f.Pins)
	}
	if rep.Counts.T2 != 1 || rep.Counts.Total != 1 {
		t.Errorf("counts = t2:%d total:%d, want 1/1 (logical)", rep.Counts.T2, rep.Counts.Total)
	}
}

// TestBuildReportMixedVersionDriftVisible proves per-file version drift within
// one logical dep is visible both in the pins array and in metadata.
func TestBuildReportMixedVersionDriftVisible(t *testing.T) {
	all := []common.Resolved{
		resolvedIn(common.Dependency{Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.4", File: "tools/a/build.sh"}, common.TierT2, common.StatusUpdate, "9.2.5"),
		resolvedIn(common.Dependency{Category: common.CategoryScriptPin, Name: "qemu", Version: "9.2.3", File: "tools/b/build.sh"}, common.TierT2, common.StatusUpdate, "9.2.5"),
	}

	rep := buildReport(all, nil, nil, sectionNow(), false)
	if len(rep.Findings) != 1 {
		t.Fatalf("findings = %d, want 1", len(rep.Findings))
	}
	f := rep.Findings[0]
	if len(f.Pins) != 2 {
		t.Fatalf("pins = %+v, want both versions visible", f.Pins)
	}
	if !strings.Contains(f.Metadata["drift"], "mixed-version") {
		t.Errorf("metadata drift = %q, want it to mention mixed-version", f.Metadata["drift"])
	}
}

// TestConsoleRendersSections proves the console report shows the integrity and
// inventory sections flat and readable.
func TestConsoleRendersSections(t *testing.T) {
	all := []common.Resolved{
		resolvedIn(common.Dependency{Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.63.0"}, common.TierT2, common.StatusUpdate, "0.64.0"),
		resolvedIn(common.Dependency{Category: common.CategoryGo, Name: "golang.org/x/text", Version: "v0.3.0", File: "core/controller/go.sum", Note: inventoryNote}, common.TierT3, common.StatusUnknown, ""),
		resolvedIn(common.Dependency{Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "0123abcd", File: "tools/ffmpeg-dist/build.sh", Role: common.RoleIntegrity}, common.TierT1, common.StatusIntegrity, ""),
	}
	rep := buildReport(all, nil, nil, sectionNow(), false)
	out := renderConsole(rep, "/repo")

	if !strings.Contains(out, "Integrity (hash pins) — 1") {
		t.Errorf("console missing integrity section:\n%s", out)
	}
	if !strings.Contains(out, "Inventory (transitive) — 1") {
		t.Errorf("console missing inventory section:\n%s", out)
	}
	if !strings.Contains(out, "golang.org/x/text") || !strings.Contains(out, "ffmpeg") {
		t.Errorf("console sections do not name their entries:\n%s", out)
	}
}
