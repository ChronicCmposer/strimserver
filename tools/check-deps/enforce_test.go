package main

import (
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"

	"strimserver-check-deps/common"
)

// This file covers the enforcement wave: the blast-radius tier rules for the
// image-linked tool binaries and the fish script pin, the --strict default-on
// wiring and --native-tools hermetic switch, and the strict/ignore interaction
// (an ignored unknown satisfies --strict; integrity/inventory are exempt; an
// expired or malformed `until` fails closed).

// enforceNow is the fixed clock for the strict/ignore tests.
func enforceNow() time.Time { return time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC) }

// resolvedUnknown builds a finding-section resolved record with an unknown
// status, the shape strictFailure inspects.
func resolvedUnknown(dep common.Dependency) common.Resolved {
	return common.Resolved{Dep: dep, Status: common.StatusUnknown, Tier: common.TierT3}
}

// TestNewClassifierRestsImageLinkedToolBinariesAtT2 proves the named
// blast-radius rules keep the image-linked C tool binaries at T2 even though the
// tool-binary category default could be changed later. A matching version keeps
// the resting tier intact through classification.
func TestNewClassifierRestsImageLinkedToolBinariesAtT2(t *testing.T) {
	c := newClassifier()
	names := []string{"curl", "mbedtls", "cares", "libwebsockets", "protobuf_c", "containerd_api"}
	for _, name := range names {
		dep := common.Dependency{Category: common.CategoryToolBinary, Name: name, Version: "1.0.0"}
		got := c.Classify(dep, common.VersionInfo{Version: "1.0.0"})
		if got.Tier != common.TierT2 {
			t.Errorf("tool-binary/%s resting tier = %s, want T2", name, got.Tier)
		}
	}
}

// TestNewClassifierRestsFishAtT2 proves the fish shell script pin rests at T2,
// above the script-pin T3 fallback (there is no script-pin category default).
func TestNewClassifierRestsFishAtT2(t *testing.T) {
	c := newClassifier()
	dep := common.Dependency{Category: common.CategoryScriptPin, Name: "fish", Version: "4.3.1"}
	got := c.Classify(dep, common.VersionInfo{Version: "4.3.1"})
	if got.Tier != common.TierT2 {
		t.Errorf("script-pin/fish resting tier = %s, want T2", got.Tier)
	}
}

// TestNewClassifierRestsMediamtxArmTwinAtT1 proves the arm64 twin of the
// security-critical media server binary rests at T1 like its amd64 sibling,
// rather than falling through to the T2 tool-binary default.
func TestNewClassifierRestsMediamtxArmTwinAtT1(t *testing.T) {
	c := newClassifier()
	for _, name := range []string{"mediamtx_dist", "mediamtx_dist_arm64"} {
		dep := common.Dependency{Category: common.CategoryToolBinary, Name: name, Version: "1.21.2"}
		got := c.Classify(dep, common.VersionInfo{Version: "1.21.2"})
		if got.Tier != common.TierT1 {
			t.Errorf("tool-binary/%s resting tier = %s, want T1", name, got.Tier)
		}
	}
}

// TestOptionsDefaultsStrictAndNativeToolsOn proves --strict and --native-tools
// both default on, so the production path enforces and resolves by default.
func TestOptionsDefaultsStrictAndNativeToolsOn(t *testing.T) {
	opts := newOptions()
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	bindFlags(fs, &opts)
	if err := fs.Parse(nil); err != nil {
		t.Fatalf("parse defaults: %v", err)
	}
	if !opts.Strict {
		t.Error("--strict default = false, want true (strict is the default path)")
	}
	if !opts.NativeTools {
		t.Error("--native-tools default = false, want true")
	}
}

// TestNativeToolsFlagDisablesHermeticBatchResolvers proves --native-tools=false
// (and --strict=false) override the defaults, so CI can request a hermetic run.
func TestNativeToolsFlagDisablesHermeticBatchResolvers(t *testing.T) {
	opts := newOptions()
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	bindFlags(fs, &opts)
	if err := fs.Parse([]string{"--native-tools=false", "--strict=false"}); err != nil {
		t.Fatalf("parse overrides: %v", err)
	}
	if opts.NativeTools {
		t.Error("--native-tools=false did not disable the native batch resolvers")
	}
	if opts.Strict {
		t.Error("--strict=false did not disable strict")
	}
}

// TestStrictFailureSatisfiedByIgnoredUnknown proves an extraction unknown whose
// id (category/name) and file match a live ignore rule satisfies --strict.
func TestStrictFailureSatisfiedByIgnoredUnknown(t *testing.T) {
	dep := common.Dependency{
		Category: common.CategoryNPM, Name: "rollup", Version: "4.0.0",
		File: "tools/streamdeck-plugin/package.json",
	}
	ignores := parsedIgnoreSet{{ID: "npm/rollup", File: "tools/streamdeck-plugin/package.json", untilStr: "2030-01-01"}}

	if err := strictFailure(&Options{Strict: true}, []common.Resolved{resolvedUnknown(dep)}, nil, ignores, enforceNow()); err != nil {
		t.Errorf("strict failed on an ignored unknown: %v", err)
	}
}

