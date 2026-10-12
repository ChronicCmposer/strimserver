package extractorimpl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// TestExtractVendoredPinsValid covers the happy path: one well-formed pin.json
// yields exactly one tool-binary dependency whose Source prefers owner_repo and
// whose Note carries the sha256.
func TestExtractVendoredPinsValid(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, "third_party", "foo", "pin.json"), `{
  "name": "foo",
  "version": "1.2.3",
  "upstream": "https://example.com/foo-1.2.3.tar.gz",
  "sha256": "abc123",
  "owner_repo": "acme/foo"
}`)

	deps, unknowns := ExtractVendoredPins(root)
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("deps = %v, want exactly one", deps)
	}

	dep := deps[0]
	if dep.Category != common.CategoryToolBinary {
		t.Errorf("Category = %q, want %q", dep.Category, common.CategoryToolBinary)
	}
	if dep.Name != "foo" {
		t.Errorf("Name = %q, want %q", dep.Name, "foo")
	}
	if dep.Version != "1.2.3" {
		t.Errorf("Version = %q, want %q", dep.Version, "1.2.3")
	}
	if dep.Source != "acme/foo" {
		t.Errorf("Source = %q, want owner_repo %q", dep.Source, "acme/foo")
	}
	if dep.File != "third_party/foo/pin.json" {
		t.Errorf("File = %q, want %q", dep.File, "third_party/foo/pin.json")
	}
	if !strings.Contains(dep.Note, "abc123") {
		t.Errorf("Note = %q, want it to carry the sha256", dep.Note)
	}
}

// TestExtractVendoredPinsOwnerRepoNull covers the nullable fields: owner_repo
// null falls back to the upstream URL as Source, and a null sha256 is noted
// rather than silently dropped.
func TestExtractVendoredPinsOwnerRepoNull(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, "third_party", "bar", "pin.json"), `{
  "name": "bar",
  "version": "9.9",
  "upstream": "https://ftp.example.org/bar/bar-9.9.tar.gz",
  "sha256": null,
  "owner_repo": null
}`)

	deps, unknowns := ExtractVendoredPins(root)
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 1 {
		t.Fatalf("deps = %v, want exactly one", deps)
	}

	dep := deps[0]
	if dep.Source != "https://ftp.example.org/bar/bar-9.9.tar.gz" {
		t.Errorf("Source = %q, want the upstream URL", dep.Source)
	}
	if !strings.Contains(strings.ToLower(dep.Note), "sha256") {
		t.Errorf("Note = %q, want it to mention the absent sha256", dep.Note)
	}
}

// TestExtractVendoredPinsMalformed covers fail-closed parsing: unparseable
// JSON becomes an ExtractionUnknown, never a silent drop.
func TestExtractVendoredPinsMalformed(t *testing.T) {
	root := t.TempDir()
	const pinFile = "third_party/bad/pin.json"
	writeFixture(t, filepath.Join(root, pinFile), `{ this is not valid json`)

	deps, unknowns := ExtractVendoredPins(root)
	if len(deps) != 0 {
		t.Fatalf("deps = %v, want none for malformed pin", deps)
	}
	if len(unknowns) != 1 {
		t.Fatalf("unknowns = %v, want exactly one", unknowns)
	}
	if unknowns[0].File != pinFile {
		t.Errorf("unknown File = %q, want %q", unknowns[0].File, pinFile)
	}
	if unknowns[0].Reason == "" {
		t.Errorf("unknown Reason is empty, want a descriptive reason")
	}
}

// TestExtractVendoredPinsMissing covers coverage gaps: a vendored library
// directory without a pin.json is surfaced as an ExtractionUnknown. Plain files
// directly under third_party (README, BUILD.bazel) are not libraries and are
// ignored.
func TestExtractVendoredPinsMissing(t *testing.T) {
	root := t.TempDir()
	const libDir = "third_party/nopin"
	if err := os.MkdirAll(filepath.Join(root, libDir), 0o755); err != nil {
		t.Fatalf("creating lib dir: %v", err)
	}
	writeFixture(t, filepath.Join(root, "third_party", "README.md"), "not a library")

	deps, unknowns := ExtractVendoredPins(root)
	if len(deps) != 0 {
		t.Fatalf("deps = %v, want none when no pin.json exists", deps)
	}
	if len(unknowns) != 1 {
		t.Fatalf("unknowns = %v, want exactly one for the unpinned lib", unknowns)
	}
	if unknowns[0].File != "third_party/nopin/pin.json" {
		t.Errorf("unknown File = %q, want %q", unknowns[0].File, "third_party/nopin/pin.json")
	}
}

