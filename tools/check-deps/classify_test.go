package main

import (
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// Policy-behavior tests live in the main package with the concrete classifier
// configuration they exercise (see classify.go). They build a classifier from
// the real default policies and base-tier rules via testClassifier().

func assertClassify(t *testing.T, c *common.Classifier, dep common.Dependency, latest string, wantStatus common.Status, wantTier common.Tier) {
	t.Helper()
	r := c.Classify(dep, common.VersionInfo{Version: latest})
	if r.Status != wantStatus || r.Tier != wantTier {
		t.Errorf("classify(%s/%s %s -> %s) = %s/%s, want %s/%s", dep.Category, dep.Name, dep.Version, latest, r.Status, r.Tier, wantStatus, wantTier)
	}
}

func TestClassifyBazelModuleTiering(t *testing.T) {
	c := testClassifier()
	cases := []struct {
		name       string
		dep        common.Dependency
		latest     string
		wantStatus common.Status
		wantTier   common.Tier
	}{
		{name: "0.x minor bump is breaking", dep: common.Dependency{Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.63.0"}, latest: "0.64.0", wantStatus: common.StatusUpdate, wantTier: common.TierT2},
		{name: "0.x patch bump is non-breaking", dep: common.Dependency{Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.63.0"}, latest: "0.63.1", wantStatus: common.StatusUpdate, wantTier: common.TierT3},
		{name: "current equals latest is ok", dep: common.Dependency{Category: common.CategoryBazelModule, Name: "rules_go", Version: "0.63.0"}, latest: "0.63.0", wantStatus: common.StatusOK, wantTier: common.TierT2},
		{name: "1.x major bump is breaking", dep: common.Dependency{Category: common.CategoryBazelModule, Name: "gazelle", Version: "1.2.0"}, latest: "2.0.0", wantStatus: common.StatusUpdate, wantTier: common.TierT2},
		{name: "1.x minor bump is non-breaking", dep: common.Dependency{Category: common.CategoryBazelModule, Name: "gazelle", Version: "1.2.0"}, latest: "1.3.0", wantStatus: common.StatusUpdate, wantTier: common.TierT3},
		{name: "0 to 1 transition is a major bump", dep: common.Dependency{Category: common.CategoryBazelModule, Name: "rules_oci", Version: "0.9.0"}, latest: "1.0.0", wantStatus: common.StatusUpdate, wantTier: common.TierT2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assertClassify(t, c, tc.dep, tc.latest, tc.wantStatus, tc.wantTier)
		})
	}
}

func TestClassifyFloatingBaseImageHygiene(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryBaseImage, Name: "amazonlinux", Version: "2023", File: "tools/openssh/publish.sh"}
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
		dep := common.Dependency{Category: common.CategoryBaseImage, Name: "example", Version: v}
		r := c.Classify(dep, common.VersionInfo{Version: "2026"})
		if r.Status != common.StatusHygiene || r.Tier != common.TierT2 {
			t.Errorf("floating tag %q: got %s/%s, want hygiene/T2", v, r.Status, r.Tier)
		}
	}
}

func TestClassifyDigestPinnedOK(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryBaseImage, Name: "alpine", DigestPinned: true}
	r := c.Classify(dep, common.VersionInfo{})
	if r.Status != common.StatusOK || r.Tier != common.TierT1 {
		t.Errorf("digest-pinned alpine: got %s/%s, want ok/T1", r.Status, r.Tier)
	}
}

func TestClassifyDebianDateTag(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryBaseImage, Name: "debian", Version: "20260824T082821Z"}
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
	dep := common.Dependency{Category: common.CategoryCIAction, Name: "actions/checkout", Version: sha}
	r := c.Classify(dep, common.VersionInfo{Version: "v4.2.0"})
	if r.Status != common.StatusOK {
		t.Errorf("full-SHA action pin: got %s, want ok", r.Status)
	}
}

func TestClassifyActionV0Major(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryCIAction, Name: "example/action", Version: "v0"}
	r := c.Classify(dep, common.VersionInfo{Version: "v0"})
	if r.Status != common.StatusOK {
		t.Errorf("v0 current + v0 latest: got %s, want ok (genuine major 0, not unknown)", r.Status)
	}

	dep = common.Dependency{Category: common.CategoryCIAction, Name: "example/action", Version: "not-a-ref"}
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
	dep := common.Dependency{Category: common.CategoryCIAction, Name: "actions/checkout", Version: "v4"}
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
	dep := common.Dependency{Category: common.CategoryBaseImage, Name: "ubuntu", Version: "1.0.0"}
	r := c.Classify(dep, common.VersionInfo{Version: "2.0.0"})
	if r.Status != common.StatusUpdate || r.Tier != common.TierT1 {
		t.Errorf("T1 breaking bump: got %s/%s, want update/T1", r.Status, r.Tier)
	}
}

func TestClassifyUpdateEscalatesSecurityToT1(t *testing.T) {
	c := testClassifier()
	dep := common.Dependency{Category: common.CategoryScriptPin, Name: "openssh-portable", Version: "10.3p1"}
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

func TestFirstTwoNumericStates(t *testing.T) {
	// Each case pins the exact numericCore a version string must parse to;
	// numericCore is comparable, so direct equality is the whole assertion.
	cases := []struct {
		in   string
		want numericCore
	}{
		{"0.63.0", numericCore{major: 0, minor: 63, ok: true, minorSet: true, minorValid: true}},
		{"1.2.0", numericCore{major: 1, minor: 2, ok: true, minorSet: true, minorValid: true}},
		{"v4", numericCore{major: 4, ok: true}}, // single-component version: no minor present
		{"0", numericCore{major: 0, ok: true}},
		{"0.broken", numericCore{major: 0, ok: true, minorSet: true}},               // present minor unparseable
		{"0.99999999999999999999", numericCore{major: 0, ok: true, minorSet: true}}, // present minor overflows int
		{"abc", numericCore{}},
		{"", numericCore{}},
	}
	for _, c := range cases {
		if got := firstTwoNumeric(c.in); got != c.want {
			t.Errorf("firstTwoNumeric(%q) = %+v, want %+v", c.in, got, c.want)
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