// TestStrictFailureFailsWithoutIgnore proves the same unknown still fails
// strict when no ignore rule covers it.
func TestStrictFailureFailsWithoutIgnore(t *testing.T) {
	dep := common.Dependency{
		Category: common.CategoryNPM, Name: "rollup", Version: "4.0.0",
		File: "tools/streamdeck-plugin/package.json",
	}
	if err := strictFailure(&Options{Strict: true}, []common.Resolved{resolvedUnknown(dep)}, nil, parsedIgnoreSet{}, enforceNow()); err == nil {
		t.Fatal("strict succeeded on an unignored unknown, want a failure")
	}
}

// TestStrictFailureIgnoreUntilFailsClosed proves a malformed or expired until
// never satisfies strict: the unknown still fails the run.
func TestStrictFailureIgnoreUntilFailsClosed(t *testing.T) {
	dep := common.Dependency{
		Category: common.CategoryNPM, Name: "rollup", Version: "4.0.0",
		File: "tools/streamdeck-plugin/package.json",
	}
	cases := map[string]ignoredRule{
		"malformed until": {ID: "npm/rollup", malformedUntil: true},
		"expired until":   {ID: "npm/rollup", untilStr: "2020-01-01"},
	}
	for name, rule := range cases {
		t.Run(name, func(t *testing.T) {
			err := strictFailure(&Options{Strict: true}, []common.Resolved{resolvedUnknown(dep)}, nil, parsedIgnoreSet{rule}, enforceNow())
			if err == nil {
				t.Fatalf("strict satisfied by a %s ignore rule, want fail-closed", name)
			}
		})
	}
}

// TestStrictFailureExemptsIntegrityAndInventory proves integrity and inventory
// pins never count toward strict, so an ignore rule is never needed for them.
func TestStrictFailureExemptsIntegrityAndInventory(t *testing.T) {
	all := []common.Resolved{
		{Dep: common.Dependency{Category: common.CategoryGo, Name: "x/text", Version: "v0.3.0", File: "core/controller/go.sum", Note: inventoryNote}, Status: common.StatusUnknown, Tier: common.TierT3},
		{Dep: common.Dependency{Category: common.CategoryScriptPin, Name: "ffmpeg", Version: "abcd", File: "tools/ffmpeg-dist/build.sh", Role: common.RoleIntegrity}, Status: common.StatusUnknown, Tier: common.TierT1},
	}
	if err := strictFailure(&Options{Strict: true}, all, nil, parsedIgnoreSet{}, enforceNow()); err != nil {
		t.Errorf("strict failed on exempt integrity/inventory unknowns: %v", err)
	}
}

// TestStrictFailureExtractionUnknownSatisfiedByFileRule proves a Phase-1
// extraction unknown (which carries only a file, no id) is satisfied by a
// file-scoped ignore rule.
func TestStrictFailureExtractionUnknownSatisfiedByFileRule(t *testing.T) {
	unknowns := []common.ExtractionUnknown{{File: "tools/x/build.sh", Reason: "cannot read file"}}
	ignores := parsedIgnoreSet{{ID: "script-pin/anything", File: "tools/x/build.sh"}}
	if err := strictFailure(&Options{Strict: true}, nil, unknowns, ignores, enforceNow()); err != nil {
		t.Errorf("strict failed on an ignored extraction unknown: %v", err)
	}
}

// TestStrictFailureNoopWhenNotStrict proves a non-strict run never fails, even
// with unknowns and no ignore rules.
func TestStrictFailureNoopWhenNotStrict(t *testing.T) {
	unknowns := []common.ExtractionUnknown{{File: "tools/x/build.sh", Reason: "cannot read file"}}
	if err := strictFailure(&Options{Strict: false}, nil, unknowns, parsedIgnoreSet{}, enforceNow()); err != nil {
		t.Errorf("non-strict run failed: %v", err)
	}
}

