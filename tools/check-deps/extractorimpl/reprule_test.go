package extractorimpl

import (
	"strings"
	"testing"

	"strimserver-check-deps/common"
)

// repoRuleFixture mirrors the MODULE.bazel repo-rule shapes the spec table must
// handle: tarball_strip_symlinks (version from strip_prefix), deb_extract
// (Debian version from the .deb filename), amd64_sysroot (three url+sha pairs in
// one call), apt.install (a comment-laced package list), s3_http_archive /
// s3_http_file (self-published, sha-only), and the qemu_x86_64 use_repo_rule
// call (version from the bzl default).
const repoRuleFixture = `
tarball_strip_symlinks(
    name = "libwebsockets",
    build_file_content = """
filegroup(name = "x", srcs = glob(["**/*"]))
""",
    sha256 = "f853c6582101cfcee3a5a9e28ae92ab19d9735c5f31f0bb2e9794b5106123962",
    strip_prefix = "libwebsockets-5.0.0",
    url = "https://github.com/warmcat/libwebsockets/archive/refs/tags/v5.0.0.tar.gz",
)

deb_extract(
    name = "libprotobuf_dev_arm64",
    build_file_content = "cc_library(name = \"libprotobuf\")",
    sha256 = "26e311a867ef831d2378a33e772b1f21924261eedcefe08f7ce852c6176c2836",
    url = "https://snapshot.debian.org/archive/debian/20261005T000000Z/pool/main/p/protobuf/libprotobuf-dev_3.21.12-11+deb13u1_arm64.deb",
)

amd64_sysroot(
    name = "amd64_sysroot",
    libc6_sha256 = "54ef8425cbc7c45888981e6ef23529df4d056688a6c71a415fcc95a404522b9f",
    libc6_url = "https://snapshot.debian.org/archive/debian/20261005T000000Z/pool/main/c/cross-toolchain-base/libc6-dev-amd64-cross_2.41-11cross1_all.deb",
    libgcc_sha256 = "c6642e5d83ad232573c2a45efb5b407b06eb61af2220eb1c922d0380dd446286",
    libgcc_url = "https://snapshot.debian.org/archive/debian/20261005T000000Z/pool/main/g/gcc-14-cross/libgcc-14-dev-amd64-cross_14.2.0-19cross1_all.deb",
    linux_libc_sha256 = "da463ddd3ee96b37c33f16da99c47b03b4e514888d3d853e73253ee73bd0d7d8",
    linux_libc_url = "https://snapshot.debian.org/archive/debian/20261005T000000Z/pool/main/c/cross-toolchain-base/linux-libc-dev-amd64-cross_6.12.38-1cross1_all.deb",
)

apt.install(
    dependency_set = "trixie",
    packages = [
        # Runtime shell for the controller image.
        "dash",
        "busybox-static",
        "gettext-base",
        "ca-certificates",
        "libfdk-aac2t64",
        "libc6",
        "coreutils",
        "libbinutils",
        "libsframe1",
        "zlib1g",
        "libzstd1",
        "libgcc-s1",
        "binutils-x86-64-linux-gnu",
    ],
    suites = ["trixie"],
)

s3_http_archive(
    name = "ffmpeg_dist",
    build_file_content = 'exports_files(["ffmpeg"])',
    mirror_urls = ["https://github.com/ChronicCmposer/strimserver/releases/download/ffmpeg-artifacts/ffmpeg-8.1-deb20260824-cuda13.2.2-sm75-1a748fe.tar.gz"],
    s3_key = "ffmpeg/ffmpeg-8.1-deb20260824-cuda13.2.2-sm75-1a748fe.tar.gz",
    sha256 = "44021ca11d9c5a3f1921b57150dfe68562cb291658afbef40b231a3554a82120",
)

s3_http_file(
    name = "openssh_dist",
    build_file_content = 'exports_files(["openssh-experimental.rpm"])',
    downloaded_file_name = "openssh-experimental.rpm",
    mirror_urls = ["https://github.com/ChronicCmposer/strimserver/releases/download/openssh-dist/openssh-experimental.rpm"],
    s3_key = "openssh/openssh-experimental.rpm",
    sha256 = "05a2869d27c59c22aaccbad738a91b08f397a82a066c2d6ade4ed68ac00cc8fd",
)

qemu_x86_64(name = "qemu_x86_64_patched")
`

