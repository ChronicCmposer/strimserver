package extractorimpl

import (
	"testing"

	"strimserver-check-deps/common"
)

// TestExtractBazelrcEmitsIntegrityToolchainDeps proves the .bazelrc extractor
// surfaces the registered platform/toolchain lines as toolchain-category
// integrity pins: they carry no version, so they must land in the integrity
// section and never trip --strict.
func TestExtractBazelrcEmitsIntegrityToolchainDeps(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, root+"/.bazelrc", `# a comment
build:amd64 --platforms=@zig_sdk//platform:linux_amd64
build:amd64 --extra_toolchains=@zig_sdk//toolchain:linux_amd64_musl
build:arm64 --platforms=@zig_sdk//platform:linux_arm64
build:arm64 --extra_toolchains=@zig_sdk//toolchain:linux_arm64_musl
register_toolchains("@rules_go//go:toolchain")
`)

	deps, unknowns := ExtractBazelrc(root)
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}

	wantNames := []string{
		"@zig_sdk//platform:linux_amd64",
		"@zig_sdk//toolchain:linux_amd64_musl",
		"@zig_sdk//platform:linux_arm64",
		"@zig_sdk//toolchain:linux_arm64_musl",
		"@rules_go//go:toolchain",
	}
	got := make(map[string]common.Dependency, len(deps))
	for _, dep := range deps {
		got[dep.Name] = dep
		if dep.Category != common.CategoryToolchain {
			t.Errorf("Category = %q, want %q", dep.Category, common.CategoryToolchain)
		}
		if dep.Role != common.RoleIntegrity {
			t.Errorf("%s Role = %q, want %q", dep.Name, dep.Role, common.RoleIntegrity)
		}
		if dep.Version != "" {
			t.Errorf("%s Version = %q, want empty (integrity pin)", dep.Name, dep.Version)
		}
		if dep.File != ".bazelrc" {
			t.Errorf("%s File = %q, want .bazelrc", dep.Name, dep.File)
		}
	}
	for _, name := range wantNames {
		if _, ok := got[name]; !ok {
			t.Errorf("missing toolchain/platform pin %q; got %v", name, deps)
		}
	}
}

// TestExtractBazelrcMissingFile proves a repo without a .bazelrc yields nothing
// rather than an unknown: the file is optional.
func TestExtractBazelrcMissingFile(t *testing.T) {
	deps, unknowns := ExtractBazelrc(t.TempDir())
	if len(deps) != 0 {
		t.Fatalf("deps = %v, want none", deps)
	}
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none for a missing optional .bazelrc", unknowns)
	}
}

// TestExtractBazelrcIgnoresUnrelatedFlags proves only the toolchain/platform
// directives are surfaced; ordinary build flags are not pins.
func TestExtractBazelrcIgnoresUnrelatedFlags(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, root+"/.bazelrc", `common --noenable_workspace
build --disk_cache=~/.cache/bazel
test --test_output=errors
build:amd64 --copt=-Os
`)

	deps, unknowns := ExtractBazelrc(root)
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	if len(deps) != 0 {
		t.Fatalf("deps = %v, want none for non-toolchain flags", deps)
	}
}
