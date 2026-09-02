package main

import (
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// Policy-behavior tests moved to the main package with the concrete classifier
// configuration they exercise (see classify.go). They build a classifier from
// the real default policies and base-tier rules via testClassifier().

func TestClassifyBazelModuleZeroXMinorAsMajor(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	// 0.x minor bump is breaking -> T2 review.
	r := c.Classify(dep, common.VersionInfo{Version: "0.64.0"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT2 {
		t.Errorf("0.x minor bump: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// 0.x patch bump is non-breaking -> T3.
	r = c.Classify(dep, common.VersionInfo{Version: "0.63.1"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT3 {
		t.Errorf("0.x patch bump: got %s/%s, want update/T3", r.Status, r.Tier)
	}
	// current at latest -> ok.
	r = c.Classify(dep, common.VersionInfo{Version: "0.63.0"})
	if r.Status != common.StatusOK {
		t.Errorf("current == latest: got %s, want ok", r.Status)
	}
}

func TestClassifyBazelModuleOneXMajor(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "bazel-module", Name: "gazelle", Version: "1.2.0"}
	// 1.x major bump -> T2 review.
	r := c.Classify(dep, common.VersionInfo{Version: "2.0.0"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT2 {
		t.Errorf("1.x major bump: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// 1.x minor/patch bump -> T3.
	r = c.Classify(dep, common.VersionInfo{Version: "1.3.0"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT3 {
		t.Errorf("1.x minor bump: got %s/%s, want update/T3", r.Status, r.Tier)
	}
	// 0 -> 1 transition is a major bump -> T2.
	dep = common.Dependency{Category: "bazel-module", Name: "rules_oci", Version: "0.9.0"}
	r = c.Classify(dep, common.VersionInfo{Version: "1.0.0"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT2 {
		t.Errorf("0 -> 1 transition: got %s/%s, want update/T2", r.Status, r.Tier)
	}
}

func TestClassifyFloatingBaseImageHygiene(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "base-image", Name: "amazonlinux", Version: "2023", File: "tools/openssh/publish.sh"}
	r := c.Classify(dep, common.VersionInfo{Version: "2023"})
	if r.Status != common.StatusHygiene || r.Tier != common.TierT2 {
		t.Errorf("floating base image: got %s/%s, want hygiene/T2", r.Status, r.Tier)
	}
	if len(r.Reasons) == 0 {
		t.Error("floating base image should carry a digest/date pinning reason")
	}
}

func TestClassifyFloatingLiteralBaseImageHygiene(t *testing.T) {
	c := testClassifier()
	for _, v := range []string{"latest", "stable"} {
		dep := common.Dependency{Category: "base-image", Name: "example", Version: v}
		r := c.Classify(dep, common.VersionInfo{Version: "2026"})
		if r.Status != common.StatusHygiene || r.Tier != common.TierT2 {
			t.Errorf("floating tag %q: got %s/%s, want hygiene/T2", v, r.Status, r.Tier)
		}
	}
}

func TestClassifyDigestPinnedOK(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "base-image", Name: "alpine", DigestPinned: true}
	r := c.Classify(dep, common.VersionInfo{})
	if r.Status != common.StatusOK || r.Tier != common.TierT1 {
		t.Errorf("digest-pinned alpine: got %s/%s, want ok/T1", r.Status, r.Tier)
	}
}

func TestClassifyDebianDateTag(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "base-image", Name: "debian", Version: "20260824T082821Z"}
	// Newer date-tag -> update, T1 (security base image).
	r := c.Classify(dep, common.VersionInfo{Version: "20260901"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT1 {
		t.Errorf("newer debian date tag: got %s/%s, want update/T1", r.Status, r.Tier)
	}
	// Current date-tag -> ok.
	r = c.Classify(dep, common.VersionInfo{Version: "20260824"})
	if r.Status != common.StatusOK {
		t.Errorf("current debian date tag: got %s, want ok", r.Status)
	}
}

func TestClassifyFullSHAPinnedAction(t *testing.T) {
	c := testClassifier()
	sha := "0123456789abcdef0123456789abcdef01234567"
	dep := common.Dependency{Category: "ci-action", Name: "actions/checkout", Version: sha}
	r := c.Classify(dep, common.VersionInfo{Version: "v4.2.0"})
	if r.Status != common.StatusOK {
		t.Errorf("full-SHA action pin: got %s, want ok", r.Status)
	}
}

func TestClassifyActionV0Major(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "ci-action", Name: "example/action", Version: "v0"}
	r := c.Classify(dep, common.VersionInfo{Version: "v0"})
	if r.Status != common.StatusOK {
		t.Errorf("v0 current + v0 latest: got %s, want ok (genuine major 0, not unknown)", r.Status)
	}

	dep = common.Dependency{Category: "ci-action", Name: "example/action", Version: "not-a-ref"}
	r = c.Classify(dep, common.VersionInfo{Version: "v4"})
	if r.Status != common.StatusUnknown {
		t.Errorf("unparseable current: got %s, want unknown", r.Status)
	}
	if len(r.Reasons) == 0 || !strings.Contains(r.Reasons[0], "cannot parse action majors") {
		t.Errorf("unparseable current should carry the parse reason, got reasons=%v", r.Reasons)
	}
}

func TestClassifyGitHubActionExemption(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "ci-action", Name: "actions/checkout", Version: "v4"}
	// Newer major exists -> update, T2.
	r := c.Classify(dep, common.VersionInfo{Version: "v5.0.1"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT2 {
		t.Errorf("newer action major: got %s/%s, want update/T2", r.Status, r.Tier)
	}
	// Same major (newer patch within v4) -> ok, exempt from hygiene.
	r = c.Classify(dep, common.VersionInfo{Version: "v4.2.0"})
	if r.Status != common.StatusOK {
		t.Errorf("same action major: got %s, want ok", r.Status)
	}
	foundExemption := false
	for _, info := range r.Infos {
		if strings.Contains(info, "exempt from date-pinning hygiene") {
			foundExemption = true
		}
	}
	if !foundExemption {
		t.Errorf("same-major action should record the hygiene exemption, got infos=%v", r.Infos)
	}
}

func TestClassifyT1BreakingBumpStaysT1(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "base-image", Name: "ubuntu", Version: "1.0.0"}
	r := c.Classify(dep, common.VersionInfo{Version: "2.0.0"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT1 {
		t.Errorf("T1 breaking bump: got %s/%s, want update/T1", r.Status, r.Tier)
	}
}

func TestClassifyUpdateEscalatesSecurityToT1(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: "script-pin", Name: "openssh-portable", Version: "10.3p1"}
	r := c.Classify(dep, common.VersionInfo{Version: "10.4p1"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT1 {
		t.Errorf("security dep update: got %s/%s, want update/T1", r.Status, r.Tier)
	}
}

func TestClassifyDebianDateTagUnparseable(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryBaseImage, Name: "debian", Version: "trixie-slim"}
	r := c.Classify(dep, common.VersionInfo{Version: "20260901"})
	if r.Status != common.StatusUnknown {
		t.Errorf("unparseable current date tag: got status %s, want unknown", r.Status)
	}
}

func TestClassifySemverPinnedAheadOfLatest(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryScriptPin, Name: "some-tool", Version: "2.0.0"}
	r := c.Classify(dep, common.VersionInfo{Version: "1.0.0"})
	if r.Status != common.StatusOK {
		t.Errorf("pinned ahead of latest: got status %s, want ok", r.Status)
	}
}

func TestClassifyNonBaseImageDebianIsNotDateTagged(t *testing.T) {
	c := testClassifier()
	// A script-pin named "debian" is not a date-tagged base image; it must
	// classify as a semver update, not the date-tag policy (which would be
	// StatusUnknown because no YYYYMMDD date is present).
	dep := common.Dependency{Category: common.CategoryScriptPin, Name: "debian", Version: "1.0.0"}
	r := c.Classify(dep, common.VersionInfo{Version: "2.0.0"})
	if r.Status != common.StatusUpdate {
		t.Errorf("non-base-image debian: got status %s, want update", r.Status)
	}
}

// --- version-bump helpers --------------------------------------------------

func TestFirstTwoNumericStates(t *testing.T) {
	cases := []struct {
		in           string
		major, minor int
		ok           bool
		minorSet     bool
		minorValid   bool
	}{
		{"0.63.0", 0, 63, true, true, true},
		{"1.2.0", 1, 2, true, true, true},
		{"v4", 4, 0, true, false, true}, // single-component version: no minor, treated as 0
		{"0", 0, 0, true, false, true},
		{"0.broken", 0, 0, true, true, false},               // present minor unparseable
		{"0.99999999999999999999", 0, 0, true, true, false}, // present minor overflows int
		{"abc", 0, 0, false, false, false},
		{"", 0, 0, false, false, false},
	}
	for _, c := range cases {
		major, minor, ok, minorSet, minorValid := firstTwoNumeric(c.in)
		if major != c.major || minor != c.minor || ok != c.ok || minorSet != c.minorSet || minorValid != c.minorValid {
			t.Errorf("firstTwoNumeric(%q) = (%d, %d, %v, %v, %v), want (%d, %d, %v, %v, %v)",
				c.in, major, minor, ok, minorSet, minorValid, c.major, c.minor, c.ok, c.minorSet, c.minorValid)
		}
	}
}

func TestIsBreakingBump(t *testing.T) {
	// On the 0.x axis the minor is the breaking axis.
	if !isBreakingBump("0.63.0", "0.64.0") {
		t.Error("0.x minor bump should be breaking")
	}
	if isBreakingBump("0.63.0", "0.63.1") {
		t.Error("0.x patch bump should not be breaking")
	}
	// A single-component 0.x version has no minor and compares with minor 0.
	if !isBreakingBump("0", "0.1.0") {
		t.Error("0 -> 0.1.0 should be a breaking minor bump")
	}
	// A minor that is present but unparseable/overflowing must be treated as
	// non-breaking, never silently escalating a review.
	if isBreakingBump("0.broken", "0.1.0") {
		t.Error("broken current minor must not be breaking")
	}
	if isBreakingBump("0.1.0", "0.broken") {
		t.Error("broken latest minor must not be breaking")
	}
	// On the 1.x axis only a major bump breaks; the 0 -> 1 transition too.
	if !isBreakingBump("1.2.0", "2.0.0") {
		t.Error("1.x major bump should be breaking")
	}
	if isBreakingBump("1.2.0", "1.3.0") {
		t.Error("1.x minor bump should not be breaking")
	}
	if !isBreakingBump("0.9.0", "1.0.0") {
		t.Error("0 -> 1 transition should be breaking")
	}
}