// repoRuleFixtureDefaults supplies the out-of-band qemu bzl default the fixture
// call needs (the version lives in tools/bazel/qemu_x86_64.bzl, not the call).
func repoRuleFixtureDefaults() repoRuleDefaults {
	return repoRuleDefaults{qemuVersion: "11.0.4"}
}

// TestScanRepoRule proves scanRepoRule generalizes scanCallArgs: balanced
// parentheses (a nested call inside build_file_content), comments, strings, and
// a whole-word guard so "http_archive" never matches s3_http_archive.
func TestScanRepoRule(t *testing.T) {
	tests := []struct {
		name     string
		content  string
		ruleName string
		want     string
	}{
		{
			name:     "balanced parens in nested call",
			content:  `s3_http_archive(name = "x", build_file_content = "exports_files([\"a\"])")`,
			ruleName: "s3_http_archive",
			want:     `name = "x", build_file_content = "exports_files([\"a\"])"`,
		},
		{
			name:     "parens inside quoted string and comment",
			content:  "apt.install(name = \"x\", # ) stays ignored\n  packages = [\"a\"])",
			ruleName: "apt.install",
			want:     "name = \"x\", # ) stays ignored\n  packages = [\"a\"]",
		},
		{
			name:     "word-boundary guard skips s3_http_archive when scanning http_archive",
			content:  `s3_http_archive(name = "x")`,
			ruleName: "http_archive",
			want:     "",
		},
		{
			name:     "word-boundary guard skips qemu_x86_64.bzl string",
			content:  `qemu_x86_64 = use_repo_rule("//tools/bazel:qemu_x86_64.bzl", "qemu_x86_64")`,
			ruleName: "qemu_x86_64",
			want:     "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := scanRepoRule(tt.content, tt.ruleName)
			if tt.want == "" {
				if len(got) != 0 {
					t.Errorf("scanRepoRule(%q, %q) = %q, want none", tt.content, tt.ruleName, got)
				}
				return
			}
			if len(got) != 1 || got[0] != tt.want {
				t.Errorf("scanRepoRule(%q, %q) = %q, want [%q]", tt.content, tt.ruleName, got, tt.want)
			}
		})
	}
}

// TestParseRepoRulesSpecTable drives the whole fixture through the spec table
// and asserts every rule shape lands with the right name/version/category/role.
func TestParseRepoRulesSpecTable(t *testing.T) {
	deps, unknowns := parseModuleBazelWithDefaults([]byte(repoRuleFixture), "MODULE.bazel", repoRuleFixtureDefaults())
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}

	cases := []struct {
		category string
		name     string
		version  string
		role     string
	}{
		{common.CategoryToolBinary, "libwebsockets", "5.0.0", ""},
		{common.CategoryToolBinary, "libprotobuf_dev_arm64", "3.21.12-11+deb13u1", ""},
		{common.CategoryToolchain, "amd64_sysroot:libc6", "2.41-11cross1", ""},
		{common.CategoryToolchain, "amd64_sysroot:libgcc", "14.2.0-19cross1", ""},
		{common.CategoryToolchain, "amd64_sysroot:linux_libc", "6.12.38-1cross1", ""},
		{common.CategoryBaseImage, "dash", "", ""},
		{common.CategoryBaseImage, "binutils-x86-64-linux-gnu", "", ""},
		{common.CategoryToolBinary, "ffmpeg_dist", "8.1", common.RoleIntegrity},
		{common.CategoryRuntime, "openssh_dist", "", common.RoleIntegrity},
		{common.CategoryToolBinary, "qemu_x86_64_patched", "11.0.4", ""},
	}
	for _, tc := range cases {
		got := findDepVersion(t, deps, tc.category, tc.name, tc.version)
		if got == nil {
			t.Errorf("%s %q version %q not extracted: %v", tc.category, tc.name, tc.version, deps)
			continue
		}
		if got.Role != tc.role {
			t.Errorf("%s Role = %q, want %q", tc.name, got.Role, tc.role)
		}
		if got.File != "MODULE.bazel" {
			t.Errorf("%s File = %q, want MODULE.bazel", tc.name, got.File)
		}
	}
}