// TestExtractVendoredPinsMissingRequiredField covers parse-time validation: a
// pin.json that omits a required field is malformed, not a half-populated dep.
func TestExtractVendoredPinsMissingRequiredField(t *testing.T) {
	root := t.TempDir()
	const pinFile = "third_party/half/pin.json"
	writeFixture(t, filepath.Join(root, pinFile), `{
  "name": "half",
  "upstream": "https://example.com/half.tar.gz",
  "sha256": null,
  "owner_repo": null
}`)

	deps, unknowns := ExtractVendoredPins(root)
	if len(deps) != 0 {
		t.Fatalf("deps = %v, want none when version is absent", deps)
	}
	if len(unknowns) != 1 {
		t.Fatalf("unknowns = %v, want exactly one", unknowns)
	}
	if !strings.Contains(unknowns[0].Reason, "version") {
		t.Errorf("Reason = %q, want it to name the missing field", unknowns[0].Reason)
	}
}

// TestExtractVendoredPinsNoThirdPartyDir covers a repo with no vendored layer:
// the missing directory is one unknown, not a crash.
func TestExtractVendoredPinsNoThirdPartyDir(t *testing.T) {
	deps, unknowns := ExtractVendoredPins(t.TempDir())
	if len(deps) != 0 {
		t.Fatalf("deps = %v, want none", deps)
	}
	if len(unknowns) != 1 {
		t.Fatalf("unknowns = %v, want exactly one", unknowns)
	}
}

// TestExtractVendoredPinsMixed aggregates a valid, a malformed, and a missing
// library in one walk so the per-entry fail-closed behavior composes.
func TestExtractVendoredPinsMixed(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, "third_party", "good", "pin.json"), `{
  "name": "good", "version": "1", "upstream": "https://x/good.tar.gz",
  "sha256": "d", "owner_repo": "o/good"
}`)
	writeFixture(t, filepath.Join(root, "third_party", "bad", "pin.json"), `{`)
	if err := os.MkdirAll(filepath.Join(root, "third_party", "absent"), 0o755); err != nil {
		t.Fatalf("creating absent dir: %v", err)
	}

	deps, unknowns := ExtractVendoredPins(root)
	if len(deps) != 1 || deps[0].Name != "good" {
		t.Fatalf("deps = %v, want just the good pin", deps)
	}
	if len(unknowns) != 2 {
		t.Fatalf("unknowns = %v, want two (malformed + missing)", unknowns)
	}
}

// TestExtractVendoredPinsRealRepo is the integration guard: every vendored
// library directory that actually ships in this repo has a parseable pin.json.
// It locates the repo root by walking up from the test working directory and
// skips when third_party is absent (e.g. a hermetic test sandbox).
func TestExtractVendoredPinsRealRepo(t *testing.T) {
	root := findRepoRoot(t)

	deps, unknowns := ExtractVendoredPins(root)
	if len(unknowns) != 0 {
		t.Fatalf("real repo unknowns = %v, want none", unknowns)
	}

	want := map[string]string{
		"libmicrohttpd":  "1.0.10",
		"wslay":          "1.1.1",
		"yyjson":         "0.13.0",
		"libwebsockets":  "5.0.0",
		"protobuf-c":     "1.5.2",
		"curl":           "8.22.0",
		"mbedtls":        "3.6.7",
		"c-ares":         "1.34.8",
		"containerd-api": "1.12.0",
	}
	got := make(map[string]string, len(deps))
	for _, dep := range deps {
		got[dep.Name] = dep.Version
	}
	for name, version := range want {
		if got[name] != version {
			t.Errorf("pin %q version = %q, want %q", name, got[name], version)
		}
	}
	if len(deps) != len(want) {
		t.Errorf("got %d pins, want %d", len(deps), len(want))
	}
}

// findRepoRoot walks up from the test working directory to the directory that
// contains third_party, skipping the test when none is found.
func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if info, statErr := os.Stat(filepath.Join(dir, "third_party")); statErr == nil && info.IsDir() {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Skip("no third_party directory above test working directory; skipping repo integration test")
		}
		dir = parent
	}
}
