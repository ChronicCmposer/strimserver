package extractorimpl

import (
	"path/filepath"
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// appManifestFixture mirrors the real Stream Deck manifest.json.tpl: SDKVersion
// is a JSON number, the other version fields are strings.
const appManifestFixture = `{
  "$schema": "https://schemas.elgato.com/streamdeck/plugins/manifest.json",
  "UUID": "com.chroniccmposer.strimserver",
  "Name": "Strimserver",
  "Version": "__VERSION__",
  "SDKVersion": 2,
  "Software": { "MinimumVersion": "6.6" },
  "Nodejs": { "Version": "24", "Debug": "enabled" },
  "OS": [{ "Platform": "mac", "MinimumVersion": "13" }],
  "Actions": []
}
`

func TestParseAppManifest(t *testing.T) {
	deps, unknowns := parseAppManifest([]byte(appManifestFixture), appManifestPath)
	if len(unknowns) != 0 {
		t.Fatalf("parseAppManifest unknowns = %v, want none", unknowns)
	}
	cases := []struct {
		name    string
		version string
	}{
		{"Stream Deck SDK", "2"},
		{"Stream Deck software", "6.6"},
		{"Stream Deck Node.js", "24"},
		{"Stream Deck macOS", "13"},
	}
	for _, tc := range cases {
		got := findDepVersion(t, deps, common.CategoryToolchain, tc.name, tc.version)
		if got == nil {
			t.Errorf("manifest field %q=%q not extracted: %v", tc.name, tc.version, deps)
			continue
		}
		if got.File != appManifestPath {
			t.Errorf("%s File = %q, want %q", tc.name, got.File, appManifestPath)
		}
		if got.Note == "" {
			t.Errorf("%s Note is empty, want a non-semver annotation", tc.name)
		}
	}
}

// TestParseAppManifestStringSDKVersion proves the SDKVersion field tolerates a
// JSON string as well as a number: the field normalizes to its literal text.
func TestParseAppManifestStringSDKVersion(t *testing.T) {
	const manifest = `{"SDKVersion": "3", "Software": {"MinimumVersion": "6.9"}}`
	deps, unknowns := parseAppManifest([]byte(manifest), appManifestPath)
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, common.CategoryToolchain, "Stream Deck SDK", "3"); got == nil {
		t.Errorf("string SDKVersion not extracted: %v", deps)
	}
}

func TestParseAppManifestInvalidJSON(t *testing.T) {
	_, unknowns := parseAppManifest([]byte("{ not json"), appManifestPath)
	if len(unknowns) != 1 || !strings.Contains(unknowns[0].Reason, "invalid JSON") {
		t.Fatalf("unknowns = %v, want exactly one invalid-JSON unknown", unknowns)
	}
}

func TestExtractAppManifest(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, filepath.FromSlash(appManifestPath)), appManifestFixture)

	deps, unknowns := ExtractAppManifest(root)
	if len(unknowns) != 0 {
		t.Fatalf("ExtractAppManifest unknowns = %v, want none", unknowns)
	}
	if len(deps) != 4 {
		t.Fatalf("ExtractAppManifest deps = %v, want exactly 4", deps)
	}
}

// ExtractAppManifest must keep satisfying the common.Extractor contract.
var _ common.Extractor = ExtractAppManifest