// TestParseRepoRulesAptInstallPackages asserts the apt.install pass emits one
// versionless base-image dependency per package, in declaration order, with the
// comment-laced list skipped correctly.
func TestParseRepoRulesAptInstallPackages(t *testing.T) {
	deps, unknowns := parseRepoRules(repoRuleFixture, "MODULE.bazel", repoRuleFixtureDefaults())
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	want := []string{
		"dash", "busybox-static", "gettext-base", "ca-certificates",
		"libfdk-aac2t64", "libc6", "coreutils", "libbinutils", "libsframe1",
		"zlib1g", "libzstd1", "libgcc-s1", "binutils-x86-64-linux-gnu",
	}
	got := aptPackageNames(deps)
	if len(got) != len(want) {
		t.Fatalf("apt.install packages = %v, want %d", got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("apt.install package[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func aptPackageNames(deps []common.Dependency) []string {
	var names []string
	for _, d := range deps {
		if d.Category == common.CategoryBaseImage {
			names = append(names, d.Name)
		}
	}
	return names
}

// TestParseRepoRulesS3RoleIntegrity asserts every s3 self-published artifact is
// emitted as an integrity pin, and that a sha-only pin (no version) is not a
// failure.
func TestParseRepoRulesS3RoleIntegrity(t *testing.T) {
	deps, unknowns := parseRepoRules(repoRuleFixture, "MODULE.bazel", repoRuleFixtureDefaults())
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	for _, name := range []string{"ffmpeg_dist", "openssh_dist"} {
		got := findDep(t, deps, "tool-binary", name)
		if got == nil {
			got = findDep(t, deps, "runtime", name)
		}
		if got == nil || !got.IsIntegrity() {
			t.Errorf("s3 %s not emitted as an integrity pin: %v", name, got)
		}
	}
	if got := findDep(t, deps, "runtime", "openssh_dist"); got == nil || got.Version != "" {
		t.Errorf("openssh_dist sha-only pin should have empty version, got %v", got)
	}
}

// TestParseRepoRulesFailClosed asserts a scanned rule that yields neither a
// version nor a sha256 becomes a first-class ExtractionUnknown with a
// descriptive reason.
func TestParseRepoRulesFailClosed(t *testing.T) {
	const module = `
tarball_strip_symlinks(
    name = "mystery",
    build_file_content = "exports_files([\"x\"])",
)
`
	_, unknowns := parseRepoRules(module, "MODULE.bazel", repoRuleDefaults{})
	if len(unknowns) != 1 {
		t.Fatalf("unknowns = %v, want exactly one fail-closed unknown", unknowns)
	}
	if !strings.Contains(unknowns[0].Reason, "mystery") || !strings.Contains(unknowns[0].Reason, "version or sha256") {
		t.Errorf("unknown reason = %q, want a descriptive version-or-sha256 reason naming the dep", unknowns[0].Reason)
	}
}

// TestParseRepoRulesSHAOnlyNotFailure asserts a rule with a sha but no version
// is emitted with RoleIntegrity rather than failing closed.
func TestParseRepoRulesSHAOnlyNotFailure(t *testing.T) {
	const module = `
deb_extract(
    name = "sha_only",
    sha256 = "26e311a867ef831d2378a33e772b1f21924261eedcefe08f7ce852c6176c2836",
    url = "https://snapshot.debian.org/archive/debian/20261005T000000Z/pool/main/p/protobuf/weird-package_arm64.deb",
)
`
	deps, unknowns := parseRepoRules(module, "MODULE.bazel", repoRuleDefaults{})
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none (sha present)", unknowns)
	}
	got := findDep(t, deps, "tool-binary", "sha_only")
	if got == nil || !got.IsIntegrity() {
		t.Fatalf("sha-only dep = %v, want RoleIntegrity", got)
	}
}

// TestParseHTTPArchiveTwoPartVersion asserts the protoc two-part fallback:
// .../protoc-36.2-linux-x86_64.zip yields version 36.2 and captures its sha256.
func TestParseHTTPArchiveTwoPartVersion(t *testing.T) {
	const module = `
http_archive(
    name = "protoc_linux_x86_64",
    build_file = "//third_party/protobuf-c:BUILD.protoc",
    sha256 = "121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278",
    url = "https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protoc-36.2-linux-x86_64.zip",
)
`
	deps, unknowns := parseModuleBazel([]byte(module), "MODULE.bazel")
	if len(unknowns) != 0 {
		t.Fatalf("unknowns = %v, want none", unknowns)
	}
	got := findDepVersion(t, deps, "tool-binary", "protoc_linux_x86_64", "36.2")
	if got == nil {
		t.Fatalf("protoc 36.2 not extracted: %v", deps)
	}
	if !strings.Contains(got.Note, "121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278") {
		t.Errorf("protoc Note = %q, want the sha256 captured", got.Note)
	}
}