// TestBuildReportMarksIgnoredUnknowns proves the unknowns array carries the
// ignored flag: a resolved unknown and a phase-1 extraction unknown covered by a
// live ignore rule are marked ignored, while an uncovered extraction unknown is
// not. This is the report-side half of "ignore applies to findings and
// unknowns".
func TestBuildReportMarksIgnoredUnknowns(t *testing.T) {
	dep := common.Dependency{
		Category: common.CategoryNPM, Name: "rollup", Version: "4.0.0",
		File: "tools/streamdeck-plugin/package.json",
	}
	all := []common.Resolved{resolvedUnknown(dep)}
	unknowns := []common.ExtractionUnknown{
		{File: "tools/x/build.sh", Reason: "cannot read file"},
		{File: "tools/y/build.sh", Reason: "cannot read file"},
	}
	ignores := parsedIgnoreSet{
		{ID: "npm/rollup", File: "tools/streamdeck-plugin/package.json"},
		{ID: "script-pin/anything", File: "tools/x/build.sh"},
	}

	rep := buildReport(all, unknowns, ignores, enforceNow(), false)

	byName := map[string]unknownEntry{}
	byFile := map[string]unknownEntry{}
	for _, u := range rep.Unknowns {
		if u.Name != "" {
			byName[u.Name] = u
		}
		byFile[u.File] = u
	}
	if got := byName["rollup"]; !got.Ignored {
		t.Errorf("resolved unknown not marked ignored: %+v", got)
	}
	if got := byFile["tools/x/build.sh"]; !got.Ignored {
		t.Errorf("ignored phase-1 unknown not marked ignored: %+v", got)
	}
	if got := byFile["tools/y/build.sh"]; got.Ignored {
		t.Errorf("uncovered phase-1 unknown wrongly marked ignored: %+v", got)
	}
}

// TestStrictFailureEmptyReasonIgnoreDoesNotSatisfy proves an ignore rule with an
// empty reason is not a reviewed exception: it never satisfies strict, so a
// hand-edited rule that forgot its justification cannot silently pin a dep.
func TestStrictFailureEmptyReasonIgnoreDoesNotSatisfy(t *testing.T) {
	dep := common.Dependency{
		Category: common.CategoryNPM, Name: "rollup", Version: "4.0.0",
		File: "tools/streamdeck-plugin/package.json",
	}
	rule := ignoredRule{
		ID: "npm/rollup", File: "tools/streamdeck-plugin/package.json",
		emptyReason: true,
	}
	if err := strictFailure(&Options{Strict: true}, []common.Resolved{resolvedUnknown(dep)}, nil, parsedIgnoreSet{rule}, enforceNow()); err == nil {
		t.Fatal("strict satisfied by an empty-reason ignore rule, want fail-closed")
	}
}

// TestParseIgnoreEmptyReasonFailsClosed proves the parse boundary marks an
// empty (or whitespace-only) reason as invalid, so matching fails closed rather
// than honoring an unjustified rule.
func TestParseIgnoreEmptyReasonFailsClosed(t *testing.T) {
	rules := ignoreSet{
		{ID: "npm/blank", Reason: ""},
		{ID: "npm/space", Reason: "   "},
		{ID: "npm/ok", Reason: "reviewed"},
	}.parsed()

	if rules.isIgnored("npm/blank", enforceNow()) {
		t.Error("empty-reason rule must not match")
	}
	if rules.isIgnored("npm/space", enforceNow()) {
		t.Error("whitespace-only-reason rule must not match")
	}
	if !rules.isIgnored("npm/ok", enforceNow()) {
		t.Error("reasoned rule must still match")
	}
	if rules.coversFile("npm/blank", calendarDate(enforceNow())) {
		t.Error("empty-reason rule must not cover a file either")
	}
}

// TestNativeBatchResolversSelectsOfflineReporter proves the composition choice:
// --native-tools=false registers no batch resolver, --offline registers the
// hermetic skip reporter, and the online default registers the real native
// resolver.
func TestNativeBatchResolversSelectsOfflineReporter(t *testing.T) {
	if got := nativeBatchResolvers(&Options{NativeTools: false}); len(got) != 0 {
		t.Errorf("native-tools=false registered %d batch resolver(s), want 0", len(got))
	}
	if got := nativeBatchResolvers(&Options{Offline: true, NativeTools: true}); len(got) == 0 {
		t.Error("offline registered no skip reporter, want one")
	}
	if got := nativeBatchResolvers(&Options{NativeTools: true}); len(got) == 0 {
		t.Error("online native-tools registered no native resolver, want one")
	}
}

// TestOfflineNativeBatchReportsSkipped proves the offline native batch never
// shells out yet still surfaces the native pins: it reads the go.mod require
// directives from disk and reports each as skipped.
func TestOfflineNativeBatchReportsSkipped(t *testing.T) {
	root := t.TempDir()
	goMod := "module example.com/x\n\ngo 1.26\n\nrequire example.com/foo v1.2.3\n"
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte(goMod), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	got := offlineNativeBatch(root, time.Second, newClassifier())
	if len(got) == 0 {
		t.Fatal("offline native batch reported nothing for a go.mod require")
	}
	for _, r := range got {
		if r.Status != common.StatusSkipped {
			t.Errorf("status = %q, want skipped: %+v", r.Status, r)
		}
		if r.Dep.Category != common.CategoryGo || r.Dep.Name != "example.com/foo" {
			t.Errorf("unexpected offline record: %+v", r)
		}
	}
}
