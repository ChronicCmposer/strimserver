package extractorimpl

import (
	"path/filepath"
	"testing"

	"strimserver-check-deps/common"
)

// TestParseManagedPackageJSONEmitsNPMDeps proves the discovered package.json
// yields one npm-category finding per declared package (version = declared
// range) plus engines.node, while keeping the existing pnpm toolchain pin.
func TestParseManagedPackageJSONEmitsNPMDeps(t *testing.T) {
	const manifest = `{
  "packageManager": "pnpm@9.15.9",
  "engines": { "node": ">=24" },
  "dependencies": { "@elgato/streamdeck": "^2" },
  "devDependencies": { "rollup": "4.64.5", "typescript": "6.0.3" }
}`
	deps, unknowns := parseManagedPackageJSON([]byte(manifest), "tools/streamdeck-plugin/package.json")
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, common.CategoryNPM, "@elgato/streamdeck", "^2"); got == nil {
		t.Errorf("dependency range not extracted: %v", deps)
	}
	if got := findDepVersion(t, deps, common.CategoryNPM, "rollup", "4.64.5"); got == nil {
		t.Errorf("devDependency not extracted: %v", deps)
	}
	if got := findDepVersion(t, deps, common.CategoryNPM, "typescript", "6.0.3"); got == nil {
		t.Errorf("devDependency not extracted: %v", deps)
	}
	if got := findDepVersion(t, deps, common.CategoryNPM, "node", ">=24"); got == nil {
		t.Errorf("engines.node not extracted: %v", deps)
	}
	if got := findDepVersion(t, deps, common.CategoryToolchain, "pnpm", "9.15.9"); got == nil {
		t.Errorf("pnpm pin no longer extracted: %v", deps)
	}
}

// TestParseManagedPackageJSONNPMDepsWithoutPackageManager proves a manifest
// without a packageManager still yields its npm deps (it is a real dependency
// tree), while yielding no pnpm finding.
func TestParseManagedPackageJSONNPMDepsWithoutPackageManager(t *testing.T) {
	deps, unknowns := parseManagedPackageJSON([]byte(`{"dependencies":{"left-pad":"1.3.0"}}`), "web/package.json")
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if got := findDepVersion(t, deps, common.CategoryNPM, "left-pad", "1.3.0"); got == nil {
		t.Errorf("npm dep without packageManager not extracted: %v", deps)
	}
	if findDep(t, deps, common.CategoryToolchain, "pnpm") != nil {
		t.Errorf("no pnpm finding expected without packageManager: %v", deps)
	}
}

// TestExtractToolchainsEmitsNPMDeps proves the npm deps flow through the real
// discovery path and are tagged with the sub-repo package.json.
func TestExtractToolchainsEmitsNPMDeps(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, ".bazelversion"), "9.2.0\n")
	writeFixture(t, filepath.Join(root, "tools", "streamdeck-plugin", "package.json"),
		`{"packageManager":"pnpm@9.15.9","dependencies":{"@elgato/streamdeck":"^2"}}`)

	deps, unknowns := ExtractToolchains(root)
	if len(unknowns) != 0 {
		t.Fatalf("ExtractToolchains unknowns = %v, want none", unknowns)
	}
	got := findDepVersion(t, deps, common.CategoryNPM, "@elgato/streamdeck", "^2")
	if got == nil {
		t.Fatalf("npm dep not extracted via ExtractToolchains: %v", deps)
	}
	if got.File != "tools/streamdeck-plugin/package.json" {
		t.Errorf("npm dep File = %q, want the sub-repo package.json", got.File)
	}
}
