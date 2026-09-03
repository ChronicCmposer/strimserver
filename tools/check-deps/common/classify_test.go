package common

import (
	"testing"
)

// Phase 2 unit tests moved into the common package: pure logic only (tier
// classification). No network is touched; the classifier is exercised against
// inline fixture strings.

// --- tier classification ---------------------------------------------------

func TestClassifyUnknownOnNetworkFailure(t *testing.T) {
	c := NewClassifier(nil, nil)
	dep := Dependency{Category: "bazel-module", Name: "rules_go", Version: "0.63.0"}
	r := c.Classify(dep, VersionInfo{Err: errTestNetwork})
	if r.Status != StatusUnknown {
		t.Errorf("resolver failure: got %s, want unknown", r.Status)
	}
	if len(r.Reasons) == 0 {
		t.Error("unknown resolution must carry a reason")
	}
}

// errTestNetwork is a sentinel used only in unit tests.
var errTestNetwork = errorString("test network failure")

type errorString string

func (e errorString) Error() string { return string(e) }
